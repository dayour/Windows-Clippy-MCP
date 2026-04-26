"""Async Azure Voice Live realtime client.

This module mirrors the ``WidgetHost\\Voice\\VoiceLiveSession.cs`` and
``VoiceLiveSpeaker.cs`` clients from the Clippy widget so that the Python MCP
server can offer the same TTS / STT functionality to any MCP client.

The class is single-shot per request: it connects, sends one
``session.update``, performs one TTS or STT exchange, then closes. This keeps
the surface area small and makes it safe to call from MCP tool handlers without
worrying about long-lived background sessions.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import struct
from dataclasses import dataclass
from typing import AsyncIterator, Awaitable, Callable, Optional

try:
    import websockets
    from websockets.exceptions import WebSocketException
except ImportError as exc:  # pragma: no cover - import-time guard
    raise ImportError(
        "windows-clippy-mcp voice tools require the 'websockets' package. "
        "Run: uv pip install websockets"
    ) from exc


# ---------------------------------------------------------------------------
# Public configuration


@dataclass(frozen=True)
class VoiceLiveConfig:
    """Connection settings for an Azure Voice Live realtime session."""

    wss_endpoint: str = "wss://eastus2.api.cognitive.microsoft.com"
    model: str = "phi4-mm-realtime"
    api_version: str = "2025-10-01"
    api_key: Optional[str] = None
    voice_name: str = "en-US-AvaMultilingualNeural"
    voice_type: str = "azure-standard"
    transcription_model: str = "whisper-1"
    sample_rate: int = 24000

    def has_api_key(self) -> bool:
        return bool(self.api_key and self.api_key.strip())

    def realtime_uri(self) -> str:
        from urllib.parse import quote

        base = self.wss_endpoint.rstrip("/")
        return (
            f"{base}/voice-live/realtime"
            f"?api-version={self.api_version}&model={quote(self.model)}"
        )


def _resolve_api_key_windows() -> Optional[str]:
    """Resolve the Voice Live key from process env, then HKCU registry.

    On Windows the WPF widget sets ``VOICELIVE_API_KEY`` at User scope. New
    processes inherit it but a long-running shell may not, so we also probe the
    current-user registry hive directly.
    """
    for name in ("VOICELIVE_API_KEY", "COPILOT_DY_FOUNDRY_KEY"):
        value = os.environ.get(name)
        if value and value.strip():
            return value.strip()

    # Fall back to HKCU\Environment so freshly set User-scope keys work without
    # restarting the MCP host. Best-effort; never raises.
    try:
        import winreg  # type: ignore[import-not-found]

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment") as key:
            for name in ("VOICELIVE_API_KEY", "COPILOT_DY_FOUNDRY_KEY"):
                try:
                    value, _ = winreg.QueryValueEx(key, name)
                    if value and str(value).strip():
                        return str(value).strip()
                except OSError:
                    continue
    except Exception:
        pass
    return None


def resolve_voice_live_config(
    wss_endpoint: Optional[str] = None,
    model: Optional[str] = None,
    voice_name: Optional[str] = None,
    api_key: Optional[str] = None,
) -> VoiceLiveConfig:
    """Build a :class:`VoiceLiveConfig` from explicit args + environment.

    Explicit arguments win; otherwise we fall back to the values used by the
    Clippy widget (``eastus2.api.cognitive.microsoft.com`` / ``phi4-mm-realtime``).
    """
    return VoiceLiveConfig(
        wss_endpoint=wss_endpoint or "wss://eastus2.api.cognitive.microsoft.com",
        model=model or "phi4-mm-realtime",
        voice_name=voice_name or "en-US-AvaMultilingualNeural",
        api_key=api_key or _resolve_api_key_windows(),
    )


# ---------------------------------------------------------------------------
# Helpers


class VoiceLiveError(RuntimeError):
    """Raised for Voice Live protocol or transport errors."""


def pcm16_to_wav(pcm: bytes, sample_rate: int = 24000, channels: int = 1) -> bytes:
    """Wrap raw little-endian PCM16 audio in a minimal WAV container."""
    bits_per_sample = 16
    byte_rate = sample_rate * channels * bits_per_sample // 8
    block_align = channels * bits_per_sample // 8
    data_size = len(pcm)
    fmt_chunk = struct.pack(
        "<4sIHHIIHH",
        b"fmt ",
        16,
        1,  # PCM
        channels,
        sample_rate,
        byte_rate,
        block_align,
        bits_per_sample,
    )
    data_chunk = struct.pack("<4sI", b"data", data_size) + pcm
    riff_size = 4 + len(fmt_chunk) + len(data_chunk)
    return struct.pack("<4sI4s", b"RIFF", riff_size, b"WAVE") + fmt_chunk + data_chunk


def _decode_wav_to_pcm16_24k(wav_bytes: bytes) -> bytes:
    """Decode a WAV file to 24 kHz mono PCM16 raw bytes.

    Supports any PCM16 WAV; resamples to 24 kHz mono if needed using a simple
    linear interpolation (good enough for STT input). Falls back to assuming
    the input is already raw PCM16 24 kHz mono if WAV parsing fails.
    """
    try:
        import wave
        import io

        import numpy as np

        with wave.open(io.BytesIO(wav_bytes), "rb") as w:
            n_channels = w.getnchannels()
            sample_width = w.getsampwidth()
            framerate = w.getframerate()
            n_frames = w.getnframes()
            raw = w.readframes(n_frames)
        if sample_width != 2:
            raise VoiceLiveError(
                f"WAV must be 16-bit PCM (got sample_width={sample_width})"
            )
        samples = np.frombuffer(raw, dtype=np.int16)
        if n_channels > 1:
            samples = samples.reshape(-1, n_channels).mean(axis=1).astype(np.int16)
        if framerate != 24000:
            ratio = 24000 / framerate
            new_len = int(round(len(samples) * ratio))
            x_old = np.linspace(0, 1, len(samples), endpoint=False)
            x_new = np.linspace(0, 1, new_len, endpoint=False)
            samples = np.interp(x_new, x_old, samples).astype(np.int16)
        return samples.tobytes()
    except VoiceLiveError:
        raise
    except Exception:
        # If it doesn't look like a WAV, treat as raw PCM16 24 kHz mono.
        return wav_bytes


def decode_audio_input(audio_b64: str, audio_format: str) -> bytes:
    """Decode a base64 audio blob into raw PCM16 24 kHz mono bytes for Voice Live."""
    try:
        raw = base64.b64decode(audio_b64, validate=False)
    except Exception as exc:
        raise VoiceLiveError(f"audio_b64 is not valid base64: {exc}") from exc

    fmt = (audio_format or "").lower()
    if fmt in ("pcm16", "pcm16-24k", "pcm16-24k-mono", "raw"):
        return raw
    if fmt in ("wav", "audio/wav"):
        return _decode_wav_to_pcm16_24k(raw)
    raise VoiceLiveError(
        f"Unsupported audio_format '{audio_format}'. Use 'pcm16' (raw 24kHz mono LE) "
        "or 'wav'."
    )


# ---------------------------------------------------------------------------
# Client


# Type alias for the streaming chunk callback.
ChunkCallback = Callable[[int, bytes], Awaitable[None]]


class VoiceLiveClient:
    """One-shot async client around the Voice Live realtime WebSocket."""

    def __init__(self, config: VoiceLiveConfig):
        if not config.has_api_key():
            raise VoiceLiveError(
                "VOICELIVE_API_KEY is not set. "
                "Set the User-scope env var or pass api_key explicitly."
            )
        self._config = config

    async def speak(
        self,
        text: str,
        timeout: float = 30.0,
        on_chunk: Optional[ChunkCallback] = None,
    ) -> bytes:
        """Synthesize ``text`` into PCM16 24 kHz mono audio.

        If ``on_chunk`` is provided, each ``response.audio.delta`` is forwarded
        to it as raw PCM16 bytes (chunk_index, pcm_bytes) so callers can stream
        progress back to MCP clients while we still return the assembled buffer.
        """
        if not text or not text.strip():
            raise VoiceLiveError("text must be non-empty")

        chunks: list[bytes] = []
        chunk_index = 0
        done = asyncio.Event()
        error_msg: list[str] = []

        async def handler(message: dict) -> None:
            nonlocal chunk_index
            mtype = message.get("type")
            if mtype == "response.audio.delta":
                b64 = message.get("delta")
                if b64:
                    try:
                        pcm = base64.b64decode(b64)
                        chunks.append(pcm)
                        if on_chunk is not None:
                            await on_chunk(chunk_index, pcm)
                        chunk_index += 1
                    except Exception:
                        pass
            elif mtype in ("response.audio.done", "response.done"):
                done.set()
            elif mtype == "error":
                err = message.get("error") or {}
                error_msg.append(err.get("message") or "unknown Voice Live error")
                done.set()

        async with self._connect() as ws:
            await self._send_session_update_tts(ws)
            await self._send_text_for_tts(ws, text)
            await self._receive_until(ws, handler, done, timeout)

        if error_msg:
            raise VoiceLiveError(error_msg[0])
        return b"".join(chunks)

    async def transcribe(self, pcm16_24k_mono: bytes, timeout: float = 30.0) -> str:
        """Transcribe raw PCM16 24 kHz mono bytes via Voice Live STT."""
        if not pcm16_24k_mono:
            raise VoiceLiveError("audio buffer is empty")

        transcript: list[str] = []
        done = asyncio.Event()
        error_msg: list[str] = []

        async def handler(message: dict) -> None:
            mtype = message.get("type")
            if mtype == "conversation.item.input_audio_transcription.completed":
                t = message.get("transcript")
                if t:
                    transcript.append(t.strip())
                done.set()
            elif mtype == "conversation.item.input_audio_transcription.failed":
                err = message.get("error") or {}
                error_msg.append(err.get("message") or "transcription failed")
                done.set()
            elif mtype == "error":
                err = message.get("error") or {}
                error_msg.append(err.get("message") or "unknown Voice Live error")
                done.set()

        async with self._connect() as ws:
            await self._send_session_update_stt(ws)
            await self._send_audio_buffer(ws, pcm16_24k_mono)
            await self._receive_until(ws, handler, done, timeout)

        if error_msg:
            raise VoiceLiveError(error_msg[0])
        return " ".join(transcript).strip()

    # ------------------------------------------------------------------ utils

    def _connect(self):
        uri = self._config.realtime_uri()
        headers = [("api-key", self._config.api_key)]
        # websockets >= 12 uses ``additional_headers``; fall back if older.
        try:
            return websockets.connect(
                uri,
                additional_headers=headers,
                max_size=8 * 1024 * 1024,
                ping_interval=20,
                ping_timeout=20,
            )
        except TypeError:
            return websockets.connect(
                uri,
                extra_headers=headers,
                max_size=8 * 1024 * 1024,
                ping_interval=20,
                ping_timeout=20,
            )

    async def _send_session_update_tts(self, ws) -> None:
        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "modalities": ["text", "audio"],
                "instructions": "Speak the user-provided text exactly as written. Do not add commentary.",
                "output_audio_format": "pcm16",
                "voice": {
                    "name": self._config.voice_name,
                    "type": self._config.voice_type,
                },
                "turn_detection": None,
            },
        }))

    async def _send_text_for_tts(self, ws, text: str) -> None:
        await ws.send(json.dumps({
            "type": "conversation.item.create",
            "item": {
                "type": "message",
                "role": "user",
                "content": [{"type": "input_text", "text": text}],
            },
        }))
        await ws.send(json.dumps({
            "type": "response.create",
            "response": {
                "modalities": ["audio"],
                "instructions": "Speak the most recent user message verbatim.",
            },
        }))

    async def _send_session_update_stt(self, ws) -> None:
        await ws.send(json.dumps({
            "type": "session.update",
            "session": {
                "modalities": ["text"],
                "instructions": "Transcribe the user's speech. Do not respond.",
                "input_audio_format": "pcm16",
                "input_audio_noise_reduction": {"type": "azure_deep_noise_suppression"},
                "input_audio_transcription": {"model": self._config.transcription_model},
                # Use Azure server VAD so end-of-speech auto-commits the buffer
                # and fires input_audio_transcription.completed. We pad audio
                # with trailing silence in _send_audio_buffer to guarantee the
                # silence_duration_ms threshold trips.
                "turn_detection": {
                    "type": "azure_semantic_vad",
                    "threshold": 0.3,
                    "prefix_padding_ms": 200,
                    "silence_duration_ms": 400,
                },
            },
        }))

    async def _send_audio_buffer(self, ws, pcm: bytes) -> None:
        # Append ~600 ms of silence so server VAD reliably detects end of turn.
        silence = b"\x00" * (self._config.sample_rate * 2 * 6 // 10)
        full = pcm + silence
        # Send in ~200 ms chunks so very large clips don't blow the WS frame
        # size and the server can begin transcription incrementally.
        chunk_size = self._config.sample_rate * 2 // 5  # 200 ms
        for i in range(0, len(full), chunk_size):
            slice_ = full[i : i + chunk_size]
            await ws.send(json.dumps({
                "type": "input_audio_buffer.append",
                "audio": base64.b64encode(slice_).decode("ascii"),
            }))
        # Explicit commit in case VAD is slow; harmless if VAD already fired.
        try:
            await ws.send(json.dumps({"type": "input_audio_buffer.commit"}))
        except Exception:
            pass

    async def _receive_until(
        self,
        ws,
        handler: Callable[[dict], Awaitable[None]],
        done: asyncio.Event,
        timeout: float,
    ) -> None:
        async def reader() -> None:
            try:
                async for raw in ws:
                    if isinstance(raw, bytes):
                        continue
                    try:
                        msg = json.loads(raw)
                    except Exception:
                        continue
                    await handler(msg)
                    if done.is_set():
                        return
            except WebSocketException as exc:
                raise VoiceLiveError(f"WebSocket error: {exc}") from exc

        reader_task = asyncio.create_task(reader())
        try:
            await asyncio.wait_for(done.wait(), timeout=timeout)
        except asyncio.TimeoutError as exc:
            raise VoiceLiveError(
                f"Voice Live did not complete within {timeout}s"
            ) from exc
        finally:
            if not reader_task.done():
                reader_task.cancel()
                try:
                    await reader_task
                except (asyncio.CancelledError, Exception):
                    pass
