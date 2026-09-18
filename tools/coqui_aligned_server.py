# -*- coding: utf-8 -*-
"""
Coqui VITS TTS server with phoneme alignment — drop-in replacement for
`python -m TTS.server.server` for the Eros Realm AI voice pipeline.

WHY THIS EXISTS
---------------
The stock Coqui server (`/api/tts`) computes exact per-phoneme durations
inside VITS (the duration predictor's `w_ceil`) and then throws them away,
returning only a wav. The UE lip-sync path therefore had to re-derive timing
from a *separate* espeak-ng call with heuristic durations — which drift from
the audio because VITS is stochastic (its duration predictor adds noise, so
the audio never matches an independent alignment).

This server returns the wav AND the alignment from the SAME synthesis call, so
the phoneme durations correspond exactly to the returned audio. No drift.

PROTOCOL
--------
GET/POST /api/tts?text=...&speaker_id=p251
    Returns: audio/wav body (identical bytes to the stock server) PLUS header
        X-Phoneme-Alignment: base64(json)
    where json = {
        "sample_rate": 22050,
        "audio_seconds": 5.79,
        "phonemes": [ {"code": "A", "duration": 0.12}, ... ]  # viseme codes
    }
    "code" is one of the AIVoiceVisemeLibrary codes: A E I O U B F T S SH K W Y R _

The body stays byte-identical to the stock endpoint, so an old UE client that
ignores the header keeps working unchanged.

SELF TEST
---------
    venv\Scripts\python.exe coqui_aligned_server.py --selftest "Welcome home."
Prints the phoneme/duration breakdown and writes selftest.wav — use this to
eyeball the mapping without UE in the loop.

Launch (see StartAIServers.bat):
    venv\Scripts\python.exe coqui_aligned_server.py \
        --model_name tts_models/en/vctk/vits --host 127.0.0.1 --port 5002
"""

import argparse
import base64
import io
import json
import sys
from pathlib import Path

import numpy as np
import torch
from flask import Flask, request, Response

from TTS.utils.manage import ModelManager
from TTS.utils.synthesizer import Synthesizer
from TTS.tts.utils.synthesis import synthesis


# ---------------------------------------------------------------------------
# IPA (espeak) -> AIVoiceVisemeLibrary code
#
# espeak emits IPA, one symbol per token, so diphthongs already arrive as two
# vowel tokens (e.g. "aɪ" = "a" then "ɪ") and split into two visemes for free —
# exactly the glide the old single-vowel collapse was missing.
#
# The target codes match UAIVoiceVisemeLibrary::GetShapeForPhoneme:
#   A E I O U   vowels
#   B           bilabial   p b m
#   F           labiodental f v
#   T           dental/alveolar  t d n l θ ð
#   S           alveolar sibilant  s z (flat lips)
#   SH          postalveolar sibilant/affricate  ʃ ʒ tʃ dʒ (lips protrude/round)
#   K           velar/glottal  k g h ŋ x
#   W Y R       glides  w / j / r-family
#   _           rest/silence
# ---------------------------------------------------------------------------
_IPA_TO_VISEME = {
    # --- Vowels: open / low ---
    "ɑ": "A", "ɐ": "A", "ɒ": "A", "æ": "A", "a": "A", "ʌ": "A", "ɜ": "A", "ɚ": "A", "ɝ": "A",
    # --- Vowels: mid / central ---
    "ɛ": "E", "e": "E", "ə": "E", "ɘ": "E", "ɵ": "E", "œ": "E", "ø": "E",
    # --- Vowels: close front ---
    "i": "I", "ɪ": "I", "ɨ": "I", "ʏ": "I", "y": "I", "ᵻ": "I",
    # --- Vowels: mid-back round ---
    "ɔ": "O", "o": "O",
    # --- Vowels: close back round ---
    "u": "U", "ʊ": "U", "ʉ": "U", "ɯ": "U",

    # --- Bilabials ---
    "p": "B", "b": "B", "m": "B", "ɓ": "B", "ʙ": "B",
    # --- Labiodentals ---
    "f": "F", "v": "F", "ʋ": "F", "ⱱ": "F", "ɱ": "F",
    # --- Dentals / alveolars (tongue-tip) ---
    "t": "T", "d": "T", "n": "T", "l": "T", "θ": "T", "ð": "T",
    "ɾ": "T", "ɬ": "T", "ɫ": "T", "ɭ": "T", "ɳ": "T", "ɖ": "T", "ʈ": "T", "ɗ": "T",
    # --- Alveolar sibilants (flat lips) ---
    "s": "S", "z": "S", "ç": "S",
    # --- Postalveolar sibilants / affricates (lips protrude & round) ---
    "ʃ": "SH", "ʒ": "SH", "ʧ": "SH", "ʤ": "SH",
    "ɕ": "SH", "ʑ": "SH", "ʐ": "SH", "ʂ": "SH",
    # --- Velars / glottal ---
    "k": "K", "g": "K", "ɡ": "K", "h": "K", "ŋ": "K", "x": "K", "ɣ": "K",
    "ɢ": "K", "q": "K", "ħ": "K", "ʔ": "K", "ɦ": "K", "ʍ": "K",
    # --- Glides / approximants ---
    "w": "W",
    "j": "Y", "ʎ": "Y",
    "ɹ": "R", "r": "R", "ɻ": "R", "ʁ": "R", "ʀ": "R", "ɽ": "R",
}

