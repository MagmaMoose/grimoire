"""Tests for transcribe.llm: provider dispatch, graceful skip, parsing."""

from transcribe import llm
from transcribe.llm import (
    _complete,
    _provider,
    complete_json,
    extract_action_items_with_openai,
    generate_title_description_with_openai,
    summarize_with_openai,
)

# --- _provider --------------------------------------------------------------


def test_provider_defaults_to_claude_for_empty_config():
    assert _provider({}) == "claude"
    assert _provider(None) == "claude"


def test_provider_reads_config_and_normalizes():
    assert _provider({"llm_provider": "openai"}) == "openai"
    assert _provider({"llm_provider": "  OpenAI  "}) == "openai"
    assert _provider({"llm_provider": "CLAUDE"}) == "claude"


def test_provider_none_value_falls_back_to_claude():
    assert _provider({"llm_provider": None}) == "claude"


# --- _complete dispatch -----------------------------------------------------


def test_complete_dispatches_to_anthropic_by_default(fake_anthropic, base_config):
    fake_anthropic["set_text"]("hello from claude")
    base_config["anthropic_api_key"] = "sk-ant"

    result = _complete(base_config, "sys", "user", max_tokens=100, temperature=0.5)

    assert result == "hello from claude"
    assert fake_anthropic["init_keys"] == ["sk-ant"]
    call = fake_anthropic["calls"][0]
    assert call["model"] == "claude-haiku-4-5-20251001"
    assert call["max_tokens"] == 100
    assert call["temperature"] == 0.5
    assert call["system"] == "sys"
    assert call["messages"] == [{"role": "user", "content": "user"}]


def test_complete_joins_only_text_blocks(fake_anthropic, base_config):
    fake_anthropic["set_text"]("part1 ", "part2", include_nontext=True)
    base_config["anthropic_api_key"] = "sk-ant"

    result = _complete(base_config, "s", "u", max_tokens=10, temperature=0.1)
    # The non-text (thinking) block is excluded.
    assert result == "part1 part2"


def test_complete_dispatches_to_openai_when_selected(fake_openai, base_config):
    fake_openai["set_content"]("hello from openai")
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "sk-oai"

    result = _complete(base_config, "sys", "user", max_tokens=50, temperature=0.2)

    assert result == "hello from openai"
    assert fake_openai["init_keys"] == ["sk-oai"]
    call = fake_openai["calls"][0]
    assert call["model"] == "gpt-4o-mini"
    assert call["max_tokens"] == 50
    assert call["temperature"] == 0.2
    assert call["messages"] == [
        {"role": "system", "content": "sys"},
        {"role": "user", "content": "user"},
    ]


