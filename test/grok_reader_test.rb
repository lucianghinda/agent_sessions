# frozen_string_literal: true

require_relative "test_helper"

# PROVISIONAL: fixtures follow tokentelemetry's parser of this format.
#
# Grok is the reason Readers::Base has a `record_path` hook. Layer 2
# enumerates summary.json, but the turns are in chat_history.jsonl beside it,
# and the billed tokens are in a THIRD file — ~/.grok/logs/unified.jsonl,
# shared by every session and keyed by session id.
class GrokReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_the_sibling_transcript_not_the_summary
    with_session([turn("user", "hello"), turn("assistant", "hi there")]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  def test_content_blocks_become_typed_parts
    blocks = [{ type: "text", text: "running it" },
              { type: "tool_use", id: "t1", name: "bash", input: { command: "ls" } }]
    with_session([turn("assistant", blocks)]) do |reader|
      text, tool_use = reader.messages.first.parts
      assert_equal :text, text.type
      assert_equal :tool_use, tool_use.type
      assert_equal "bash", tool_use.name
      assert_equal '{"command":"ls"}', tool_use.text
    end
  end

  def test_the_summary_is_exposed_for_what_layer_2_does_not_carry
    with_session([turn("user", "hi")]) do |reader|
      assert_equal "fixing the parser", reader.summary["generated_title"]
      assert_equal "grok-build", reader.summary["current_model_id"]
    end
  end

  def test_the_session_model_is_the_fallback_when_a_turn_names_none
    with_session([turn("assistant", "ok")]) do |reader|
      assert_equal "grok-build", reader.messages.first.model
    end
  end

  def test_a_turn_naming_its_own_model_overrides_the_session_model
    record = turn("assistant", "ok").merge(model: "grok-4-fast")
    with_session([record]) do |reader|
      assert_equal "grok-4-fast", reader.messages.first.model
    end
  end

  # prompt_tokens includes cached_prompt_tokens, so input is the difference —
  # the same normalization Codex and Gemini need, reached through a shared
  # log rather than through the session's own records.
  def test_usage_sums_this_sessions_rows_in_the_shared_log
    rows = [inference(SESSION, prompt: 1000, cached: 400, completion: 50, reasoning: 10),
            inference(SESSION, prompt: 500, cached: 100, completion: 20, reasoning: 5),
            inference("someone-else", prompt: 9999, cached: 0, completion: 9999, reasoning: 0)]
    with_session([turn("user", "hi")], log: rows) do |reader|
      usage = reader.usage
      assert_equal (1000 - 400) + (500 - 100), usage.input
      assert_equal 500, usage.cache_read
      assert_equal 70, usage.output
      assert_equal 15, usage.reasoning
    end
  end

  # A log that has rotated away leaves no usage at all — which must read as
  # unknown, not as a session that cost nothing.
  def test_usage_is_nil_when_the_shared_log_is_absent
    with_session([turn("user", "hi")]) { |reader| assert_nil reader.usage }
  end

  def test_a_row_claiming_more_cached_than_prompt_cannot_produce_negative_input
    rows = [inference(SESSION, prompt: 100, cached: 5000, completion: 1, reasoning: 0)]
    with_session([turn("user", "hi")], log: rows) do |reader|
      assert_equal 0, reader.usage.input
      assert_equal 100, reader.usage.cache_read, "the cached share is clamped to the prompt"
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_session([turn("user", "hello")], **options, &block)
  end

  def conformance_unknown(&block)
    with_session([{ role: "oracle", content: "?", timestamp: STAMP }], &block)
  end

  def conformance_broken
    with_home do |home, env|
      write(JSON.generate(summary), *session_dir(home), "summary.json")
      write("not json at all\n", *session_dir(home), "chat_history.jsonl")
      yield read_session(env)
    end
  end

  SESSION = "0f1e2d3c-4b5a-4697-8899-aabbccddeeff"
  ENCODED_PROJECT = "%2FUsers%2Fyou%2Fapp"
  STAMP = "2026-07-21T09:12:03.000Z"

  def session_dir(home) = [home, ".grok", "sessions", ENCODED_PROJECT, SESSION]

  def summary
    { info: { cwd: "/Users/you/app" }, created_at: STAMP, updated_at: STAMP,
      generated_title: "fixing the parser", current_model_id: "grok-build" }
  end

  def turn(role, content)
    { role: role, content: content, timestamp: STAMP }
  end

  def inference(sid, prompt:, cached:, completion:, reasoning:)
    { msg: "shell.turn.inference_done", sid: sid,
      ctx: { prompt_tokens: prompt, cached_prompt_tokens: cached,
             completion_tokens: completion, reasoning_tokens: reasoning } }
  end

  def with_session(records, log: nil, **options)
    with_home do |home, env|
      write(JSON.generate(summary), *session_dir(home), "summary.json")
      write(records.map { |r| JSON.generate(r) }.join("\n") + "\n",
            *session_dir(home), "chat_history.jsonl")
      if log
        write(log.map { |r| JSON.generate(r) }.join("\n") + "\n",
              home, ".grok", "logs", "unified.jsonl")
      end
      yield read_session(env, **options)
    end
  end

  def read_session(env, **options)
    Agent::Sessions.read(Agent::Sessions.sessions(:grok, env: env).first, **options)
  end
end