# Symbols that are diacritics/suprasegmentals, not mouth poses — their duration
# is folded into the preceding phoneme rather than emitted as its own viseme.
_MODIFIER_SYMBOLS = set("ˈˌːˑʼʰʱʲʷˠˤ˞ⁿˀ̩̃͡'↓↑→↗↘")

# Pad token (config: characters.pad) used as the interspersed blank when
# add_blank=True — a separator between phonemes, folded into the previous one.
_PAD_CHAR = "_"

# Punctuation the tokenizer may keep — treated as a rest (mouth closes).
_PUNCTUATION = set(';:,.!?¡¿—…"«»“” ')


class AlignedSynth:
    """Wraps a Coqui Synthesizer and exposes wav + per-phoneme viseme timing."""

    def __init__(self, model_name, use_cuda=False):
        import TTS as _TTS
        models_json = Path(_TTS.__file__).parent / ".models.json"
        manager = ModelManager(models_json)
        model_path, config_path, _ = manager.download_model(model_name)
        self.synth = Synthesizer(
            tts_checkpoint=model_path,
            tts_config_path=config_path,
            use_cuda=use_cuda,
        )
        self.model = self.synth.tts_model
        self.config = self.synth.tts_config
        self.use_cuda = use_cuda

        audio = self.config.audio
        self.sample_rate = int(audio["sample_rate"])
        self.hop_length = int(audio["hop_length"])
        self.seconds_per_frame = self.hop_length / float(self.sample_rate)

        # Multi-speaker (VCTK) — resolve speaker name -> id like the stock server.
        self.speaker_manager = getattr(self.model, "speaker_manager", None)

        # Global speech-speed default. VITS multiplies its predicted phoneme
        # durations by length_scale, so >1.0 => longer durations => slower,
        # calmer speech. Set from --length_scale in main(); a per-request
        # length_scale query param overrides it. 1.0 == stock speed.
        self.default_length_scale = 1.0

    def _resolve_speaker_id(self, speaker_name):
        if not self.speaker_manager or not speaker_name:
            return None
        name_to_id = getattr(self.speaker_manager, "name_to_id", None)
        if name_to_id and speaker_name in name_to_id:
            return name_to_id[speaker_name]
        # Fall back to the first available speaker rather than erroring.
        if name_to_id:
            return next(iter(name_to_id.values()))
        return None

    def synthesize(self, text, speaker_name=None, length_scale=None):
        """Returns (wav_int16_bytes_wavfile, alignment_dict).

        length_scale scales the VITS duration predictor: >1.0 slows speech and
        lengthens every phoneme, giving the UE lip-sync blend more frames per
        sound. Because VITS scales w_ceil (the durations this server reads for
        alignment) by the SAME factor, the returned alignment stretches with
        the audio — lips stay in sync and pitch is preserved (unlike changing
        playback rate on the client). None => use the server default.
        """
        speaker_id = self._resolve_speaker_id(speaker_name)

        effective_scale = (self.default_length_scale
                           if length_scale is None else float(length_scale))
        # Clamp to a sane band so a bad query param can't produce a 30-second
        # word or near-zero durations the lip-sync blend can't resolve.
        effective_scale = float(np.clip(effective_scale, 0.5, 2.5))
        self.model.length_scale = effective_scale

        out = synthesis(
            self.model,
            text,
            self.config,
            use_cuda=self.use_cuda,
            speaker_id=speaker_id,
            use_griffin_lim=False,
            do_trim_silence=False,
        )

        wav = out["wav"]
        model_outputs = out["outputs"]
        text_inputs = out["text_inputs"]  # torch tensor [1, T] of token ids

        phonemes = self._extract_phonemes(text_inputs, model_outputs)

        # Save wav to an in-memory RIFF via the synthesizer's own writer so the
        # bytes are byte-identical to what the stock /api/tts returns.
        buf = io.BytesIO()
        self.synth.save_wav(wav, buf)
        wav_bytes = buf.getvalue()

        audio_seconds = len(wav) / float(self.sample_rate)
        alignment = {
            "sample_rate": self.sample_rate,
            "audio_seconds": round(audio_seconds, 4),
            "phonemes": phonemes,
        }
        return wav_bytes, alignment

    def _extract_phonemes(self, text_inputs, model_outputs):
        """Pair each input token with its VITS duration, map to viseme codes.

        `durations` (w_ceil) aligns element-wise with `text_inputs`, both
        including the interspersed pad/blank tokens (add_blank=True). Pad and
        modifier tokens carry real frame counts — we fold those into the
        previous emitted phoneme instead of dropping the time, so the summed
        durations still equal the audio length.
        """
        durations = model_outputs.get("durations")
        if durations is None:
            return []

        # [1,1,T] or [1,T] -> [T]
        dur = durations.squeeze().detach().cpu().numpy().astype(np.float64)
        ids = text_inputs.squeeze().detach().cpu().numpy().tolist()
        if np.ndim(dur) == 0:
            dur = np.array([float(dur)])
        if isinstance(ids, int):
            ids = [ids]

        tokenizer = self.model.tokenizer
        result = []  # list of dict {code, frames}

        def fold_into_prev(frames):
            if result:
                result[-1]["frames"] += frames

        for token_id, frames in zip(ids, dur):
            frames = float(frames)
            try:
                ch = tokenizer.decode([int(token_id)])
            except Exception:
                ch = ""

            if ch == "" or ch == _PAD_CHAR or ch in _PUNCTUATION:
                # Separator / silence. Emit a rest only if it is a genuine gap;
                # tiny interspersed blanks just fold back into the last phoneme.
                if frames >= 1.0 and ch in _PUNCTUATION:
                    result.append({"code": "_", "frames": frames})
                else:
                    fold_into_prev(frames)
                continue

            if ch in _MODIFIER_SYMBOLS:
                fold_into_prev(frames)
                continue

            code = _IPA_TO_VISEME.get(ch)
            if code is None:
                # Unknown IPA symbol — keep its time as a rest so totals hold,
                # and let the mapping be tightened later from selftest output.
                fold_into_prev(frames)
                continue

            # Merge consecutive identical codes (e.g. a geminate) so we don't
            # emit micro-slivers the lip-sync blend can't resolve.
            if result and result[-1]["code"] == code:
                result[-1]["frames"] += frames
            else:
                result.append({"code": code, "frames": frames})

        # Frames -> seconds.
        phonemes = [
            {"code": p["code"],
             "duration": round(p["frames"] * self.seconds_per_frame, 5)}
            for p in result if p["frames"] > 0.0
        ]
        return phonemes