def test_complete_returns_none_when_claude_key_missing(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = ""
    result = _complete(base_config, "s", "u", max_tokens=10, temperature=0.1)
    assert result is None
    # SDK client was never constructed
    assert fake_anthropic["init_keys"] == []


def test_complete_returns_none_when_openai_key_missing(fake_openai, base_config):
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = ""
    result = _complete(base_config, "s", "u", max_tokens=10, temperature=0.1)
    assert result is None
    assert fake_openai["init_keys"] == []


def test_complete_respects_custom_models(fake_anthropic, fake_openai, base_config):
    base_config["anthropic_api_key"] = "k"
    base_config["anthropic_model"] = "claude-haiku-4-5"
    _complete(base_config, "s", "u", max_tokens=1, temperature=0.0)
    assert fake_anthropic["calls"][0]["model"] == "claude-haiku-4-5"

    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    base_config["openai_model"] = "gpt-4o"
    _complete(base_config, "s", "u", max_tokens=1, temperature=0.0)
    assert fake_openai["calls"][0]["model"] == "gpt-4o"


def test_complete_falls_back_to_default_model_when_blank(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = "k"
    base_config["anthropic_model"] = ""
    _complete(base_config, "s", "u", max_tokens=1, temperature=0.0)
    assert fake_anthropic["calls"][0]["model"] == llm.DEFAULT_ANTHROPIC_MODEL


# --- summarize_with_openai --------------------------------------------------


def test_summarize_returns_text(fake_anthropic, base_config):
    fake_anthropic["set_text"]("a summary")
    base_config["anthropic_api_key"] = "k"
    assert summarize_with_openai("transcript text", base_config) == "a summary"
    # Transcript embedded in the user prompt
    assert "transcript text" in fake_anthropic["calls"][0]["messages"][0]["content"]


def test_summarize_returns_none_when_no_key(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = ""
    assert summarize_with_openai("x", base_config) is None


def test_summarize_swallows_exceptions(monkeypatch, base_config, capsys):
    base_config["anthropic_api_key"] = "k"

    def boom(*a, **k):
        raise RuntimeError("kaboom")

    monkeypatch.setattr(llm, "_complete", boom)
    assert summarize_with_openai("x", base_config) is None
    assert "Failed to summarize" in capsys.readouterr().out


# --- generate_title_description_with_openai ---------------------------------


def test_title_description_parsed(fake_anthropic, base_config):
    fake_anthropic["set_text"]("Title: My Video\nDescription: A short blurb.")
    base_config["anthropic_api_key"] = "k"
    title, desc = generate_title_description_with_openai("t", base_config)
    assert title == "My Video"
    assert desc == "A short blurb."


def test_title_description_none_when_no_content(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = ""  # _complete returns None
    title, desc = generate_title_description_with_openai("t", base_config)
    assert title is None
    assert desc is None


def test_title_description_handles_missing_fields(fake_anthropic, base_config):
    fake_anthropic["set_text"]("Title: Only A Title")
    base_config["anthropic_api_key"] = "k"
    title, desc = generate_title_description_with_openai("t", base_config)
    assert title == "Only A Title"
    assert desc == ""


def test_title_description_swallows_exceptions(monkeypatch, base_config, capsys):
    base_config["anthropic_api_key"] = "k"
    monkeypatch.setattr(llm, "_complete", lambda *a, **k: (_ for _ in ()).throw(ValueError("x")))
    title, desc = generate_title_description_with_openai("t", base_config)
    assert (title, desc) == (None, None)
    assert "Failed to generate title/description" in capsys.readouterr().out


# --- extract_action_items_with_openai ---------------------------------------


def test_action_items_parsed(fake_anthropic, base_config):
    fake_anthropic["set_text"]("- First task\n- Second task\n• Third task")
    base_config["anthropic_api_key"] = "k"
    items = extract_action_items_with_openai("t", base_config)
    assert items == ["First task", "Second task", "Third task"]


def test_action_items_empty_when_none_identified(fake_anthropic, base_config):
    fake_anthropic["set_text"]("No specific action items identified.")
    base_config["anthropic_api_key"] = "k"
    assert extract_action_items_with_openai("t", base_config) == []


def test_action_items_empty_when_no_key(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = ""
    assert extract_action_items_with_openai("t", base_config) == []


def test_action_items_ignores_non_bullet_lines(fake_anthropic, base_config):
    fake_anthropic["set_text"]("Here are the items:\n- Do the thing\nrandom line")
    base_config["anthropic_api_key"] = "k"
    assert extract_action_items_with_openai("t", base_config) == ["Do the thing"]


def test_action_items_swallows_exceptions(monkeypatch, base_config, capsys):
    base_config["anthropic_api_key"] = "k"
    monkeypatch.setattr(llm, "_complete", lambda *a, **k: (_ for _ in ()).throw(ValueError("x")))
    assert extract_action_items_with_openai("t", base_config) == []
    assert "Failed to extract action items" in capsys.readouterr().out


def test_action_items_uses_openai_when_selected(fake_openai, base_config):
    fake_openai["set_content"]("- OpenAI task")
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    assert extract_action_items_with_openai("t", base_config) == ["OpenAI task"]
    # Lower temperature for action-item extraction is preserved.
    assert fake_openai["calls"][0]["temperature"] == 0.3


# --- client options: base URL, timeout, retries -----------------------------


def test_openai_base_url_routes_to_compatible_endpoint(fake_openai, base_config):
    """openai_base_url is how a LiteLLM gateway or Ollama gets used."""
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    base_config["openai_base_url"] = "https://litellm.example.com"
    summarize_with_openai("t", base_config)
    assert fake_openai["init_options"][0]["base_url"] == "https://litellm.example.com"


def test_openai_without_base_url_uses_provider_default(fake_openai, base_config):
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    summarize_with_openai("t", base_config)
    assert "base_url" not in fake_openai["init_options"][0]


def test_anthropic_base_url_override(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = "k"
    base_config["anthropic_base_url"] = "https://proxy.example.com"
    summarize_with_openai("t", base_config)
    assert fake_anthropic["init_options"][0]["base_url"] == "https://proxy.example.com"


def test_timeout_and_retries_are_bounded(fake_anthropic, base_config):
    """Left at SDK defaults, one stalled call can hold up a run for ~30 minutes."""
    base_config["anthropic_api_key"] = "k"
    base_config["llm_timeout_seconds"] = 120
    base_config["llm_max_retries"] = 1
    summarize_with_openai("t", base_config)
    options = fake_anthropic["init_options"][0]
    assert options["timeout"] == 120.0
    assert options["max_retries"] == 1


def test_client_options_have_defaults(fake_anthropic, base_config):
    base_config["anthropic_api_key"] = "k"
    summarize_with_openai("t", base_config)
    options = fake_anthropic["init_options"][0]
    assert options["timeout"] == 600.0
    assert options["max_retries"] == 2


def test_complete_json_retries_once_when_truncated(fake_openai, base_config, capsys):
    """Hitting the output cap is recoverable, so it earns one retry with more room."""
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    fake_openai["set_content"](None)  # empty content + finish_reason="length"

    assert complete_json(base_config, "sys", "user", {"type": "object"}, max_tokens=1000) is None

    out = capsys.readouterr().out
    assert "ran out of output budget" in out
    assert "retrying with 2000 tokens" in out
    # Two attempts: the original and the retry.
    assert len(fake_openai["calls"]) == 2
    assert fake_openai["calls"][1]["max_tokens"] == 2000


def test_complete_json_succeeds_on_the_retry(fake_openai, base_config):
    """A bigger budget on the second attempt is the whole point of retrying."""
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"

    attempts = {"n": 0}
    original = fake_openai["set_content"]

    def content_for_attempt():
        attempts["n"] += 1
        return None if attempts["n"] == 1 else '{"title": "Recovered"}'

    # First call truncates, second returns valid JSON.
    fake_openai["set_content_factory"](content_for_attempt)
    assert complete_json(base_config, "s", "u", {"type": "object"}) == {"title": "Recovered"}
    assert original is not None


def test_truncated_completion_is_not_reported_as_a_parse_error(fake_openai, base_config, capsys):
    """Truncation used to surface as JSONDecodeError, which named the wrong cause."""
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    fake_openai["set_content"](None)

    complete_json(base_config, "s", "u", {"type": "object"})
    out = capsys.readouterr().out
    assert "JSONDecodeError" not in out


def test_complete_json_returns_parsed_object(fake_openai, base_config):
    base_config["llm_provider"] = "openai"
    base_config["openai_api_key"] = "k"
    fake_openai["set_content"]('{"title": "Routing review"}')
    assert complete_json(base_config, "s", "u", {"type": "object"}) == {"title": "Routing review"}


def test_complete_json_without_api_key_returns_none(base_config):
    base_config["anthropic_api_key"] = ""
    assert complete_json(base_config, "s", "u", {"type": "object"}) is None


# --- bearer-token credentials ----------------------------------------------


def test_api_key_for_returns_plain_key_unchanged():
    cfg = {"llm_provider": "claude", "anthropic_api_key": "sk-ant-api-abc"}
    assert llm.api_key_for(cfg) == "sk-ant-api-abc"
    assert llm.auth_token_for(cfg) == ""


def test_oauth_shaped_api_key_is_treated_as_a_bearer_token():
    cfg = {"llm_provider": "claude", "anthropic_api_key": "sk-ant-oat-abc"}
    assert llm.api_key_for(cfg) == ""
    assert llm.auth_token_for(cfg) == "sk-ant-oat-abc"


def test_explicit_auth_token_wins_over_api_key():
    cfg = {
        "llm_provider": "claude",
        "anthropic_api_key": "sk-ant-api-abc",
        "anthropic_auth_token": "bearer-xyz",
    }
    assert llm.auth_token_for(cfg) == "bearer-xyz"


def test_is_configured_accepts_either_credential():
    assert llm.is_configured({"llm_provider": "claude", "anthropic_auth_token": "t"})
    assert llm.is_configured({"llm_provider": "claude", "anthropic_api_key": "sk-ant-api-1"})
    assert not llm.is_configured({"llm_provider": "claude"})


def test_client_options_send_bearer_token_with_the_oauth_beta_header():
    options = llm._client_options({"llm_provider": "claude", "anthropic_auth_token": "t"})
    assert options["auth_token"] == "t"
    assert options["default_headers"] == {"anthropic-beta": llm.DEFAULT_OAUTH_BETA}


def test_oauth_beta_header_is_overridable():
    options = llm._client_options(
        {"llm_provider": "claude", "anthropic_auth_token": "t", "anthropic_oauth_beta": "beta-9"}
    )
    assert options["default_headers"] == {"anthropic-beta": "beta-9"}


def test_plain_api_key_sends_no_bearer_token():
    options = llm._client_options({"llm_provider": "claude", "anthropic_api_key": "sk-ant-api-1"})
    assert "auth_token" not in options
    assert "default_headers" not in options


def test_openai_provider_never_sends_a_bearer_token():
    cfg = {"llm_provider": "openai", "openai_api_key": "sk-1", "anthropic_auth_token": "t"}
    assert llm.auth_token_for(cfg) == ""
    assert "auth_token" not in llm._client_options(cfg)
