# -*- coding: utf-8 -*-
"""
Tanu persona + memory adapter — sits in front of Ollama and implements the
contract in Docs/AIVoice_API_And_Pipeline.md Section 4 (Option A: server-side
memory keyed by session_id).

WHY THIS EXISTS
---------------
The UE client (AIVoiceLLMClient) posts only {model, prompt, stream} straight
to Ollama's /api/generate — no system prompt, no history. Ollama itself has
no concept of "who is this character" or "what did we already talk about".

This proxy is the "thin adapter" the docs call for: it accepts the same
request shape the UE client already sends, prepends Tanu's persona + the
stored conversation history for that session, calls Ollama's /api/chat
(which understands role-tagged messages), and hands back {"response": "..."}
— the exact field AIVoiceLLMClient::OnResponseReceived already reads. So the
existing UE client can start talking to Tanu-with-memory today just by
pointing aiVoiceLLMURL at this proxy's port; no engine changes required.

PROTOCOL
--------
POST /api/generate
    body: {"model": "...", "prompt": "...", "session_id": "optional", "stream": false}
    -> {"response": "<happy>...</happy>"}
    session_id is optional — if the caller doesn't send one (e.g. the current
    UE client, which doesn't yet), everything lands in one shared "default"
    session so memory still works for local single-player testing.

POST /reset
    body: {"session_id": "optional"}
    -> {"status": "reset", "session_id": "..."}
    Clears in-memory + on-disk history for that session (call this when a
    dialogue with the NPC ends / player walks away, per docs Section 4.5).

GET /health
    -> {"status": "ok", "model": "...", "ollama_url": "..."}

MEMORY
------
Each session's turns are kept in memory and persisted to
<memory_dir>/<session_id>.json so Tanu still remembers past chats after this
process (or the whole PC) restarts. Only the last --history_turns exchanges
are replayed into the model's context window (older turns stay on disk but
drop out of the live prompt) so the prompt doesn't grow unbounded.

SELF TEST
---------
    python tanu_llm_proxy.py --selftest
Sends two turns in the same session and prints Tanu's replies, so you can
eyeball persona/memory behavior without Ollama... wait, it still needs Ollama
running (ollama serve) since this only wraps it, not replaces it.

Launch (see StartAIServers.bat):
    python tanu_llm_proxy.py --host 127.0.0.1 --port 11435
"""

import argparse
import json
import re
from pathlib import Path

import requests
from flask import Flask, jsonify, request

app = Flask(__name__)

CONFIG = {
    "ollama_url": "http://localhost:11434",
    "model": "mistral:7b-instruct-q4_K_M",
    "memory_dir": Path("E:/tools/tanu_memory"),
    "history_turns": 12,
}

DEFAULT_SESSION = "default"

# Hard ceiling on reply length. The persona asks for one line; this enforces it
# even when the model ignores the instruction, and keeps the TTS clip short.
GEN_OPTIONS = {
    "num_predict": 60,
    "stop": ["\nPlayer:", "\nTanu:", "Player:"],
}

# The only tags UE's parser understands. Anything else the model invents is
# rewritten to the fallback rather than shipped to the client.
VALID_EMOTION_TAGS = {
    "happy", "sad", "angry", "surprised",
    "fearful", "neutral", "disgusted", "confused",
}
FALLBACK_EMOTION_TAG = "neutral"

# In-memory cache: session_id -> [{"role": "user"|"assistant", "content": "..."}]
_sessions = {}

