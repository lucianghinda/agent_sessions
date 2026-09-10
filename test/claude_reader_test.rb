# frozen_string_literal: true

require_relative "test_helper"

# Shapes taken from 142 real transcripts, 29,688 records, inventoried
# 2026-08-12: assistant 11,443, user 6,601, attachment 3,161, last-prompt
# 1,892, mode 1,613, ai-title 1,399, permission-mode 1,128, system 866,
# file-history-delta 634, queue-operation 455, file-history-snapshot 405,
# agent-name 69, pr-link 22. Content parts: tool_use 5,796, tool_result 5,795,
# thinking 3,126, text 2,693, image 6 — a 1:1 match with this gem's vocabulary.
class ClaudeReaderTest < Minitest::Test
  include FixtureHelpers
  include ReaderConformance

  def test_reads_user_and_assistant_turns
    with_session([user_turn("hello"), assistant_turn("hi there")]) do |reader|
      assert_equal %i[user assistant], reader.messages.map(&:role)
      assert_equal ["hello", "hi there"], reader.messages.map(&:text)
    end
  end

  # 636 of 18,044 real messages carry content as a bare String rather than an
  # array of parts. Both spellings are the same thing and must read alike.
  def test_string_content_reads_the_same_as_a_single_text_part
    record = turn("user", "just a string")
    with_session([record]) do |reader|
      assert_equal [:text], reader.messages.first.parts.map(&:type)
      assert_equal "just a string", reader.messages.first.text
    end
  end

  def test_thinking_tool_use_and_tool_result_parts
    parts = [{ type: "thinking", thinking: "let me check" },
             { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }]
    result = [{ type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }]

    with_session([assistant_parts(parts), user_parts(result)]) do |reader|
      thinking, tool_use = reader.messages.first.parts
      assert_equal :thinking, thinking.type
      assert_equal "let me check", thinking.text
      assert_equal :tool_use, tool_use.type
      assert_equal "Read", tool_use.name
      assert_equal "toolu_1", tool_use.call_id

      tool_result = reader.messages.last.parts.first
      assert_equal :tool_result, tool_result.type
      assert_equal "toolu_1", tool_result.call_id
      assert_equal "file contents", tool_result.text
    end
  end

  def test_an_image_part_keeps_its_payload_in_raw
    parts = [{ type: "image", source: { type: "base64", media_type: "image/png", data: "AAAA" } }]
    with_session([user_parts(parts)]) do |reader|
      assert_equal [:image], reader.messages.first.parts.map(&:type)
      assert_equal "", reader.messages.first.text
      assert_equal "AAAA", reader.messages.first.raw.dig("message", "content", 0, "source", "data")
    end
  end

  # Eleven record types carry session state, not conversation: ai-title, mode,
  # permission-mode, agent-name, last-prompt, file-history-snapshot,
  # file-history-delta, queue-operation, pr-link, plus atis-latch and
  # bridge-session (which postdate the 2026-08-12 corpus — observed live,
  # 2026-08-24). Together they are a third of every record written, and none
  # of them is a turn.
  def test_session_state_records_are_neither_messages_nor_warnings
    state = [{ type: "ai-title", aiTitle: "fixing the parser", sessionId: SESSION },
             { type: "mode", mode: "default", sessionId: SESSION },
             { type: "permission-mode", permissionMode: "default", sessionId: SESSION },
             { type: "last-prompt", lastPrompt: "go on", leafUuid: "u1", sessionId: SESSION },
             { type: "file-history-snapshot", messageId: "m1", snapshot: {}, isSnapshotUpdate: false },
             { type: "file-history-delta", messageId: "m1", trackingPath: "/tmp/x", backup: {} },
             { type: "queue-operation", operation: "enqueue", content: "later", sessionId: SESSION },
             { type: "pr-link", prNumber: 3, prUrl: "https://example.com", sessionId: SESSION },
             { type: "agent-name", agentName: "claude", sessionId: SESSION },
             { type: "atis-latch", atis: "", sessionId: SESSION },
             { type: "bridge-session", sessionId: SESSION, bridgeSessionId: "cse_1",
               lastSequenceNum: 0 }]

    with_session([user_turn("hi")] + state) do |reader|
      assert_equal 1, reader.messages.size
      assert_empty reader.warnings
    end
  end

  # system (866 real records: turn_duration, stop_hook_summary, away_summary,
  # local_command) and attachment (3,161: hook output, skill listings, task
  # reminders) are context the model saw, not turns anyone took. Same judgement
  # as Codex's event_msg: available, never on by default.
  def test_system_and_attachment_records_are_opt_in
    records = [user_turn("hi"),
               { type: "system", subtype: "turn_duration", durationMs: 12, timestamp: STAMP },
               { type: "attachment", timestamp: STAMP,
                 attachment: { type: "hook_success", hookName: "PostToolUse", stdout: "ok" } }]

    with_session(records) { |reader| assert_equal 1, reader.messages.size }
    with_session(records, include_events: true) do |reader|
      assert_equal 3, reader.messages.size
      assert_equal %i[user system system], reader.messages.map(&:role)
      assert_empty reader.warnings
    end
  end

  # The spill: Claude Code writes oversized tool output to a file beside the
  # transcript and leaves prose pointing at it. 24 real tool_result parts do
  # this. Resolving it is what makes a :tool_result part carry content rather
  # than a pointer (design doc 8.1).
  def test_a_spilled_tool_result_is_resolved_from_the_sidecar_file
    with_home do |home, env|
      spill = write("the whole 40 KB of output", sidecar(home), "tool-results", "hook-1.txt")
      result = [{ type: "tool_result", tool_use_id: "toolu_1",
                  content: "Output too large (40.0KB). Full output saved to: #{spill}" }]
      write_transcript(home, [user_parts(result)])

      reader = read_session(env)
      part = reader.messages.first.parts.first
      assert_equal "the whole 40 KB of output", part.text
      assert_empty reader.warnings
    end
  end

  # The path comes from tool output, which is untrusted input. A transcript
  # that says the spill lives in /etc/passwd must not turn this reader into a
  # file-read primitive: only the session's own sidecar directory is readable.
  def test_a_spill_path_outside_the_session_sidecar_is_not_read
    with_home do |home, env|
      outside = write("secret", home, "elsewhere", "tool-results", "hook-1.txt")
      pointer = "Output too large (40.0KB). Full output saved to: #{outside}"
      write_transcript(home, [user_parts([{ type: "tool_result", tool_use_id: "t1", content: pointer }])])

      reader = read_session(env)
      assert_equal pointer, reader.messages.first.parts.first.text
      assert(reader.warnings.any? { |w| w.include?("outside") })
    end
  end

  # A subagent transcript lives at <parent-id>/subagents/agent-X.jsonl and its
  # oversized output spills to <parent-id>/tool-results/, the PARENT's
  # directory — it has no sidecar of its own. Found by running this reader over
  # 124 real subagent transcripts, where a boundary drawn at the subagent's own
  # id refused every spill it referenced.
  def test_a_subagent_resolves_a_spill_from_the_parent_sidecar_tree
    with_home do |home, env|
      spill = write("the subagent's long output", sidecar(home), "tool-results", "bngm9.txt")
      pointer = "Output too large (40.0KB). Full output saved to: #{spill}"
      write("#{JSON.generate(user_parts([{ type: "tool_result", tool_use_id: "t1", content: pointer }]))}\n",
            sidecar(home), "subagents", "agent-a38c671ab8c.jsonl")
      write_transcript(home, [user_turn("parent work")])

      subagent = read_session(env).subagents.first
      assert_equal "the subagent's long output", subagent.messages.first.parts.first.text
      assert_empty subagent.warnings
    end
  end

  def test_a_missing_spill_file_keeps_the_pointer_and_warns
    with_home do |home, env|
      missing = File.join(sidecar(home), "tool-results", "gone.txt")
      pointer = "Output too large (40.0KB). Full output saved to: #{missing}"
      write_transcript(home, [user_parts([{ type: "tool_result", tool_use_id: "t1", content: pointer }])])

      reader = read_session(env)
      assert_equal pointer, reader.messages.first.parts.first.text
      assert(reader.warnings.any? { |w| w.include?("could not be read") })
    end
  end

  def test_spill_resolution_can_be_turned_off
    with_home do |home, env|
      spill = write("the whole output", sidecar(home), "tool-results", "hook-1.txt")
      pointer = "Output too large (40.0KB). Full output saved to: #{spill}"
      write_transcript(home, [user_parts([{ type: "tool_result", tool_use_id: "t1", content: pointer }])])

      reader = read_session(env, resolve_spills: false)
      assert_equal pointer, reader.messages.first.parts.first.text
    end
  end

  # 124 subagent transcripts sit on disk beside real sessions. They are exposed
  # rather than inlined: a subagent's turns are not the parent's turns, and
  # merging them would break every count taken from this reader.
  def test_subagent_transcripts_are_exposed_but_never_inlined
    with_home do |home, env|
      write("#{JSON.generate(user_turn("subagent work"))}\n",
            sidecar(home), "subagents", "agent-0198fa3c1122.jsonl")
      write_transcript(home, [user_turn("parent work")])

      reader = read_session(env)
      assert_equal ["parent work"], reader.messages.map(&:text)
      assert_equal 1, reader.subagents.size
      assert_equal ["subagent work"], reader.subagents.first.messages.map(&:text)
    end
  end

  def test_a_session_without_a_sidecar_has_no_subagents
    with_session([user_turn("hi")]) { |reader| assert_empty reader.subagents }
  end

  # 380 branch points across 85 of 151 real transcripts, fan-out 2: a turn was
  # edited and re-run, so one parent has two alternative continuations. Read in
  # file order those are two histories interleaved with nothing marking where
  # one ends.
  def test_a_branch_becomes_two_children_of_one_parent
    records = [linked("user", "u1", nil, "start"),
               linked("assistant", "u2", "u1", "first answer"),
               linked("assistant", "u3", "u1", "second answer after an edit")]

    with_session(records) do |reader|
      roots = reader.tree
      assert_equal 1, roots.size
      assert_equal "start", roots.first.message.text
      assert_equal ["first answer", "second answer after an edit"],
                   roots.first.children.map { |child| child.message.text }
    end
  end

  def test_linked_turn_serializes_without_duplicate_json_keys
    document = nil

    assert_silent { document = JSON.generate(linked("assistant", "u2", "u1", "hello")) }
    assert_equal 1, document.scan(/"uuid":/).size
    assert_equal "u2", JSON.parse(document).fetch("uuid")
  end

  def test_a_linear_conversation_is_a_chain_of_single_children
    records = [linked("user", "u1", nil, "one"),
               linked("assistant", "u2", "u1", "two"),
               linked("user", "u3", "u2", "three")]

    with_session(records) do |reader|
      root = reader.tree.first
      assert_equal "one", root.message.text
      assert_equal "two", root.children.first.message.text
      assert_equal "three", root.children.first.children.first.message.text
    end
  end

  # 5,006 of the 25,633 uuid-bearing records are attachments and system
  # records, which sit in the parent chain without being turns. A message whose
  # recorded parent is one of those must attach to the nearest ancestor that IS
  # a message, or the tree loses turns that `messages` reports.
  def test_non_message_records_in_the_chain_are_transparent
    records = [linked("user", "u1", nil, "question"),
               { type: "attachment", uuid: "u2", parentUuid: "u1", timestamp: STAMP,
                 attachment: { type: "hook_success" } },
               linked("assistant", "u3", "u2", "answer")]

    with_session(records) do |reader|
      root = reader.tree.first
      assert_equal "question", root.message.text
      assert_equal ["answer"], root.children.map { |child| child.message.text }
    end
  end

  def test_the_tree_holds_exactly_the_messages_the_reader_reports
    records = [linked("user", "u1", nil, "a"),
               linked("assistant", "u2", "u1", "b"),
               linked("assistant", "u3", "u1", "c")]

    with_session(records) do |reader|
      flattened = []
      walk = lambda do |node|
        flattened << node.message.text
        node.children.each { |child| walk.call(child) }
      end
      reader.tree.each { |root| walk.call(root) }
      assert_equal reader.messages.map(&:text).sort, flattened.sort
    end
  end

  def test_claude_declares_itself_branching
    with_session([user_turn("hi")]) { |reader| assert_predicate reader, :branching? }
  end

  def test_an_unrecognized_record_type_warns_and_becomes_unknown
    with_session([{ type: "telepathy", sessionId: SESSION, timestamp: STAMP }]) do |reader|
      assert_equal [:unknown], reader.messages.first.parts.map(&:type)
      assert(reader.warnings.any? { |w| w.include?("telepathy") })
    end
  end

  def test_messages_carry_the_record_timestamp
    with_session([user_turn("hi")]) do |reader|
      assert_equal Time.utc(2026, 8, 4, 13, 55, 6, 852_000), reader.messages.first.at
    end
  end

  # Field names from a real transcript on this machine (2026-08-24):
  # input_tokens is disjoint from both cache counts (Anthropic semantics), and
  # thinking tokens sit under output_tokens_details.
  def test_an_assistant_message_carries_its_usage_and_model
    with_session([user_turn("hi"), billed_turn(id: "msg_1", input: 2, output: 1878)]) do |reader|
      user, assistant = reader.messages
      assert_nil user.usage
      assert_nil user.model

      assert_equal "claude-fable-5", assistant.model
      assert_equal 2, assistant.usage.input
      assert_equal 1878, assistant.usage.output
      assert_equal 24_332, assistant.usage.cache_read
      assert_equal 36_105, assistant.usage.cache_creation
      assert_equal 383, assistant.usage.reasoning
      assert_nil assistant.usage.cost, "Claude reports no cost; nil must not become zero"
    end
  end

  # One API response streams into one record per content block, every record
  # repeating the same message.id and the same usage: 260 assistant records
  # share 124 ids in one real transcript, 94 ids repeating with identical
  # usage. The session total must count each id once, or it roughly doubles.
  def test_usage_counts_a_repeated_message_id_once
    records = [billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_2", input: 7, output: 3)]
    with_session(records) do |reader|
      assert_equal 17, reader.usage.input
      assert_equal 8, reader.usage.output
    end
  end

  def test_usage_is_nil_when_no_record_carries_any
    with_session([user_turn("hi")]) { |reader| assert_nil reader.usage }
  end

  # "1234" where a count belongs is not a count. One malformed field must
  # not poison the sum; the others still count.
  def test_a_non_integer_count_is_absent_rather_than_wrong
    record = billed_turn(id: "msg_1", input: 10, output: 5)
    record[:message][:usage][:input_tokens] = "not a number"
    with_session([record]) do |reader|
      assert_nil reader.usage.input
      assert_equal 5, reader.usage.output
    end
  end

  def test_reader_reports_full_fidelity
    with_session([user_turn("hi")]) do |reader|
      assert_equal :full, reader.fidelity
      refute_predicate reader, :partial?
    end
  end

  # Grouping per record would answer three round trips here — the bug this
  # feature fixes. One API response streams into one record per content
  # block, all three sharing one message.id, so it must group to one.
  def test_records_of_one_model_answer_become_one_round_trip
    records = [billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_1", input: 10, output: 5)]
    with_session(records) do |reader|
      round_trips = reader.round_trips
      assert_equal 1, round_trips.size
      assert_equal 3, round_trips.first.messages.size
      assert round_trips.first.recorded
    end
  end

  def test_claude_reports_that_round_trip_grouping_is_recorded
    with_session([user_turn("hi")]) { |reader| assert reader.round_trips_recorded? }
  end

  # each_round_trip must stream: reaching round trip 1 must not require
  # parsing every one of 50 records. A subclass that counts calls to the
  # private message_for proves it directly, rather than trusting that a
  # fast test means little work happened.
  def test_round_trips_stream
    records = Array.new(50) { |i| billed_turn(id: "msg_#{i}", input: 1, output: 1) }
    with_session(records) do |reader|
      assert_kind_of Enumerator, reader.each_round_trip

      counting_reader = CountingReader.new(reader.session)
      first_round_trip = counting_reader.each_round_trip.first
      refute_nil first_round_trip
      assert_operator counting_reader.message_for_calls, :<, 50
    end
  end

  # Summing per record roughly doubles the bill: Claude repeats one API
  # response's usage byte-for-byte on every record of that response.
  def test_round_trip_usage_is_counted_once_per_model_answer
    records = [billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_1", input: 10, output: 5)]
    with_session(records) do |reader|
      usage = reader.round_trips.first.usage
      assert_equal 10, usage.input
      assert_equal 5, usage.output
    end
  end

  # Nothing answers a tool between the two A runs, so the reappearance has no
  # explanation this reader knows and is worth a line.
  def test_a_round_trip_id_that_reappears_unexplained_opens_a_new_group_and_warns
    records = [billed_turn(id: "A-id-value", input: 1, output: 1),
               billed_turn(id: "B-id-value", input: 1, output: 1),
               billed_turn(id: "A-id-value", input: 1, output: 1)]
    with_session(records) do |reader|
      assert_equal 3, reader.round_trips.size
      assert(reader.warnings.any? { |w| w.include?("A-id-value") })
    end
  end

  # The same reappearance, with the tool answer that explains it. Claude Code
  # writes each tool_result immediately after the tool_use it answers while
  # every content block of the one response keeps its message.id, so a response
  # making two calls is split by the result in between. Measured over the 60
  # most recent real transcripts on this machine (2026-09-10): 261 of 3,315
  # message.ids are split this way, across 33 of the 60 files. Warning on it
  # would put four or five lines under every real session's loop view, so this
  # pins the silence as deliberately as the case above pins the warning.
  def test_a_round_trip_id_split_by_a_tool_answer_opens_a_new_group_in_silence
    call = assistant_parts([{ type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }])
    call[:message][:id] = "A-id-value"
    answer = user_parts([{ type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }])
    rest = assistant_parts([{ type: "text", text: "done" }])
    rest[:message][:id] = "A-id-value"

    with_session([call, answer, rest]) do |reader|
      assert_equal 3, reader.round_trips.size, "the run is still split; only the warning changes"
      assert_empty reader.warnings.grep(/reappears/),
                   "a split explained by a tool answer must not be reported as unexplained"
    end
  end

  def test_a_group_whose_records_disagree_on_usage_reports_the_first_and_says_so
    records = [billed_turn(id: "msg_1", input: 10, output: 5),
               billed_turn(id: "msg_1", input: 99, output: 99)]
    with_session(records) do |reader|
      usage = reader.round_trips.first.usage
      assert_equal 10, usage.input
      assert_equal 5, usage.output
      assert(reader.warnings.any? { |w| w.include?("disagree") })
    end
  end

  # Pins the honest fallback inside a format that otherwise records ids: a
  # user turn carries no message.id, so it stays its own assumed round trip
  # even though the assistant turn beside it is a recorded one.
  def test_a_claude_user_turn_is_its_own_assumed_round_trip
    with_session([user_turn("hello"), billed_turn(id: "msg_1", input: 1, output: 1)]) do |reader|
      user_round_trip, assistant_round_trip = reader.round_trips
      assert_equal 2, reader.round_trips.size
      refute user_round_trip.recorded
      assert assistant_round_trip.recorded
    end
  end

  # RoundTrip's own readers, over messages a real transcript would produce
  # for one turn each. Parts and calls read across every message the group
  # holds, in the order the file wrote them; roles reports who actually
  # spoke in that group.
  def test_round_trip_readers_expose_parts_calls_and_roles
    parts = [{ type: "thinking", thinking: "let me check" },
             { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }]
    result = [{ type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }]

    with_session([assistant_parts(parts), user_parts(result)]) do |reader|
      call_round_trip, result_round_trip = reader.round_trips

      assert_equal %i[thinking tool_use], call_round_trip.parts.map(&:type)
      assert_equal ["Read"], call_round_trip.calls.map(&:name)
      assert_equal [:assistant], call_round_trip.roles

      assert_equal [:tool_result], result_round_trip.parts.map(&:type)
      assert_empty result_round_trip.calls
      assert_equal [:user], result_round_trip.roles
    end
  end

  # Counts calls to the private message_for so test_round_trips_stream can
  # prove each_round_trip yields before the file is exhausted, rather than
  # just trusting that a fast test means little work happened.
  class CountingReader < Agent::Sessions::Readers::Claude
    attr_reader :message_for_calls

    def initialize(session, **rest)
      super
      @message_for_calls = 0
    end

    private

    def message_for(record, line_number)
      @message_for_calls += 1
      super
    end
  end

  private

  # --- reader conformance fixtures ---

  def conformance_hello(**options, &block)
    with_session([user_turn("hello")], **options, &block)
  end

  def conformance_unknown(&block)
    with_session([{ type: "telepathy", sessionId: SESSION, timestamp: STAMP }], &block)
  end

  def conformance_broken
    with_home do |home, env|
      write("not json at all\n", home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
      yield read_session(env)
    end
  end

    STAMP = "2026-08-04T13:55:06.852Z"
    SESSION = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    PROJECT = "-Users-you-app"

  def turn(role, content)
    { type: role, timestamp: STAMP, sessionId: SESSION, uuid: "u1", cwd: "/Users/you/app",
      isSidechain: false, message: { role: role, content: content } }
  end

  # A turn with explicit tree links, as every real record carries them.
  def linked(role, uuid, parent_uuid, text)
    turn(role, [{ type: "text", text: text }]).merge(uuid: uuid, parentUuid: parent_uuid)
  end

  def user_turn(text) = turn("user", [{ type: "text", text: text }])
  def assistant_turn(text) = turn("assistant", [{ type: "text", text: text }])

  # An assistant record the way the API writes it: model and usage beside the
  # content, cache and thinking counts shaped as observed on this machine.
  def billed_turn(id:, input:, output:)
    record = assistant_turn("ok")
    record[:message].merge!(
      id: id, model: "claude-fable-5",
      usage: { input_tokens: input, output_tokens: output,
               cache_read_input_tokens: 24_332, cache_creation_input_tokens: 36_105,
               output_tokens_details: { thinking_tokens: 383 } }
    )
    record
  end
  def user_parts(parts) = turn("user", parts)
  def assistant_parts(parts) = turn("assistant", parts)

  def sidecar(home) = File.join(home, ".claude", "projects", PROJECT, SESSION)

  def write_transcript(home, records)
    content = records.map { |r| JSON.generate(r) }.join("\n") + "\n"
    write(content, home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
  end

  def read_session(env, **options)
    Agent::Sessions.read(Agent::Sessions.sessions(:claude, env: env).first, **options)
  end

  def with_session(records, **options)
    with_home do |home, env|
      write_transcript(home, records)
      yield read_session(env, **options)
    end
  end
end