def build_app(synth: AlignedSynth):
    app = Flask(__name__)

    @app.route("/api/tts", methods=["GET", "POST"])
    def api_tts():
        text = request.values.get("text", "")
        speaker_id = request.values.get("speaker_id", "") or None
        if not text:
            return Response("missing text", status=400)

        # Optional per-request speech-speed override. Invalid/absent => server
        # default (synth.default_length_scale).
        length_scale = None
        length_scale_raw = request.values.get("length_scale", "")
        if length_scale_raw:
            try:
                length_scale = float(length_scale_raw)
            except ValueError:
                length_scale = None

        try:
            wav_bytes, alignment = synth.synthesize(
                text, speaker_name=speaker_id, length_scale=length_scale)
        except Exception as exc:  # noqa: BLE001 — surface any synth error as 500
            return Response(f"synthesis failed: {exc}", status=500)

        header_b64 = base64.b64encode(
            json.dumps(alignment, ensure_ascii=False).encode("utf-8")
        ).decode("ascii")

        resp = Response(wav_bytes, mimetype="audio/wav")
        resp.headers["X-Phoneme-Alignment"] = header_b64
        resp.headers["Access-Control-Expose-Headers"] = "X-Phoneme-Alignment"
        return resp

    @app.route("/health", methods=["GET"])
    def health():
        return Response("ok", mimetype="text/plain")

    return app