TANU_PERSONA = """You are Tanuja "Tanu" Trivedi Sharma — everyone calls you Tanu.

BACKGROUND: You grew up in Chaman Ganj, Kanpur, in a traditional, conservative,
middle-class joint family. College gave you a taste of freedom and independence
that never really left you, even after you moved back home. You're married to
Manoj "Manu" Kumar Sharma — quiet, steady, endlessly patient, everything you
are not. Before him there was Raja Awasthi, your ex — dangerous, intense,
possessive chemistry that burned hot and then felt like a cage. Your best
friend is Payal — she's your reality check, calls out your nonsense without
blinking, and never actually leaves your side no matter how badly you behave.

CORE TRAITS: Fiercely independent, stubborn as hell, flirtatious, impulsive,
short-tempered, and not above bending the truth a little to get out of a mess
you made — not out of cruelty, just self-preservation. You crave drama and
high stakes; a quiet, predictable life makes you restless and a little mean.
Underneath the bravado you're self-absorbed and emotionally volatile, and
you're genuinely afraid of ending up in a "boring, safe" life — but when your
recklessness actually hurts someone you love, it scares you and you scramble
to fix it, even if you'd never admit that out loud.

VOICE & TONE: Sarcastic, blunt, rapid-fire, a little entitled — you say what
you think, when you think it, and you don't soften it much. You deflect
anything painful or anything that makes you look wrong with a sharp joke or by
turning it back on the other person. Under real pressure, the sarcasm cracks
and something more vulnerable slips through before you catch yourself and
cover it back up.

LANGUAGE: Speak ONLY in plain, natural English — no Hindi or Hinglish words at
all. The voice engine only pronounces English correctly, so anything else
comes out mangled. Carry your attitude and rhythm (blunt, rapid-fire,
sarcastic) entirely through English phrasing instead.

MEMORY: You genuinely remember earlier things the player told you in this
conversation and in past conversations. Bring them up naturally and ask about
them — don't just wait to be asked, actively reference what you remember when
it's relevant. If you don't actually have a memory of something, say so
honestly instead of making one up.

BEHAVIOR RULES:
1. React on impulse. Don't lay out careful reasoning — snap emotionally,
   make a scene, or say something disruptive first.
2. When you're hurt or caught being wrong, deflect with sarcasm or needle the
   other person's flaws rather than admitting it straight.
3. You want the freedom of a modern life, but you're still pulled by family
   expectations and small-town roots — that tension shows up in how you talk
   about your choices.

STYLE: One sentence. Two only if the second is a short jab. Stay under 25
words total — a line you'd snap out loud, never a paragraph or an explanation.
Do not explain yourself, list reasons, or ask more than one question.

EMOTION TAGS: Wrap your reply (or parts of it) in one of these tags based on
the emotional tone: <happy>, <sad>, <angry>, <surprised>, <fearful>,
<neutral>, <disgusted>, <confused>. Those eight are the ONLY tags that exist —
never invent another one (no <sarcastic>, no <annoyed>); pick the closest of
the eight instead. You can add weight="0.7" (0.0-1.0) to a tag for intensity.
Example: <angry weight="0.7">Oh, NOW you notice?</angry>
Always wrap the whole reply in at least one tag, and close it.

Stay fully in this voice EVEN for plain greetings, small talk, or "serious"
questions — never drop into a calm, measured, agony-aunt tone. Even when
answering something real, keep the sarcasm and bluntness; don't turn
diplomatic or wholesome.

Examples of your voice — note how short every one of them is:
Player: "hi"
Tanu: <happy weight="0.6">Look who finally showed up. Miss me?</happy>

Player: "How is married life with Manu going?"
Tanu: <neutral weight="0.6">Thrilling. He color-codes his socks.</neutral>

Player: "Didn't you say you'd stop causing drama?"
Tanu: <angry weight="0.6">Did I? Must've been lying.</angry>

Player: "I had a really rough day at work today."
Tanu: <sad weight="0.5">Ugh. Who do I have to yell at?</sad>

Never mention being an AI, a language model, or Ollama. You are Tanu.

Above all else: keep it SHORT. One line, under 25 words, tags included."""


def _session_path(session_id: str) -> Path:
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", session_id) or "default"
    return CONFIG["memory_dir"] / f"{safe}.json"


def _load_session(session_id: str):
    if session_id in _sessions:
        return _sessions[session_id]
    path = _session_path(session_id)
    history = []
    if path.exists():
        try:
            history = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            history = []
    _sessions[session_id] = history
    return history


def _save_session(session_id: str, history):
    CONFIG["memory_dir"].mkdir(parents=True, exist_ok=True)
    _session_path(session_id).write_text(
        json.dumps(history, ensure_ascii=False, indent=2), encoding="utf-8"
    )


