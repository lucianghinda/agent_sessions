# frozen_string_literal: true

require_relative "test_helper"

# Every fixture record here is shaped after real ones: 128,987 records across
# 415 rollout files were inventoried on 2026-08-12, and the payload key sets
# below are the ones that corpus actually contains, in the proportions it
# contains them (response_item 57%, event_msg 38%, compacted 18 occurrences).
class CodexReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_user_and_assistant_messages_in_order
    with_session([user_message("hello"), assistant_message("hi there")]) do |reader|
      roles = reader.messages.map(&:role)
      assert_equal %i[user assistant], roles
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  # Codex says "developer" where the normalized vocabulary says :system. The
  # spec pins four roles; raw keeps the original word for anyone who needs it.
  def test_developer_role_normalizes_to_system
    with_session([message_record("developer", "input_text", "be terse")]) do |reader|
      assert_equal :system, reader.messages.first.role
      assert_equal "developer", reader.messages.first.raw.dig("payload", "role")
    end
  end

  # reasoning carries encrypted_content the gem cannot read plus a readable
  # summary. The summary is what becomes a :thinking part; claiming to expose
  # reasoning the gem cannot decrypt would be a lie about fidelity.
  def test_reasoning_becomes_a_thinking_part_from_the_summary
    with_session([reasoning("considering the options")]) do |reader|
      part = reader.messages.first.parts.first
      assert_equal :thinking, part.type
      assert_equal "considering the options", part.text
      assert_equal :assistant, reader.messages.first.role
    end
  end

  def test_tool_call_becomes_a_tool_use_part_on_an_assistant_message
    with_session([tool_call("shell", "call_abc", '{"command":"ls"}')]) do |reader|
      message = reader.messages.first
      assert_equal :assistant, message.role
      part = message.parts.first
      assert_equal :tool_use, part.type
      assert_equal "shell", part.name
      assert_equal "call_abc", part.call_id
    end
  end

  def test_tool_output_becomes_a_tool_result_part_on_a_tool_message
    with_session([tool_output("call_abc", "file-a\nfile-b")]) do |reader|
      message = reader.messages.first
      assert_equal :tool, message.role
      part = message.parts.first
      assert_equal :tool_result, part.type
      assert_equal "call_abc", part.call_id
      assert_equal "file-a\nfile-b", part.text
    end
  end

  def test_an_image_part_is_typed_rather_than_flattened_into_text
    record = { type: "response_item", timestamp: STAMP,
               payload: { type: "message", role: "user",
                          content: [{ type: "input_image", image_url: "data:image/png;base64,AAAA" }] } }
    with_session([record]) do |reader|
      assert_equal [:image], reader.messages.first.parts.map(&:type)
      assert_equal "", reader.messages.first.text
    end
  end

  # event_msg is 38% of the corpus and is UI-level: token counts, rate limits,
  # task_started. Including it by default would triple every message count.
  def test_event_messages_are_skipped_by_default_and_available_on_request
    records = [user_message("hi"), event_msg("token_count"), event_msg("task_complete")]

    with_session(records) do |reader|
      assert_equal 1, reader.messages.size
    end
    with_session(records, include_events: true) do |reader|
      assert_equal 3, reader.messages.size
      assert_equal %i[user system system], reader.messages.map(&:role)
    end
  end

  # The double-counting trap, in the shape the real records have: a compacted
  # record carries replacement_history, a restatement of turns already read.
  # Expanding it would report the same conversation twice.
  def test_compaction_is_a_boundary_and_its_replacement_history_is_not_replayed
    records = [user_message("first"), compacted(%w[first second]), user_message("third")]

    with_session(records) do |reader|
      assert_equal %w[first third], reader.messages.map(&:text)
      assert_equal 1, reader.compactions.size
      assert_equal 2, reader.compactions.first.replaced_count
      assert_equal Time.utc(2026, 7, 21, 9, 12, 3), reader.compactions.first.at
    end
  end

  def test_messages_carry_the_record_timestamp
    with_session([user_message("hi")]) do |reader|
      assert_equal Time.utc(2026, 7, 21, 9, 12, 3), reader.messages.first.at
    end
  end

  # Rule 1 of the Layer 3 spec: raw is never dropped, so a caller can escape a
  # normalization that is wrong or incomplete instead of forking the gem.
  def test_raw_is_always_the_original_parsed_record
    with_session([user_message("hi")]) do |reader|
      raw = reader.messages.first.raw
      assert_equal "response_item", raw["type"]
      assert_equal "hi", raw.dig("payload", "content", 0, "text")
    end
  end

  # Rule 2: an unrecognized record becomes an :unknown part and a warning,
  # never an exception. Codex added world_state and
  # inter_agent_communication_metadata in July 2026 without asking anyone.
  def test_an_unknown_payload_type_becomes_an_unknown_part_with_a_warning
    record = { type: "response_item", timestamp: STAMP, payload: { type: "telepathy_item", data: 1 } }
    with_session([record]) do |reader|
      part = reader.messages.first.parts.first
      assert_equal :unknown, part.type
      assert(reader.warnings.any? { |w| w.include?("telepathy_item") })
    end
  end

  # The next five shapes were invisible until the reader ran over all 415 real
  # files: a 25-file sample showed none of them. They are why the first reader
  # had to be written against an agent whose store is actually populated.

  # 129 real records. Codex's multi-agent traffic is a message with author and
  # recipient instead of role — conversation, not bookkeeping, and it was
  # landing in :unknown.
  def test_an_agent_message_is_read_as_conversation
    record = { type: "response_item", timestamp: STAMP,
               payload: { type: "agent_message", author: "agent", recipient: "orchestrator",
                          content: [{ type: "output_text", text: "found it" }] } }
    with_session([record]) do |reader|
      message = reader.messages.first
      assert_equal :assistant, message.role
      assert_equal "found it", message.text
      assert_empty reader.warnings
    end
  end

  # 288 real records, and unlike custom_tool_call it carries neither a name nor
  # a call_id — the name has to come from the record type itself.
  def test_a_web_search_call_is_a_tool_use_with_a_name_derived_from_its_type
    record = { type: "response_item", timestamp: STAMP,
               payload: { type: "web_search_call", status: "completed",
                          action: { type: "search", url: "https://example.com" } } }
    with_session([record]) do |reader|
      part = reader.messages.first.parts.first
      assert_equal :tool_use, part.type
      assert_equal "web_search", part.name
      assert_includes part.text, "https://example.com"
      assert_empty reader.warnings
    end
  end

  def test_a_tool_search_call_and_its_output_pair_by_call_id
    call = { type: "response_item", timestamp: STAMP,
             payload: { type: "tool_search_call", call_id: "call_9", status: "completed",
                        arguments: { limit: 5, query: "grep" } } }
    output = { type: "response_item", timestamp: STAMP,
               payload: { type: "tool_search_output", call_id: "call_9", status: "completed",
                          tools: [{ name: "grep", description: "search" }] } }
    with_session([call, output]) do |reader|
      use, result = reader.messages.map { |m| m.parts.first }
      assert_equal %i[tool_use tool_result], [use.type, result.type]
      assert_equal "call_9", use.call_id
      assert_equal "call_9", result.call_id
      assert_includes use.text, "grep"
      assert_empty reader.warnings
    end
  end

  # The one real image_generation_call carried a 2.5 MB base64 result. It stays
  # in raw: an :image part that inlined it would make every message carrying one
  # cost megabytes to hold, and the reader has no business decoding pixels.
  def test_an_image_generation_call_is_an_image_part_and_keeps_its_result_in_raw
    record = { type: "response_item", timestamp: STAMP,
               payload: { type: "image_generation_call", id: "ig_1", status: "completed",
                          revised_prompt: "a cat", result: "AAAABBBB" } }
    with_session([record]) do |reader|
      message = reader.messages.first
      assert_equal [:image], message.parts.map(&:type)
      assert_equal "", message.text
      assert_equal "AAAABBBB", message.raw.dig("payload", "result")
      assert_empty reader.warnings
    end
  end

  # 197 real records of internal git snapshot state. Not conversation, and
  # warning about a record the gem has deliberately classified would teach a
  # caller that warnings are noise.
  def test_a_ghost_snapshot_is_neither_a_message_nor_a_warning
    record = { type: "response_item", timestamp: STAMP,
               payload: { type: "ghost_snapshot", ghost_commit: { id: "abc", parent: "def" } } }
    with_session([user_message("hi"), record]) do |reader|
      assert_equal 1, reader.messages.size
      assert_empty reader.warnings
    end
  end

  # 80 real content items the model encrypted. The gem cannot read them and
  # never will, so they are :unknown — but they are RECOGNIZED, and warning
  # about a permanent, understood condition would be noise on every read.
  def test_encrypted_content_is_unknown_without_a_warning
    record = { type: "response_item", timestamp: STAMP,
               payload: { type: "message", role: "assistant",
                          content: [{ type: "encrypted_content", data: "gAAAAA" },
                                    { type: "output_text", text: "the answer" }] } }
    with_session([record]) do |reader|
      message = reader.messages.first
      assert_equal %i[unknown text], message.parts.map(&:type)
      assert_equal "the answer", message.text
      assert_empty reader.warnings
    end
  end

  def test_a_record_that_is_not_json_warns_instead_of_raising
    with_raw_file("{\"type\":\"response_item\"\nnot json at all\n") do |reader|
      assert_empty reader.messages
      assert(reader.warnings.any? { |w| w.match?(/line 1|line 2/) })
    end
  end

  # 14 records in the real corpus exceed 1 MB and the largest is 2.41 MB, so a
  # reader that skipped oversized records would drop real messages. It must
  # read them; only a record beyond all plausibility is refused, and loudly.
  def test_a_record_larger_than_the_layer_2_scan_cap_is_still_read
    big = "x" * 1_200_000
    with_session([user_message(big)]) do |reader|
      assert_equal 1, reader.messages.size
      assert_equal big.bytesize, reader.messages.first.text.bytesize
      assert_empty reader.warnings
    end
  end

  def test_a_record_beyond_the_hard_cap_is_reported_not_silently_dropped
    with_session([user_message("y" * 9_000_000)]) do |reader|
      assert_empty reader.messages
      assert(reader.warnings.any? { |w| w.include?("too large") })
    end
  end

  # Streaming, rule 3: each_message must yield before the file is exhausted.
  def test_each_message_yields_without_reading_the_whole_file
    records = Array.new(50) { |i| user_message("m#{i}") }
    with_session(records) do |reader|
      first = nil
      reader.each_message { |message| first = message; break }
      assert_equal "m0", first.text
    end
  end

  # Shapes and semantics from a real rollout on this machine (2026-08-24):
  # total_token_usage is a running total, so the LAST token_count record is
  # the session — an earlier record's smaller totals must not survive — and
  # its input_tokens includes cached_input_tokens, so the reader subtracts to
  # match Usage's disjoint contract (33,431 including 19,200 in the sample).
  def test_usage_is_the_last_token_count_with_cached_input_made_disjoint
    records = [user_message("hi"),
               token_count(input: 33_431, cached: 19_200, output: 320, reasoning: 213),
               token_count(input: 68_554, cached: 51_712, cache_write: 40, output: 581, reasoning: 281)]
    with_session(records) do |reader|
      usage = reader.usage
      assert_equal 68_554 - 51_712, usage.input
      assert_equal 51_712, usage.cache_read
      assert_equal 40, usage.cache_creation
      assert_equal 581, usage.output
      assert_equal 281, usage.reasoning
      assert_nil usage.cost, "Codex reports no cost; nil must not become zero"
    end
  end

  def test_usage_is_nil_without_a_token_count_record
    with_session([user_message("hi"), event_msg("task_started")]) { |reader| assert_nil reader.usage }
  end

  # Codex writes no usage on the messages themselves — the totals live in
  # token_count event records — so a message-level nil is the format speaking,
  # not this reader failing to look.
  def test_messages_carry_no_usage_or_model
    with_session([assistant_message("hi")]) do |reader|
      assert_nil reader.messages.first.usage
      assert_nil reader.messages.first.model
    end
  end

  def test_reader_reports_the_adapter_fidelity_and_is_not_partial
    with_session([user_message("hi")]) do |reader|
      assert_equal :full, reader.fidelity
      refute_predicate reader, :partial?
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_session([user_message("hello")], **options, &block)
  end

  def conformance_unknown(&block)
    with_session([{ type: "response_item", timestamp: STAMP, payload: { type: "telepathy_item" } }], &block)
  end

  def conformance_broken(&block)
    with_raw_file("not json at all\n", &block)
  end

    STAMP = "2026-07-21T09:12:03.000Z"
    UUID = "00000000-0000-4000-8000-000000000001"

    # Not `message`: Minitest::Assertions defines its own `message`, and
    # overriding it breaks every assertion failure this file could report.
  def message_record(role, content_type, text)
    { type: "response_item", timestamp: STAMP,
      payload: { type: "message", role: role, content: [{ type: content_type, text: text }] } }
  end

  def user_message(text) = message_record("user", "input_text", text)
  def assistant_message(text) = message_record("assistant", "output_text", text)

  def reasoning(text)
    { type: "response_item", timestamp: STAMP,
      payload: { type: "reasoning", encrypted_content: "gAAAAA", content: nil,
                 summary: [{ type: "summary_text", text: text }] } }
  end

  def tool_call(name, call_id, input)
    { type: "response_item", timestamp: STAMP,
      payload: { type: "custom_tool_call", name: name, call_id: call_id,
                 input: input, status: "completed" } }
  end

  def tool_output(call_id, output)
    { type: "response_item", timestamp: STAMP,
      payload: { type: "custom_tool_call_output", call_id: call_id, output: output } }
  end

  def event_msg(type)
    { type: "event_msg", timestamp: STAMP, payload: { type: type, info: {} } }
  end

  # The running-total record, shaped as observed: totals under
  # info.total_token_usage, the per-turn slice beside it ignored by the reader.
  def token_count(input:, cached:, output:, reasoning:, cache_write: 0)
    { type: "event_msg", timestamp: STAMP,
      payload: { type: "token_count",
                 info: { total_token_usage: {
                   input_tokens: input, cached_input_tokens: cached,
                   cache_write_input_tokens: cache_write, output_tokens: output,
                   reasoning_output_tokens: reasoning,
                   total_tokens: input + output
                 }, model_context_window: 258_400 } } }
  end

  def compacted(texts)
    history = texts.map { |t| { type: "message", role: "user", content: t } }
    { type: "compacted", timestamp: STAMP,
      payload: { message: "", replacement_history: history } }
  end

  def session_meta
    { type: "session_meta", timestamp: STAMP,
      payload: { id: UUID, cwd: "/Users/you/app", cli_version: "0.0.0" } }
  end

  def with_session(records, **options)
    content = ([session_meta] + records).map { |r| JSON.generate(r) }.join("\n") + "\n"
    with_raw_file(content, **options) { |reader| yield reader }
  end

  def with_raw_file(content, **options)
    with_home do |home, env|
      write(content, home, ".codex", "sessions", "2026", "07", "21",
            "rollout-2026-07-21T09-12-03-#{UUID}.jsonl")
      session = AgentSessions.sessions(:codex, env: env).first
      yield AgentSessions.read(session, **options)
    end
  end
end
