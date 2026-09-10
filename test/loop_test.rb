# frozen_string_literal: true

require_relative "test_helper"

class LoopTest < Minitest::Test
  include FixtureHelpers

  # Pairing must go by call id: two calls can be in flight at once, and
  # pairing by position would match the wrong call to the wrong result.
  def test_a_call_is_paired_with_the_result_that_answered_it
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([assistant_parts([call]), user_parts([result])]) do |reader|
      loop = Agent::Sessions::Loop.for(reader)

      assert_equal 1, loop.tool_calls.size
      tool_call = loop.tool_calls.first
      assert_equal "Read", tool_call.name
      assert_equal "toolu_1", tool_call.call_id
      assert tool_call.answered?
      assert_equal "file contents".bytesize, tool_call.result_bytes
      assert_operator tool_call.answered_in, :>, tool_call.asked_in
    end
  end

  # A call nothing answers must report NO result, never a 0-byte one — 0 would
  # claim an empty answer was recorded when nothing was recorded at all.
  def test_a_call_nothing_answered_reports_no_result_rather_than_an_empty_one
    call = { type: "tool_use", id: "toolu_9", name: "Bash", input: { command: "ls" } }

    with_session([assistant_parts([call])]) do |reader|
      loop = Agent::Sessions::Loop.for(reader)
      tool_call = loop.tool_calls.first

      refute tool_call.answered?
      assert_nil tool_call.result_bytes
      assert_nil tool_call.answered_in
    end
  end

  def test_a_result_answering_no_call_is_reported_and_rendered_nowhere
    result = { type: "tool_result", tool_use_id: "toolu_x", content: "orphan" }

    with_session([user_parts([result])]) do |reader|
      loop = Agent::Sessions::Loop.for(reader)

      assert_empty loop.tool_calls
      assert(loop.warnings.any? { |w| w.include?("toolu_x") })
    end
  end

  def test_a_broken_store_renders_empty_and_warns
    conformance_broken do |reader|
      loop = Agent::Sessions::Loop.for(reader)

      assert_empty loop.round_trips
      refute loop.recorded
      refute_empty loop.warnings
    end
  end

  # Choosing the speaker from the first part alone would call this a person's
  # prompt, because Claude files a tool result as a `user` message. This shape
  # was NOT observed in the real corpus — 0 of 3,933 real user records with
  # array content mix a tool_result with another part type (measured
  # 2026-09-09) — so it is specified as reported-but-not-observed, not an
  # ordinary case.
  def test_a_record_mixing_a_tool_result_with_other_parts_is_harness_output_and_is_reported
    mixed = [{ type: "tool_result", tool_use_id: "toolu_1", content: "file contents" },
             { type: "text", text: "here you go" }]

    with_session([user_parts(mixed)]) do |reader|
      loop = Agent::Sessions::Loop.for(reader)
      round_trip = loop.round_trips.first

      assert_equal :harness, loop.speakers[round_trip.index]
      assert(loop.warnings.any? { |w| w.include?("round trip #{round_trip.index}") })
    end
  end

  # Pins T1 rows 2 and 3, the distinction the whole table exists for: a plain
  # prompt is a person, and a message carrying only a tool result is the
  # harness, even though both are filed under the `user` role.
  def test_the_speaker_is_read_from_the_parts_not_the_role
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([user_turn("hello"), user_parts([result])]) do |reader|
      loop = Agent::Sessions::Loop.for(reader)
      prompt_round_trip, result_round_trip = loop.round_trips

      assert_equal :person, loop.speakers[prompt_round_trip.index]
      assert_equal :harness, loop.speakers[result_round_trip.index]
    end
  end

  def test_an_empty_session_is_not_marked_recorded
    with_home do |home, env|
      write("", home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
      loop = Agent::Sessions::Loop.for(read_session(env))

      refute loop.recorded
    end
  end

  private

  STAMP = "2026-08-04T13:55:06.852Z"
  SESSION = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  PROJECT = "-Users-you-app"

  def turn(role, content)
    { type: role, timestamp: STAMP, sessionId: SESSION, uuid: "u1", cwd: "/Users/you/app",
      isSidechain: false, message: { role: role, content: content } }
  end

  def user_turn(text) = turn("user", [{ type: "text", text: text }])
  def assistant_turn(text) = turn("assistant", [{ type: "text", text: text }])
  def user_parts(parts) = turn("user", parts)
  def assistant_parts(parts) = turn("assistant", parts)

  def conformance_broken
    with_home do |home, env|
      write("not json at all\n", home, ".claude", "projects", PROJECT, "#{SESSION}.jsonl")
      yield read_session(env)
    end
  end

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