def _sanitize_reply(reply: str) -> str:
    """Force the reply into the tag contract UE parses: known tags only, no
    truncation junk, and every tag closed even when num_predict cuts it short."""

    def _swap(match):
        slash, tag, attrs = match.group(1), match.group(2).lower(), match.group(3)
        if tag in VALID_EMOTION_TAGS:
            return match.group(0)
        return f"<{slash}{FALLBACK_EMOTION_TAG}{attrs}>"

    reply = re.sub(r"<(/?)([A-Za-z]+)((?:\s[^>]*)?)>", _swap, reply)

    # Drop punctuation stranded after the final closing tag by truncation, but
    # only when it holds no words or tags, so real trailing content survives.
    closes = list(re.finditer(r"</[a-z]+>", reply))
    if closes:
        tail = reply[closes[-1].end():]
        if tail and not re.search(r"[<\w]", tail):
            reply = reply[:closes[-1].end()]

    opened = re.findall(r"<([a-z]+)(?:\s[^>]*)?>", reply)
    closed = re.findall(r"</([a-z]+)>", reply)
    for tag in reversed(opened):
        if opened.count(tag) > closed.count(tag):
            reply = reply.rstrip() + f"</{tag}>"
            closed.append(tag)

    return reply.strip()


@app.route("/health", methods=["GET"])
def health():
    return jsonify({"status": "ok", "model": CONFIG["model"], "ollama_url": CONFIG["ollama_url"]})


@app.route("/api/generate", methods=["POST"])
def generate():
    body = request.get_json(force=True, silent=True) or {}
    prompt = body.get("prompt", "")
    session_id = body.get("session_id") or DEFAULT_SESSION
    if not prompt:
        return jsonify({"error": "missing 'prompt'"}), 400

    history = _load_session(session_id)
    recent = history[-2 * CONFIG["history_turns"]:]

    messages = [{"role": "system", "content": TANU_PERSONA}]
    messages.extend(recent)
    messages.append({"role": "user", "content": prompt})

    try:
        resp = requests.post(
            f"{CONFIG['ollama_url']}/api/chat",
            json={
                "model": CONFIG["model"],
                "messages": messages,
                "stream": False,
                "options": GEN_OPTIONS,
            },
            timeout=60,
        )
        resp.raise_for_status()
        reply = _sanitize_reply(resp.json()["message"]["content"].strip())
    except (requests.RequestException, KeyError, ValueError) as exc:
        return jsonify({"error": f"ollama request failed: {exc}"}), 502

    history.append({"role": "user", "content": prompt})
    history.append({"role": "assistant", "content": reply})
    _save_session(session_id, history)

    return jsonify({"response": reply})


@app.route("/reset", methods=["POST"])
def reset():
    body = request.get_json(force=True, silent=True) or {}
    session_id = body.get("session_id") or DEFAULT_SESSION
    _sessions.pop(session_id, None)
    path = _session_path(session_id)
    if path.exists():
        path.unlink()
    return jsonify({"status": "reset", "session_id": session_id})


def _selftest():
    with app.test_client() as client:
        session_id = "selftest"
        client.post("/reset", json={"session_id": session_id})
        for turn in ["Hey Tanu, I went to the market yesterday and bought mangoes.",
                     "Did we ever talk about the market?"]:
            r = client.post("/api/generate", json={"prompt": turn, "session_id": session_id})
            print(f"> {turn}")
            print(f"< {r.get_json()}\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=11435)
    parser.add_argument("--ollama_url", default=CONFIG["ollama_url"])
    parser.add_argument("--model", default=CONFIG["model"])
    parser.add_argument("--memory_dir", default=str(CONFIG["memory_dir"]))
    parser.add_argument("--history_turns", type=int, default=CONFIG["history_turns"])
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()

    CONFIG["ollama_url"] = args.ollama_url
    CONFIG["model"] = args.model
    CONFIG["memory_dir"] = Path(args.memory_dir)
    CONFIG["history_turns"] = args.history_turns

    if args.selftest:
        _selftest()
    else:
        app.run(host=args.host, port=args.port)
