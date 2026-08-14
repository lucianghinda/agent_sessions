# frozen_string_literal: true

require_relative "test_helper"

# Shapes taken from the one real thread available (2026-08-14): 24 messages,
# 12 user and 12 assistant, content parts tool_use 14, tool_result 14, text 2,
# thinking 1. One thread is thin evidence next to Codex's 415 files, and the
# adapter already warns that the server holds the canonical copy — but one
# observed thread still beats pi's zero.
class AmpReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_the_messages_of_a_thread_document
    with_thread([turn("user", [text_part("hello")]), turn("assistant", [text_part("hi")])]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal %w[hello hi], reader.messages.map(&:text)
    end
  end

  def test_thinking_parts_are_read_from_their_own_key
    part = { type: "thinking", thinking: "weighing it up", signature: "sig" }
    with_thread([turn("assistant", [part])]) do |reader|
      assert_equal :thinking, reader.messages.first.parts.first.type
      assert_equal "weighing it up", reader.messages.first.parts.first.text
    end
  end

  def test_tool_use_carries_its_name_and_id
    part = { type: "tool_use", id: "toolu_01", name: "todo_write", input: { todos: [] } }
    with_thread([turn("assistant", [part])]) do |reader|
      use = reader.messages.first.parts.first
      assert_equal :tool_use, use.type
      assert_equal "todo_write", use.name
      assert_equal "toolu_01", use.call_id
    end
  end

  # Amp spells this differently from every other agent: toolUseID rather than
  # tool_use_id, and the payload nested under run.result rather than content.
  # A mapper copied from Claude's would silently produce empty tool results.
  def test_tool_result_reads_amps_own_spelling
    part = { type: "tool_result", toolUseID: "toolu_01",
             run: { status: "success", result: "3 files changed" } }
    with_thread([turn("user", [part])]) do |reader|
      result = reader.messages.first.parts.first
      assert_equal :tool_result, result.type
      assert_equal "toolu_01", result.call_id
      assert_equal "3 files changed", result.text
    end
  end

  # A failed tool call carries run.error and no run.result at all — 2 of the 14
  # tool results in the one real thread. Mapping only run.result reported those
  # as empty text: a failure rendered as "the tool returned nothing", which is
  # the silent-emptiness this reader exists to avoid.
  def test_a_failed_tool_result_reports_its_error_rather_than_empty_text
    part = { type: "tool_result", toolUseID: "toolu_01",
             run: { status: "error", error: { message: "file not found", absolutePath: "/tmp/x" } } }
    with_thread([turn("user", [part])]) do |reader|
      message = reader.messages.first
      result = message.parts.first
      assert_equal :tool_result, result.type
      assert_equal "file not found", result.text
      # raw is the message's, not the part's: the status stays reachable there.
      assert_equal "error", message.raw.dig("content", 0, "run", "status")
      assert_empty reader.warnings
    end
  end

  def test_a_structured_tool_result_is_serialized_rather_than_inspected
    part = { type: "tool_result", toolUseID: "toolu_01",
             run: { status: "success", result: { files: 3 } } }
    with_thread([turn("user", [part])]) do |reader|
      assert_equal '{"files":3}', reader.messages.first.parts.first.text
    end
  end

  # sentAt is epoch milliseconds, not seconds and not a string.
  def test_messages_carry_their_sent_at_time
    with_thread([turn("user", [text_part("hi")], sent_at: 1_757_132_915_503)]) do |reader|
      assert_equal Time.utc(2025, 9, 6, 4, 28, 35, 503_000), reader.messages.first.at
    end
  end

  def test_a_message_without_a_time_reports_nil_rather_than_guessing
    record = { role: "user", content: [text_part("hi")] }
    with_thread([record]) { |reader| assert_nil reader.messages.first.at }
  end

  # The one reader where this is true: Amp's server holds the canonical copy,
  # so a local thread may be a partial mirror of the conversation.
  def test_amp_reports_itself_partial_and_message_fidelity
    with_thread([turn("user", [text_part("hi")])]) do |reader|
      assert_predicate reader, :partial?
      assert_equal :messages, reader.fidelity
    end
  end

  def test_an_unknown_content_part_becomes_unknown_with_a_warning
    with_thread([turn("assistant", [{ type: "telepathy", data: 1 }])]) do |reader|
      assert_equal [:unknown], reader.messages.first.parts.map(&:type)
      assert(reader.warnings.any? { |w| w.include?("telepathy") })
    end
  end

  def test_a_thread_that_is_not_json_warns_instead_of_raising
    with_raw_thread("{ not json") do |reader|
      assert_empty reader.messages
      assert(reader.warnings.any? { |w| w.include?("not valid JSON") })
    end
  end

  def test_a_thread_with_no_messages_array_warns_instead_of_raising
    with_raw_thread(JSON.generate({ id: "T-1", title: "empty" })) do |reader|
      assert_empty reader.messages
      assert(reader.warnings.any? { |w| w.include?("no messages") })
    end
  end

  # A thread is one JSON document: it cannot be streamed a record at a time, so
  # reading it means holding all of it. That is the gem's one unbounded read
  # (0.2 follow-up 8) and this is the bound — refused and reported, never an
  # attempt that ends in NoMemoryError.
  def test_a_document_larger_than_the_cap_is_refused_and_reported
    padding = "z" * (AgentSessions::Readers::Amp::MAX_DOCUMENT_BYTES + 1)
    with_raw_thread(JSON.generate({ messages: [turn("user", [text_part(padding)])] })) do |reader|
      assert_empty reader.messages
      assert(reader.warnings.any? { |w| w.include?("too large") })
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**_options, &block)
    with_thread([turn("user", [text_part("hello")])], &block)
  end

  def conformance_unknown(&block)
    with_thread([turn("assistant", [{ type: "telepathy", data: 1 }])], &block)
  end

  def conformance_broken(&block)
    with_raw_thread("{ not json", &block)
  end

  def text_part(text) = { type: "text", text: text }

  def turn(role, content, sent_at: 1_757_132_915_503)
    { role: role, content: content, meta: { sentAt: sent_at } }
  end

  def with_thread(messages, &block)
    document = { id: "T-abc", title: "fixture thread", created: 1_757_132_857_412,
                 v: 1, messages: messages }
    with_raw_thread(JSON.generate(document), &block)
  end

  def with_raw_thread(content)
    with_home do |home, env|
      write(content, home, ".local", "share", "amp", "threads",
            "T-0f8e1d2c-4b5a-4c6d-8e9f-0a1b2c3d4e5f.json")
      yield AgentSessions.read(AgentSessions.sessions(:amp, env: env).first)
    end
  end
end