def run_selftest(synth: AlignedSynth, text, speaker):
    wav_bytes, alignment = synth.synthesize(text, speaker_name=speaker)
    Path("selftest.wav").write_bytes(wav_bytes)
    total = sum(p["duration"] for p in alignment["phonemes"])
    print(f"text        : {text!r}")
    print(f"speaker     : {speaker}")
    print(f"audio_secs  : {alignment['audio_seconds']}")
    print(f"phoneme sum : {round(total, 4)}  ({len(alignment['phonemes'])} visemes)")
    print("sequence    : " + " ".join(p["code"] for p in alignment["phonemes"]))
    print("-" * 52)
    for p in alignment["phonemes"]:
        bar = "#" * max(1, int(p["duration"] * 100))
        print(f"  {p['code']:2}  {p['duration']:.3f}s  {bar}")
    print("-" * 52)
    print("wrote selftest.wav")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model_name", default="tts_models/en/vctk/vits")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5002)
    parser.add_argument("--use_cuda", action="store_true")
    parser.add_argument("--length_scale", type=float, default=1.0,
                        help="Global speech speed. >1.0 slower (more lip-sync "
                             "blend time per phoneme, pitch preserved), <1.0 "
                             "faster. A length_scale query param overrides it.")
    parser.add_argument("--selftest", metavar="TEXT", default=None,
                        help="Synthesize TEXT, print alignment, write selftest.wav, exit.")
    parser.add_argument("--speaker", default="p251")
    args = parser.parse_args()

    print(f"[coqui_aligned_server] loading {args.model_name} ...", flush=True)
    synth = AlignedSynth(args.model_name, use_cuda=args.use_cuda)
    synth.default_length_scale = float(args.length_scale)
    print(f"[coqui_aligned_server] ready. sr={synth.sample_rate} "
          f"hop={synth.hop_length} ({synth.seconds_per_frame*1000:.2f} ms/frame) "
          f"length_scale={synth.default_length_scale}",
          flush=True)

    if args.selftest is not None:
        run_selftest(synth, args.selftest, args.speaker)
        return

    app = build_app(synth)
    print(f"[coqui_aligned_server] serving on http://{args.host}:{args.port}/api/tts",
          flush=True)
    app.run(host=args.host, port=args.port, threaded=False)


if __name__ == "__main__":
    main()
