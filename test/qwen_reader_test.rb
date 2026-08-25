# frozen_string_literal: true

require_relative "test_helper"

# PROVISIONAL, like everything Qwen here: fixtures follow tokentelemetry's
# parser of the format, not observed Qwen output. Qwen is a Gemini CLI fork
# that adopted Anthropic's message shape, so these records read like Claude's
# while the store around them looks like Gemini's.
class QwenReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_user_and_assistant_turns
    with_session([turn("user", "hello"), turn("assistant", "hi there")]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  def test_string_content_reads_the_same_as_a_single_text_part
    record = { type: "user", timestamp: STAMP, message: { role: "user", content: "just a string" } }
    with_session([record]) do |reader|
      assert_equal [:text], reader.messages.first.parts.map(&:type)
      assert_equal "just a string", reader.messages.first.text
    end
  end

  def test_thinking_and_tool_parts
    parts = [{ type: "thinking", thinking: "let me check" },
             { type: "tool_use", id: "t1", name: "activate_skill", input: { name: "ruby" } }]
    with_session([turn("assistant", parts)]) do |reader|
      thinking, tool_use = reader.messages.first.parts
      assert_equal :thinking, thinking.type
      assert_equal "activate_skill", tool_use.name
      assert_equal '{"name":"ruby"}', tool_use.text
    end
  end

  # The Anthropic spelling: input_tokens is already disjoint from the cache
  # counts, so nothing is subtracted here — unlike Gemini and Codex, whose
  # input includes the cached share.
  def test_usage_is_taken_as_disjoint_without_subtraction
    usage = { input_tokens: 100, output_tokens: 20, cache_read_input_tokens: 400,
              cache_creation_input_tokens: 30 }
    with_session([billed("m1", usage)]) do |reader|
      u = reader.messages.first.usage
      assert_equal 100, u.input, "the Anthropic spelling is already disjoint"
      assert_equal 400, u.cache_read
      assert_equal 30, u.cache_creation
    end
  end

  # ephemeral_1h_input_tokens is cache creation at a different TTL. This gem's
  # Usage does not model TTL, and dropping it would under-report what was
  # written to cache.
  def test_the_one_hour_cache_creation_count_is_added_to_cache_creation
    usage = { input_tokens: 1, output_tokens: 1, cache_creation_input_tokens: 30,
              cache_creation: { ephemeral_1h_input_tokens: 12 } }
    with_session([billed("m1", usage)]) do |reader|
      assert_equal 42, reader.messages.first.usage.cache_creation
    end
  end

  def test_usage_counts_a_repeated_message_id_once
    usage = { input_tokens: 10, output_tokens: 5 }
    with_session([billed("m1", usage), billed("m1", usage), billed("m2", usage)]) do |reader|
      assert_equal 20, reader.usage.input
    end
  end

  def test_the_model_is_carried_per_message
    with_session([billed("m1", { input_tokens: 1 })]) do |reader|
      assert_equal "qwen3-coder-plus", reader.messages.first.model
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_session([turn("user", "hello")], **options, &block)
  end

  def conformance_unknown(&block)
    with_session([{ type: "telepathy", timestamp: STAMP }], &block)
  end

  def conformance_broken
    with_home do |home, env|
      write("not json at all\n", home, ".qwen", "projects", "my-app", "chats", "#{SESSION}.jsonl")
      yield read_session(env)
    end
  end

  SESSION = "8f2c1e00-1111-4222-8333-444455556666"
  STAMP = "2026-07-21T09:12:03.000Z"

  def turn(role, content)
    content = [{ type: "text", text: content }] if content.is_a?(String)
    { type: role, timestamp: STAMP, cwd: "/Users/you/app", message: { role: role, content: content } }
  end

  def billed(id, usage)
    record = turn("assistant", "ok")
    record[:message].merge!(id: id, model: "qwen3-coder-plus", usage: usage)
    record
  end

  def with_session(records, **options)
    with_home do |home, env|
      write(records.map { |r| JSON.generate(r) }.join("\n") + "\n",
            home, ".qwen", "projects", "my-app", "chats", "#{SESSION}.jsonl")
      yield read_session(env, **options)
    end
  end

  def read_session(env, **options)
    Agent::Sessions.read(Agent::Sessions.sessions(:qwen, env: env).first, **options)
  end
end
