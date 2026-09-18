# CLAUDE.md - Eros Realms AI Voice Server Stack

This file is loaded by Claude Code at the start of every session in this folder.
Read it fully before producing any output.

This folder is NOT the game project. It is the local AI backend the game talks to.
The Unreal project lives separately (on this machine or another) and has its own CLAUDE.md.

---

## What this is

Four local HTTP servers that give the Unreal Engine 5.7 project "Eros Realm" a
voice conversation loop with an AI character (Tanu). No cloud services involved.

The round trip for one spoken player turn:

```
UE mic capture
  -> WAV bytes  -> [Whisper.cpp  :8080]  -> transcribed text
  -> text       -> [Tanu proxy   :11435] -> persona + history prepended
                        -> [Ollama :11434] -> LLM reply text
  -> text       -> [Coqui TTS    :5002]  -> WAV + phoneme timings
  -> UE plays audio and drives lip sync from the timings
```

UE never talks to Ollama directly. It always goes through the Tanu proxy, which
injects the system prompt and the conversation history for that session.

## Ports and endpoints

| Port | Server | Endpoints UE uses |
|---|---|---|
| 8080 | whisper.cpp STT | `POST /inference` - multipart `file=@x.wav`, `temperature` |
| 11435 | Tanu persona/memory proxy | `POST /api/generate`, `POST /reset`, `GET /health` |
| 11434 | Ollama | internal only - the proxy forwards here over loopback |
| 5002 | Coqui TTS (aligned) | `GET|POST /api/tts?text=&speaker_id=&length_scale=`, `GET /health` |

Proxy request body: `{"model":"...","prompt":"...","session_id":"optional","stream":false}`
`session_id` is optional and falls back to a default session.
Reset body: `{"session_id":"..."}`

## Files in this folder

| Path | What it is |
|---|---|
| `SetupAIServers.bat` | One-time installer for a new machine. Run as administrator. |
| `StartAIServers.bat` | Day-to-day launcher. Binds loopback only - see the LAN section. |
| `requirements-coqui.txt` | Exact pip freeze of the known-good venv. 146 packages. |
| `coqui_aligned_server.py` | Coqui TTS wrapper returning phoneme timings for lip sync. |
| `tanu_llm_proxy.py` | Flask proxy adding persona + per-session history over Ollama. |
| `tanu_memory/` | Conversation history, one JSON per session id. Not in git. |
| `whisper.cpp/` | Prebuilt whisper server plus its GGML model. |
| `coqui-tts/venv/` | Python 3.10 venv. Machine-specific - see constraints. |

---

## Setting up a new machine

Copy this whole folder across, then run `SetupAIServers.bat` as administrator.
It is re-runnable and skips anything already done.

It performs, in order: Python 3.10 install, Ollama install,
`ollama pull mistral:7b-instruct-q4_K_M`, venv rebuild, CPU torch install,
locked package install, proxy deps into system Python, whisper model download,
`tanu_memory/` creation, firewall rule.

If it exits with code 2 it installed something that is not yet on PATH in that
shell. Open a new elevated window and run it again.

Then launch with `StartAIServers.bat` and wait for `ALL SERVERS ONLINE`.

---

## Hard constraints - do not violate these

**Python must be 3.10.** `TTS==0.22.0` has no wheels for 3.12+ and will not
build from source on Windows. The venv here is 3.10.11.

**torch must be the CPU build, installed before the lock file.**
The working version is `2.12.1+cpu` from `https://download.pytorch.org/whl/cpu`.
A plain `pip install TTS` or letting the lock file resolve torch pulls the
default PyPI wheel, which is the ~2.5 GB CUDA build.

**Never copy `coqui-tts/venv/` between machines.** A venv bakes absolute
interpreter paths into its scripts. A copied venv activates but cannot run.
Delete it and recreate with `py -3.10 -m venv`.

**Never `pip install` into this venv without pinning.** The 146 packages in
`requirements-coqui.txt` are a known-good Windows/3.10 resolution. Reproduce it;
do not re-resolve it.

**Use the full Ollama model tag** `mistral:7b-instruct-q4_K_M`. A bare `mistral`
triggers a different pull and breaks the locked CPU setup.

**The proxy runs under system Python, not the venv.** `StartAIServers.bat`
launches it with plain `python`. That interpreter needs `flask` and `requests`.

---

## Running for a remote UE client (LAN)

By default every server binds `127.0.0.1`, which is loopback only - a socket
bound there is never placed on the network card, so no other machine can reach
it. This is a bind-address property, not a firewall setting.

To serve a UE client on another PC, three things must all be true.

**1. Bind wide.** In `StartAIServers.bat`, change `127.0.0.1` to `0.0.0.0` for
whisper (`--host`), Coqui (`--host`), and the proxy (`--host`). Ollama has no
`--host` flag - it reads `OLLAMA_HOST`, so prepend
`set OLLAMA_HOST=0.0.0.0:11434 &&` to its start line.

Leave two things alone: the verify `curl` calls stay on `localhost` because they
run on this machine, and the proxy's `--ollama_url` stays `localhost` because the
proxy and Ollama are on the same box.

**2. Open the firewall** (elevated, once):

```
netsh advfirewall firewall delete rule name="ErosRealm AI Servers"
netsh advfirewall firewall add rule name="ErosRealm AI Servers" dir=in action=allow protocol=TCP localport=8080,5002,11435 profile=any remoteip=192.168.1.0/24
```

