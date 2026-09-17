"""Configuration loading and saving for transcribe."""

import os
from pathlib import Path

import yaml

# Configuration
CONFIG_DIR = Path.home() / ".transcribe"
CONFIG_FILE = CONFIG_DIR / "config.yaml"
DEFAULT_CONFIG = {
    "watch_directory": str(Path.home() / "Movies"),
    "destination_directory": str(
        Path.home() / "Library/Mobile Documents/com~apple~CloudDocs/Movies"
    ),
    # LLM provider for summaries/titles/action items: "claude" (default) or "openai".
    "llm_provider": "claude",
    # Anthropic (Claude) settings. Default is the current Claude Haiku 4.5.
    "anthropic_api_key": "",
    # Bearer token alternative to anthropic_api_key, for OAuth-issued tokens.
    # An anthropic_api_key starting with "sk-ant-oat" is treated as one too.
    "anthropic_auth_token": "",
    "anthropic_model": "claude-haiku-4-5-20251001",
    # OpenAI settings (used when llm_provider is "openai").
    "openai_api_key": "",
    "openai_model": "gpt-4o-mini",
    # Point the "openai" provider at any OpenAI-compatible endpoint: a LiteLLM
    # gateway, Ollama, vLLM, LM Studio, OpenRouter. Empty means api.openai.com.
    "openai_base_url": "",
    # SDK defaults are 600s x 2 retries, so one stalled call can hold up a run
    # for half an hour. A reasoning model on a long transcript is genuinely
    # slow, so this is generous but bounded.
    "llm_timeout_seconds": 600,
    "llm_max_retries": 2,
    "slack_webhook_url": "",
    "video_extensions": [".mov", ".mp4", ".avi", ".mkv", ".m4v"],
    # Whisper model name (ggml-<name>.bin); auto-downloaded if missing.
    # large-v3-turbo is the accuracy/speed sweet spot on Apple Silicon.
    "whisper_model": "large-v3-turbo",
    "icloud_base_url": "https://www.icloud.com/iclouddrive/",  # Users can customize this
    # --- Transcription -----------------------------------------------------
    # Voice Activity Detection. Leave this on: without it, whisper hallucinates
    # filler over room tone and can lock into a repetition loop that ruins
    # everything after it.
    "whisper_vad": True,
    "whisper_vad_threshold": 0.5,
    "whisper_suppress_non_speech": True,
    "whisper_language": "en",
    "whisper_threads": 8,
    # Optional initial prompt biasing the decoder toward your vocabulary, e.g.
    # "Terraform, Kubernetes, MikroTik, BGP, IPsec". Improves proper nouns.
    # Seed vocabulary. This is no longer a list to maintain by hand: the prompt
    # is assembled per recording from the calendar event, a glossary mined from
    # your own past notes, and this seed, then fitted to whisper's 224-token cap.
    "whisper_prompt": "",
    "whisper_auto_prompt": True,
    "whisper_prompt_token_budget": 190,
    # --- Meetings ----------------------------------------------------------
    # Split a recording into the separate meetings it contains, and write one
    # folder of notes per meeting. Set false for the original flat behaviour.
    "meeting_mode": True,
    "split_meetings": True,
    # Also cut the source video into one clip per meeting (lossless stream copy).
    "split_video": True,
    "move_source_video": True,
    # A pause at least this long is a candidate boundary between meetings.
    "meeting_gap_seconds": 180,
    "min_meeting_seconds": 120,
    # Output budgets. Reasoning models bill their chain of thought as completion
    # tokens and return empty content if they exhaust the budget thinking, so
    # these are generous. You are only charged for what is actually generated.
    "boundary_max_tokens": 8000,
    # Naming a dozen voices takes as much deliberation as writing the notes --
    # measured against deepseek-v4-pro, 8000 was exhausted by reasoning alone
    # and every meeting came back unnamed.
    "speaker_max_tokens": 16000,
    "notes_max_tokens": 16000,
    # --- Speaker attribution ----------------------------------------------
    # Local voice clustering via sherpa-onnx. Needs: pip install 'transcribe[diarize]'
    "diarization_enabled": True,
    # Cosine-distance threshold for merging voices. Higher merges more. The
    # upstream default of 0.5 badly over-segments real meetings (36 "speakers"
    # in a 15-minute sample); 0.8 gave a plausible 6.
    "diarization_threshold": 0.8,
    # Segmentation window step, as a fraction of the window. Lower is slower for
    # no measurable gain: 0.1 ran at 10.9x realtime, 0.25 at 28.9x, same turns.
    "diarization_window_shift_ratio": 0.25,
    # Diarization is the slowest local stage on a long meeting; match whisper.
    "diarization_threads": 8,
    # Names that recur in your meetings; helps map voices to real people when no
    # calendar attendee list is available.
    "known_participants": [],
    # --- Auto-recording (transcribe autorecord) ----------------------------
    # Start/stop an OBS recording when a meeting starts and ends, detected by
    # microphone activity. Needs: pip install 'transcribe[autorecord]' and
    # OBS > Tools > WebSocket Server Settings enabled.
    # A recording needs the microphone AND one corroborating signal. The mic
    # alone fires on dictation, voice notes and Siri.
    "autorecord_require_camera": True,
    "autorecord_use_calendar": True,
    # Opt-in, and noisy: recording on microphone activity alone is what makes
    # always-on capture feel unhinged.
    "autorecord_mic_only": False,
    "autorecord_ignored_cameras": [],
    "autorecord_poll_seconds": 5,
    # How long the mic must be held before recording starts. Long enough that a
    # notification chime or a "can you hear me" does not produce a file.
    "autorecord_start_after_seconds": 45,
    # How long it must be released before recording stops. Long enough that
    # swapping a headset does not chop a meeting in two.
    "autorecord_stop_after_seconds": 120,
    # Refuse to start below this much free space: a truncated recording on a
    # full disk loses the meeting entirely.
    "autorecord_min_free_gb": 10,
    # Virtual/loopback inputs that report as running whenever their host app is
    # open. Empty means use the built-in list.
    "autorecord_ignored_devices": [],
    "obs_host": "localhost",
    "obs_port": 4455,
    "obs_password": "",
    # --- Calendar ----------------------------------------------------------
    # Match the recording against calendar events for real titles and attendees.
    # Needs: pip install 'transcribe[calendar]' and Calendar permission.
    "calendar_enabled": True,
    "calendar_source": "macos",
    "calendar_margin_minutes": 15,
}


