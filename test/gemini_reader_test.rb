# frozen_string_literal: true

require_relative "test_helper"

# Written against a real store (2026-08-24): 12 chats, 121 records, and 97
# token records whose arithmetic settled the cache question — see
# test_cached_tokens_are_subtracted_from_input.
class GeminiReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_user_and_assistant_turns
    with_session([user_message("hello"), gemini_message("hi there")]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  # thoughts sit beside content rather than inside a parts array; a thought is
  # {subject, description}, and the subject alone reads as a heading with no
  # body, so both are kept.
  def test_thoughts_become_thinking_parts_carrying_subject_and_description
    record = gemini_message("done", thoughts: [{ subject: "Dissecting the Needs",
                                                 description: "I'm focused on the core request." }])
    with_session([record]) do |reader|
      thinking, text = reader.messages.first.parts
      assert_equal :thinking, thinking.type
      assert_equal "Dissecting the Needs: I'm focused on the core request.", thinking.text
      assert_equal :text, text.type
    end
  end

  # One toolCalls entry holds both the call and its result.
  def test_a_tool_call_becomes_a_tool_use_and_a_tool_result
    call = { id: "codebase_investigator-1765543509729", name: "codebase_investigator",
             args: { objective: "find the bug" }, result: "found it", status: "success" }
    with_session([gemini_message("ok", tool_calls: [call])]) do |reader|
      parts = reader.messages.first.parts
      tool_use = parts.find { |p| p.type == :tool_use }
      tool_result = parts.find { |p| p.type == :tool_result }
      assert_equal "codebase_investigator", tool_use.name
      assert_equal '{"objective":"find the bug"}', tool_use.text
      assert_equal "found it", tool_result.text
      assert_equal tool_use.call_id, tool_result.call_id
    end
  end

  def test_a_running_tool_call_has_no_result_part
    call = { id: "t1", name: "search", args: {}, status: "executing" }
    with_session([gemini_message("ok", tool_calls: [call])]) do |reader|
      refute(reader.messages.first.parts.any? { |p| p.type == :tool_result })
    end
  end

  # info records are the CLI talking to the operator ("Update successful!"),
  # not a turn. One real session on this machine contains nothing else, and
  # reads as empty by default — which is correct, not a bug.
  def test_info_records_are_opt_in_events
    records = [user_message("hi"), { id: "i1", timestamp: STAMP, type: "info",
                                     content: "Update successful!" }]
    with_session(records) { |reader| assert_equal 1, reader.messages.size }
    with_session(records, include_events: true) do |reader|
      assert_equal %i[user system], reader.messages.map(&:role)
      assert_empty reader.warnings
    end
  end

  # The whole point of the arithmetic check: across all 97 real token records,
  # total == input + output + thoughts + tool, with cached never added — so a
  # cached count is part of the input beside it, and must be subtracted for
  # Usage#input to mean the same thing it means for Claude.
  def test_cached_tokens_are_subtracted_from_input
    tokens = { input: 64_138, output: 54, cached: 7867, thoughts: 109, tool: 0, total: 64_301 }
    with_session([gemini_message("ok", tokens: tokens)]) do |reader|
      usage = reader.messages.first.usage
      assert_equal 64_138 - 7867, usage.input
      assert_equal 7867, usage.cache_read
      assert_equal 54, usage.output
      assert_equal 109, usage.reasoning
      assert_nil usage.cost, "Gemini reports no cost; nil must not become zero"
    end
  end

  def test_usage_sums_per_message_rather_than_treating_counts_as_running_totals
    records = [gemini_message("a", tokens: { input: 100, output: 5, cached: 0, thoughts: 0 }),
               gemini_message("b", tokens: { input: 40, output: 3, cached: 0, thoughts: 0 })]
    with_session(records) do |reader|
      assert_equal 140, reader.usage.input
      assert_equal 8, reader.usage.output
    end
  end

  def test_the_model_is_carried_per_message
    with_session([gemini_message("ok")]) do |reader|
      assert_equal "gemini-2.5-pro", reader.messages.first.model
    end
  end

  # Layer 2's id is the filename, whose trailing hex is shared between
  # sessions; the agent's own sessionId lives in the document.
  def test_header_exposes_the_documents_own_session_id
    with_session([user_message("hi")]) do |reader|
      assert_equal "b20947ab-6d96-4c50-af3c-d04af150950a", reader.header["sessionId"]
      refute reader.header.key?("messages"), "the header is metadata, not the transcript"
    end
  end

  def test_an_unrecognized_record_type_warns_and_becomes_unknown
    with_session([{ id: "x", timestamp: STAMP, type: "telepathy", content: "?" }]) do |reader|
      assert_equal [:unknown], reader.messages.map(&:role)
      refute_empty reader.warnings
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_session([user_message("hello")], **options, &block)
  end

  def conformance_unknown(&block)
    with_session([{ id: "x", timestamp: STAMP, type: "telepathy", content: "?" }], &block)
  end

  def conformance_broken
    with_home do |home, env|
      write("not json at all\n", home, ".gemini", "tmp", PROJECT_HASH, "chats", "#{SESSION}.json")
      yield read_session(env)
    end
  end

  SESSION = "session-2025-11-29T20-08-b20947ab"
  PROJECT_HASH = "c50803d9b17d02f08903fa879df04d28d4b5e7b68d97add32827a31e211f8b95"
  STAMP = "2025-11-29T20:09:43.874Z"

  def user_message(text) = { id: "u1", timestamp: STAMP, type: "user", content: text }

  def gemini_message(text, thoughts: nil, tool_calls: nil, tokens: nil)
    record = { id: "g1", timestamp: STAMP, type: "gemini", content: text, model: "gemini-2.5-pro" }
    record[:thoughts] = thoughts if thoughts
    record[:toolCalls] = tool_calls if tool_calls
    record[:tokens] = tokens if tokens
    record
  end

  def with_session(messages, **options)
    with_home do |home, env|
      document = { sessionId: "b20947ab-6d96-4c50-af3c-d04af150950a", projectHash: PROJECT_HASH,
                   startTime: STAMP, lastUpdated: STAMP, messages: messages }
      write(JSON.generate(document), home, ".gemini", "tmp", PROJECT_HASH, "chats", "#{SESSION}.json")
      yield read_session(env, **options)
    end
  end

  def read_session(env, **options)
    AgentSessions.read(AgentSessions.sessions(:gemini, env: env).first, **options)
  end
end
