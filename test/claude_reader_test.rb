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

  # Nine record types carry session state, not conversation: ai-title, mode,
  # permission-mode, agent-name, last-prompt, file-history-snapshot,
  # file-history-delta, queue-operation, pr-link. Together they are a third of
  # every record written, and none of them is a turn.
  def test_session_state_records_are_neither_messages_nor_warnings
    state = [{ type: "ai-title", aiTitle: "fixing the parser", sessionId: SESSION },
             { type: "mode", mode: "default", sessionId: SESSION },
             { type: "permission-mode", permissionMode: "default", sessionId: SESSION },
             { type: "last-prompt", lastPrompt: "go on", leafUuid: "u1", sessionId: SESSION },
             { type: "file-history-snapshot", messageId: "m1", snapshot: {}, isSnapshotUpdate: false },
             { type: "file-history-delta", messageId: "m1", trackingPath: "/tmp/x", backup: {} },
             { type: "queue-operation", operation: "enqueue", content: "later", sessionId: SESSION },
             { type: "pr-link", prNumber: 3, prUrl: "https://example.com", sessionId: SESSION },
             { type: "agent-name", agentName: "claude", sessionId: SESSION }]

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

  def test_reader_reports_full_fidelity
    with_session([user_turn("hi")]) do |reader|
      assert_equal :full, reader.fidelity
      refute_predicate reader, :partial?
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
    turn(role, [{ type: "text", text: text }]).merge("uuid" => uuid, "parentUuid" => parent_uuid)
  end

  def user_turn(text) = turn("user", [{ type: "text", text: text }])
  def assistant_turn(text) = turn("assistant", [{ type: "text", text: text }])
  def user_parts(parts) = turn("user", parts)
  def assistant_parts(parts) = turn("assistant", parts)

  def sidecar(home) = File.join(home, ".claude", "projects", PROJECT, SESSION)

  def write_transcript(home, records)
    content = records.map { |r| JSON.generate(r) }.join("\n") + "\n"
    write(content, home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
  end

  def read_session(env, **options)
    AgentSessions.read(AgentSessions.sessions(:claude, env: env).first, **options)
  end

  def with_session(records, **options)
    with_home do |home, env|
      write_transcript(home, records)
      yield read_session(env, **options)
    end
  end
end
