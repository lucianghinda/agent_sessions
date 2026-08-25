# frozen_string_literal: true

require_relative "test_helper"

# These fixtures encode the format tokentelemetry's parser reads
# (resources/tokentelemetry, _scan_pi_sessions), because this machine's pi
# store holds no session files to copy shapes from (2026-08-24) — the same
# provisional standing the reader's own header comment declares. If a real pi
# session ever contradicts a shape here, fix the fixture AND the reader
# together; the fixture is a claim, not a preference.
class PiReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_user_and_assistant_turns
    with_session([header, message_record("user", [text("hello")]),
                  message_record("assistant", [text("hi there")])]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  def test_the_header_and_model_change_records_are_state_not_messages
    records = [header,
               { type: "model_change", provider: "anthropic", modelId: "claude-sonnet-5" },
               message_record("user", [text("hi")])]
    with_session(records) do |reader|
      assert_equal 1, reader.messages.size
      assert_empty reader.warnings
    end
  end

  def test_a_tool_call_becomes_a_tool_use_part
    call = { type: "toolCall", id: "tc_1", name: "bash", arguments: { command: "ls" } }
    with_session([header, message_record("assistant", [call])]) do |reader|
      part = reader.messages.first.parts.first
      assert_equal :tool_use, part.type
      assert_equal "bash", part.name
      assert_equal "tc_1", part.call_id
      assert_equal '{"command":"ls"}', part.text
    end
  end

  # usage spells camelCase and carries agent-computed cost. totalTokens is
  # deliberately unmapped — it restates the other fields.
  def test_a_message_carries_camel_case_usage_and_its_model
    usage = { input: 100, output: 20, cacheRead: 400, cacheWrite: 30,
              reasoning: 7, totalTokens: 557, cost: 0.004 }
    with_session([header, message_record("assistant", [text("ok")], usage: usage,
                                               model: "claude-sonnet-5")]) do |reader|
      m = reader.messages.first
      assert_equal "claude-sonnet-5", m.model
      assert_equal 100, m.usage.input
      assert_equal 20, m.usage.output
      assert_equal 400, m.usage.cache_read
      assert_equal 30, m.usage.cache_creation
      assert_equal 7, m.usage.reasoning
      assert_in_delta 0.004, m.usage.cost
    end
  end

  def test_usage_sums_across_messages_and_is_nil_without_any
    records = [header,
               message_record("assistant", [text("a")], usage: { input: 10, output: 5 }),
               message_record("assistant", [text("b")], usage: { input: 7, output: 3 })]
    with_session(records) do |reader|
      assert_equal 17, reader.usage.input
      assert_equal 8, reader.usage.output
    end
    with_session([header, message_record("user", [text("hi")])]) { |reader| assert_nil reader.usage }
  end

  def test_an_unrecognized_record_type_warns_and_becomes_unknown
    with_session([header, { type: "telepathy" }]) do |reader|
      assert_equal [:unknown], reader.messages.map(&:role)
      refute_empty reader.warnings
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_session([header, message_record("user", [text("hello")])], **options, &block)
  end

  def conformance_unknown(&block)
    with_session([header, { type: "telepathy" }], &block)
  end

  def conformance_broken
    with_home do |home, env|
      write("not json at all\n", home, ".pi", "agent", "sessions", PROJECT, FILENAME)
      yield read_session(env)
    end
  end

  PROJECT = "--Users-you-app--"
  FILENAME = "2026-07-21T09-12-03_0abc1234.jsonl"
  STAMP = "2026-07-21T09:12:03.000Z"

  def header = { type: "session", id: "0abc1234", cwd: "/Users/you/app", timestamp: STAMP }
  def text(value) = { type: "text", text: value }

  # Not `message`: Minitest::Assertions defines its own `message`, and
  # overriding it breaks every assertion failure this file could report —
  # the same trap the Codex reader test names.
  def message_record(role, content, usage: nil, model: nil)
    data = { role: role, content: content }
    data[:usage] = usage if usage
    data[:model] = model if model
    { type: "message", timestamp: STAMP, message: data }
  end

  def with_session(records, **options)
    with_home do |home, env|
      content = records.map { |r| JSON.generate(r) }.join("\n") + "\n"
      write(content, home, ".pi", "agent", "sessions", PROJECT, FILENAME)
      yield read_session(env, **options)
    end
  end

  def read_session(env, **options)
    Agent::Sessions.read(Agent::Sessions.sessions(:pi, env: env).first, **options)
  end
end