def load_config():
    """Load configuration from file or create default."""
    if not CONFIG_FILE.exists():
        # Config can contain API keys and tokens; keep dir/file private.
        CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
        with open(CONFIG_FILE, "w") as f:
            yaml.dump(DEFAULT_CONFIG, f, default_flow_style=False)
        os.chmod(CONFIG_FILE, 0o600)
        print(f"Created default config at {CONFIG_FILE}")
        print("Please edit it to add your OpenAI API key and Slack webhook URL.")
        return DEFAULT_CONFIG

    with open(CONFIG_FILE) as f:
        config = yaml.safe_load(f)

    # Capture the on-disk state before merging defaults, so back-compat logic
    # below can distinguish what the user actually configured.
    had_openai_key = bool(config.get("openai_api_key"))
    had_anthropic_key = bool(config.get("anthropic_api_key"))
    had_explicit_provider = "llm_provider" in config

    # Merge with defaults for any missing keys
    for key, value in DEFAULT_CONFIG.items():
        if key not in config:
            config[key] = value

    # Back-compat: an existing OpenAI-only config (set before Claude became the
    # default provider) had no llm_provider and no Anthropic key. Default such
    # configs to OpenAI so those users keep getting summaries.
    if had_openai_key and not had_anthropic_key and not had_explicit_provider:
        config["llm_provider"] = "openai"

    return config


def save_config(config):
    """Save configuration to file."""
    # Config can contain API keys and tokens; keep dir/file private.
    CONFIG_DIR.mkdir(mode=0o700, parents=True, exist_ok=True)
    with open(CONFIG_FILE, "w") as f:
        yaml.dump(config, f, default_flow_style=False)
    os.chmod(CONFIG_FILE, 0o600)
