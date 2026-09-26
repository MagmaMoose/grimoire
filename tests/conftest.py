"""Shared pytest fixtures for the transcribe test suite.

Every test mocks external I/O: the anthropic + openai SDKs, requests (Slack),
subprocess (whisper-cli / ffmpeg), and the filesystem (via tmp_path). No real
network, process, or home-directory access happens.
"""

import sys
import types

import pytest

from transcribe import config as config_mod


@pytest.fixture
def base_config():
    """A complete config dict with sane, fully-populated values."""
    return {
        "watch_directory": "/tmp/watch",
        "destination_directory": "/tmp/dest",
        "llm_provider": "claude",
        "anthropic_api_key": "",
        "anthropic_model": "claude-haiku-4-5-20251001",
        "openai_api_key": "",
        "openai_model": "gpt-4o-mini",
        "slack_webhook_url": "",
        "video_extensions": [".mov", ".mp4", ".avi", ".mkv", ".m4v"],
        "whisper_model": "base",
        "icloud_base_url": "https://www.icloud.com/iclouddrive/",
    }


@pytest.fixture(autouse=True)
def private_config_dir(tmp_path, monkeypatch):
    """Keep every test out of the real ``~/.transcribe``.

    Claims, the Voice Memos ledger and the action item state all live there,
    and a test run that wrote into the developer's own copy would both leak
    state between tests and quietly edit real data.
    """
    config_dir = tmp_path / ".transcribe"
    monkeypatch.setattr(config_mod, "CONFIG_DIR", config_dir)
    monkeypatch.setattr(config_mod, "CONFIG_FILE", config_dir / "config.yaml")
    return config_dir


@pytest.fixture(autouse=True)
def no_real_categorising(monkeypatch):
    """Stop the automatic categorising after notes from reaching a real provider.

    Notes tests stub ``notes.complete_json``; categorising runs straight after
    and calls its own import of it, which would otherwise go to the network with
    the test's fake key. Tests of categorising patch it again themselves.
    """
    from transcribe import categorise

    monkeypatch.setattr(categorise, "complete_json", lambda *a, **k: None)


@pytest.fixture
def patched_config_paths(tmp_path, monkeypatch):
    """Redirect config.py's CONFIG_DIR / CONFIG_FILE into tmp_path.

    Returns the (config_dir, config_file) Path pair so tests can inspect them.
    """
    config_dir = tmp_path / ".transcribe"
    config_file = config_dir / "config.yaml"
    monkeypatch.setattr(config_mod, "CONFIG_DIR", config_dir)
    monkeypatch.setattr(config_mod, "CONFIG_FILE", config_file)
    return config_dir, config_file


class FakeTextBlock:
    """Mimics an Anthropic content block with a .type and .text attribute."""

    def __init__(self, text, type="text"):
        self.type = type
        self.text = text


class FakeAnthropicResponse:
    def __init__(self, blocks):
        self.content = blocks


class FakeAnthropicMessages:
    def __init__(self, recorder, blocks):
        self._recorder = recorder
        self._blocks = blocks

    def create(self, **kwargs):
        self._recorder.append(kwargs)
        return FakeAnthropicResponse(self._blocks)


class FakeAnthropicClient:
    def __init__(self, recorder, blocks, api_key=None, **options):
        self.api_key = api_key
        self.messages = FakeAnthropicMessages(recorder, blocks)


@pytest.fixture
def fake_anthropic(monkeypatch):
    """Install a fake ``anthropic`` module into sys.modules.

    Returns a recorder dict: ``calls`` (list of kwargs passed to create),
    ``init_keys`` (api_keys passed to the client), and ``set_text`` to control
    the returned text blocks.
    """
    state = {
        "calls": [],
        "init_keys": [],
        "init_options": [],
        "blocks": [FakeTextBlock("default")],
    }

    def _client_factory(api_key=None, **options):
        state["init_keys"].append(api_key)
        state["init_options"].append(options)
        return FakeAnthropicClient(state["calls"], state["blocks"], api_key=api_key, **options)

    fake_mod = types.ModuleType("anthropic")
    fake_mod.Anthropic = _client_factory
    monkeypatch.setitem(sys.modules, "anthropic", fake_mod)

    def set_text(*texts, include_nontext=False):
        blocks = [FakeTextBlock(t) for t in texts]
        if include_nontext:
            blocks.insert(0, FakeTextBlock("IGNORED", type="thinking"))
        state["blocks"] = blocks

    state["set_text"] = set_text
    return state


class FakeChoiceMessage:
    def __init__(self, content):
        self.content = content


class FakeChoice:
    def __init__(self, content, finish_reason="stop"):
        self.message = FakeChoiceMessage(content)
        # Reasoning models return empty content with finish_reason="length"
        # when they spend the whole budget thinking.
        self.finish_reason = "length" if content is None else finish_reason


class FakeOpenAIResponse:
    def __init__(self, content):
        self.choices = [FakeChoice(content)]


class FakeOpenAICompletions:
    def __init__(self, recorder, content):
        self._recorder = recorder
        self._content = content

    def create(self, **kwargs):
        self._recorder.append(kwargs)
        # Resolved per call, so a test can make a retry answer differently from
        # the attempt before it.
        content = self._content() if callable(self._content) else self._content
        while callable(content):
            content = content()
        return FakeOpenAIResponse(content)


class FakeOpenAIChat:
    def __init__(self, recorder, content):
        self.completions = FakeOpenAICompletions(recorder, content)


class FakeOpenAIClient:
    def __init__(self, recorder, content, api_key=None, **options):
        self.api_key = api_key
        self.chat = FakeOpenAIChat(recorder, content)


@pytest.fixture
def fake_openai(monkeypatch):
    """Install a fake ``openai`` module into sys.modules."""
    state = {"calls": [], "init_keys": [], "init_options": [], "content": "default"}

    def _client_factory(api_key=None, **options):
        state["init_keys"].append(api_key)
        state["init_options"].append(options)
        return FakeOpenAIClient(
            state["calls"], lambda: state["content"], api_key=api_key, **options
        )

    fake_mod = types.ModuleType("openai")
    fake_mod.OpenAI = _client_factory
    monkeypatch.setitem(sys.modules, "openai", fake_mod)

    def set_content(content):
        state["content"] = content

    def set_content_factory(factory):
        """Supply a callable resolved on every request, for multi-attempt tests."""
        state["content"] = factory

    state["set_content"] = set_content
    state["set_content_factory"] = set_content_factory
    return state
