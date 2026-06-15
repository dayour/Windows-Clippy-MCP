"""Voice Live integration for windows-clippy-mcp.

Exposes a thin async client around the Azure Voice Live realtime WebSocket
(``phi4-mm-realtime``). Used by the MCP server tools to provide:

- TTS (text-to-speech): synthesize speech from text and return PCM16 audio.
- STT (speech-to-text): transcribe a base64 PCM16 / WAV blob.
- Streamed TTS: stream audio chunks back via FastMCP progress notifications
  while still returning the assembled WAV at the end.

Authentication: ``VOICELIVE_API_KEY`` (Process scope or User scope on Windows;
``COPILOT_DY_FOUNDRY_KEY`` is also accepted as a fallback).
"""

from .voice_live import (
    VoiceLiveClient,
    VoiceLiveConfig,
    VoiceLiveError,
    decode_audio_input,
    pcm16_to_wav,
    resolve_voice_live_config,
)

__all__ = [
    "VoiceLiveClient",
    "VoiceLiveConfig",
    "VoiceLiveError",
    "decode_audio_input",
    "pcm16_to_wav",
    "resolve_voice_live_config",
]
