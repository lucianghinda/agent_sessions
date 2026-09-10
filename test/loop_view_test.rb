# frozen_string_literal: true

require_relative "test_helper"

class LoopViewTest < Minitest::Test
  include FixtureHelpers

  # A renderer that drops the round-trip count from one format disagrees with
  # the other two about the same underlying Loop — the three outputs describe
  # one object and must not contradict each other on a fact this basic.
  def test_one_session_renders_three_ways
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "file contents" }

    with_session([user_turn("hi"), assistant_parts([call]), user_parts([result]),
                  assistant_turn("done")]) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash = view.to_h

      refute_empty ascii
      refute_empty markdown
      refute_empty hash

      count = hash.fetch(:round_trips).size
      assert_equal 4, count
      assert_includes ascii, count.to_s
      assert_includes markdown, count.to_s
    end
  end

  # A renderer that prints a stop REASON claims a fact the on-disk transcript
  # does not hold — no store records why a run stopped — so every rendering
  # must say "inferred", not state the ending as if it were recorded.
  def test_every_rendering_marks_the_ending_inferred
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }

    with_session([user_turn("read the file"), assistant_parts([call])]) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash = view.to_h

      assert_includes ascii, "inferred"
      assert_includes ascii, "a tool was asked for and nothing answered it"
      assert_includes markdown, "inferred"
      assert_includes markdown, "a tool was asked for and nothing answered it"
      assert hash.dig(:ending, :inferred)
      assert_equal :stopped_in_the_loop, hash.dig(:ending, :name)
    end
  end

  # Printing local times differs between two zones, and printing the path
  # differs between two homes — both would make one recorded file render
  # differently depending on which machine reads it, which R8 forbids.
  def test_rendering_is_deterministic_and_the_machine_cannot_change_it
    call = { type: "tool_use", id: "toolu_1", name: "Read", input: { file_path: "/tmp/x" } }
    records = [user_turn("hi"), assistant_parts([call])]

    first_ascii = first_markdown = first_hash = nil
    with_session(records) do |reader|
      view = view_for(reader)
      first_ascii = view.ascii
      first_markdown = view.markdown
      first_hash = view.to_h
    end

    original_tz = ENV["TZ"]
    begin
      ENV["TZ"] = "Pacific/Kiritimati" # about as far from UTC as a real zone gets
      with_session(records) do |reader| # a fresh, different throwaway HOME
        view = view_for(reader)
        assert_equal first_ascii, view.ascii
        assert_equal first_markdown, view.markdown
        assert_equal first_hash, view.to_h
      end
    ensure
      ENV["TZ"] = original_tz
    end
  end

  # A preview of the first forty characters would print both the token and
  # the password just as surely as printing the whole body would — the only
  # safe thing to print is a count, never a fragment of the content itself.
  def test_no_body_reaches_the_output
    call = { type: "tool_use", id: "toolu_1", name: "Bash", input: { command: "echo SECRET-TOKEN-123" } }
    result = { type: "tool_result", tool_use_id: "toolu_1", content: "SECRET-TOKEN-123" }
    prompt_text = "my password is hunter2"

    with_session([user_turn(prompt_text), assistant_parts([call]), user_parts([result])]) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash_dump = view.to_h.inspect

      [ascii, markdown, hash_dump].each do |rendering|
        refute_includes rendering, "SECRET-TOKEN-123"
        refute_includes rendering, "hunter2"
        refute_includes rendering, "password"
      end

      assert_includes ascii, "SECRET-TOKEN-123".bytesize.to_s
      assert_includes ascii, prompt_text.bytesize.to_s
    end
  end

  def test_events_appear_only_when_they_are_asked_for
    event = { type: "attachment", timestamp: STAMP, uuid: "u_event", attachment: { type: "hook_success" } }
    records = [user_turn("hi"), event]

    with_session(records, include_events: true) do |reader|
      assert_includes view_for(reader).ascii, "hook_success"
    end

    with_session(records) do |reader|
      refute_includes view_for(reader).ascii, "hook_success"
    end
  end

  # The label field is a free String, not a controlled vocabulary — R9 must
  # hold even the day a format starts putting a sentence there instead of a
  # short record-type name like hook_success.
  def test_a_free_text_event_label_is_not_printed_as_a_label
    sentence = "this hook's own explanation happens to leak hunter2 right here in its prose"
    event = { type: "attachment", timestamp: STAMP, uuid: "u_event", attachment: { type: sentence } }

    with_session([user_turn("hi"), event], include_events: true) do |reader|
      view = view_for(reader)
      ascii = view.ascii
      markdown = view.markdown
      hash_dump = view.to_h.inspect

      [ascii, markdown, hash_dump].each do |rendering|
        refute_includes rendering, "hunter2"
        refute_includes rendering, sentence
      end
      assert_includes ascii, "unknown" # falls back to the part's type name
    end
  end

  def test_an_unanswered_call_is_shown_as_no_answer_recorded_not_zero_bytes
    call = { type: "tool_use", id: "toolu_9", name: "Bash", input: { command: "ls" } }

    with_session([assistant_parts([call])]) do |reader|
      markdown = view_for(reader).markdown
      assert_includes markdown, "no answer recorded"
      refute_includes markdown, "0 B"
    end
  end

  # Loop#recorded is round_trips.all?(&:recorded), so one assumed group makes
  # the whole session read false — and on Claude, the one format that names its
  # groups, every user and harness turn has no message.id and is assumed by
  # construction. Printing that as the bare word "assumed" would tell a reader
  # Claude records no grouping at all, which is the confusion this gem's
  # standing rule forbids in both directions. So the line carries counts.
  def test_the_grouping_line_says_how_many_groups_the_store_named
    named = assistant_turn("ok")
    named[:message][:id] = "msg_1"

    with_session([user_turn("hi"), named]) do |reader|
      view = view_for(reader)
      assert reader.round_trips_recorded?, "Claude does record a round-trip id"
      assert_includes view.ascii, "1 of 2 named by the store"
      assert_includes view.markdown, "1 of 2 named by the store"
      refute_includes view.ascii, "(grouping: assumed)",
                      "a format that names groups must never read as naming none"
    end
  end

  # The other side of the same line: a session where the store named nothing
  # has to say so in words a reader cannot mistake for "there were none".
  def test_the_grouping_line_says_when_the_store_named_nothing
    with_session([user_turn("hi"), assistant_turn("ok")]) do |reader|
      view = view_for(reader)
      assert_includes view.ascii, "none named by the store"
      assert_includes view.ascii, "one round trip per message"
    end
  end

  private

  STAMP = "2026-08-04T13:55:06.852Z"
  SESSION = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
  PROJECT = "-Users-you-app"

  def view_for(reader) = Agent::Sessions::LoopView.new(Agent::Sessions::Loop.for(reader))

  def turn(role, content)
    { type: role, timestamp: STAMP, sessionId: SESSION, uuid: "u1", cwd: "/Users/you/app",
      isSidechain: false, message: { role: role, content: content } }
  end

  def user_turn(text) = turn("user", [{ type: "text", text: text }])
  def assistant_turn(text) = turn("assistant", [{ type: "text", text: text }])
  def user_parts(parts) = turn("user", parts)
  def assistant_parts(parts) = turn("assistant", parts)

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