Use `profile=any`, not `profile=private`. Windows classifies unknown networks
as Public, and a private-profile rule silently matches nothing on a Public
network - the rule appears in the list while every connection still times out.
`remoteip` scopes it to the LAN, so `any` does not mean open everywhere.

Delete before adding: `netsh ... add` with an existing name creates a duplicate
rather than replacing it, so a stale wrong-profile rule survives.

Check the classification with `Get-NetConnectionProfile`. Add 11434 only if you
want direct Ollama access; UE does not need it.

**3. Point UE at this machine's IP.** The URLs are `UPROPERTY(Config, ...)` on
`UErosRealmOnlineConfig`, so this is an ini change with no rebuild. On the UE
machine, in `Config/DefaultErosRealmOnline.ini` (committed, team-wide) or
`Saved/Config/WindowsEditor/ErosRealmOnline.ini` (local only):

```ini
[/Script/ErosRealmOnline.ErosRealmOnlineConfig]
aiVoiceSTTURL="http://<server-ip>:8080/inference"
aiVoiceLLMURL="http://<server-ip>:11435/api/generate"
aiVoiceLLMResetURL="http://<server-ip>:11435/reset"
aiVoiceTTSURL="http://<server-ip>:5002/api/tts"
```

Editing these via Project Settings > Eros Realm Online writes back into the
committed `DefaultErosRealmOnline.ini`, because the UCLASS is marked
`DefaultConfig`. Use the `Saved/` path to keep it machine-local.

A literal IPv4 address also sidesteps the IPv6/IPv4 dual-stack loopback issue
noted in the C++ defaults - that only affected `localhost`.

---

## UE client defaults, for reference

From `Source/ErosRealmOnline/Config/ErosRealmOnlineConfig.cpp`:

| Setting | Default |
|---|---|
| `aiVoiceLLMModel` | `mistral:7b-instruct-q4_K_M` |
| `aiVoiceTTSSpeakerID` | `p248` |
| `aiVoiceTTSLengthScale` | `1.5` |
| `aiVoiceHttpTimeoutSeconds` | `60.0` |
| `aiVoiceMaxRecordSeconds` | `15.0` |

`length_scale` above 1.0 slows speech so the lip-sync blend gets more frames per
phoneme; pitch is preserved. UE sends it per request and it overrides the
server-side fallback of 1.15 set on the Coqui command line.

---

## Troubleshooting

**Diagnose the transport before the server.** From the client machine:

```
curl http://<server-ip>:11435/health
```

- Connection **times out** -> firewall, or the network is not Private.
- Connection **refused** -> the server is bound to `127.0.0.1`, or not running.
- Returns `{"status":"ok",...}` -> transport is fine; the fault is elsewhere.

**Ollama reports NOT RESPONDING but the window looks fine.** The health check in
`StartAIServers.bat` posts a real prompt with `--max-time 5`; a cold model load
takes longer than that. Check `http://localhost:11434/api/tags` instead - it is
instant and proves the daemon is up. Then confirm the model is pulled with
`ollama list`; a missing model and a dead server look identical otherwise.

**Coqui fails to start.** Almost always the venv. Run
`coqui-tts\venv\Scripts\python.exe -c "import TTS, torch"`. An ImportError means
the venv is incomplete or was copied from another machine - rebuild it.

**Tanu replies with no memory of earlier turns.** History is per `session_id`,
stored as `tanu_memory/<session_id>.json`. History does not move between
machines unless you copy that folder. An empty folder is expected on a new box.

**Whisper is slow.** `build/bin/Release/` ships `ggml-cuda.dll`, so it was built
with CUDA. Without an NVIDIA driver it falls back to CPU. That works; it is just
slower. Nothing to change.

**Ollama is on CPU deliberately.** `StartAIServers.bat` sets
`CUDA_VISIBLE_DEVICES=-1`, `HIP_VISIBLE_DEVICES=-1`, `GGML_VK_VISIBLE_DEVICES=-1`
and `OLLAMA_VULKAN=false`. Remove those to use a GPU. Do not assume it is a bug.

---

## Conventions for editing this folder

- Batch files must be written with CRLF. LF-only line endings break `goto` and
  label resolution in cmd.
- No emojis anywhere - code, comments, logs, or documentation.
- Keep comments to two lines maximum.
- Never write the Unicode replacement character U+FFFD. Remove it where found.
- Prefer editing `StartAIServers.bat` over creating parallel launchers, so there
  is one source of truth for ports and arguments.
- When changing a port or bind address, update this file and the UE
  `DefaultErosRealmOnline.ini` in the same change. They are a contract.

## Verified facts, and how

Confirmed by inspection on the origin machine (2026-08-07), not assumed:

- Venv is Python 3.10.11 - from `coqui-tts/venv/pyvenv.cfg`.
- `torch 2.12.1+cpu`, `cuda_avail False`, `TTS 0.22.0`, `Flask 3.1.3` - from an
  import check inside the venv.
- 146 locked packages - from `pip freeze` in that venv.
- `small.en` is a valid argument to `models/download-ggml-model.cmd`, and it
  downloads into its own folder, which is where the server expects the model.
- Proxy routes `/health`, `/api/generate`, `/reset`; Coqui routes `/api/tts`
  and `/health` - read from the two Python sources.

Not verified, and worth checking if they fail: the winget package ids
`Python.Python.3.10` and `Ollama.Ollama`. Winget ids do get renamed. If either
install fails, `SetupAIServers.bat` prints the vendor URL and exits rather than
continuing into a half-built install.
