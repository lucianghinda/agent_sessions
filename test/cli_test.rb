# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/agent_sessions/cli"

class CLITest < Minitest::Test
  include FixtureHelpers

  def run_cli(*argv, env:)
    stdout = StringIO.new
    stderr = StringIO.new
    status = AgentSessions::CLI.new(argv, env: env, stdout: stdout, stderr: stderr).run
    [status, stdout.string, stderr.string]
  end

  def test_where_lists_every_agent
    with_home do |_home, env|
      status, out, = run_cli("where", env: env)
      assert_equal 0, status
      assert_includes out, "Claude Code"
      assert_includes out, "Codex CLI"
      assert_includes out, "opencode"
    end
  end

  def test_where_marks_agents_not_installed
    with_home do |_home, env|
      _, out, = run_cli("where", env: env)
      assert_includes out, "(not installed)"
    end
  end

  def test_where_single_agent_json
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      status, out, = run_cli("where", "claude", "--json", env: env)
      assert_equal 0, status
      payload = JSON.parse(out)
      assert_equal "claude", payload.first.fetch("agent")
      assert_equal File.join(home, ".claude", "projects"), payload.first.dig("effective", "path")
      assert_equal "2026-08-05", payload.first.fetch("verified_on")
    end
  end

  def test_unknown_agent_exits_nonzero_with_message
    with_home do |_home, env|
      status, _, err = run_cli("where", "wat", env: env)
      assert_equal 1, status
      assert_includes err, "unknown agent"
    end
  end

  def test_unknown_command_shows_help
    with_home do |_home, env|
      status, _, err = run_cli("frobnicate", env: env)
      assert_equal 1, status
      assert_includes err, "unknown command: frobnicate"
      assert_includes err, "Usage"
    end
  end

  def test_doctor_exit_code_reflects_failures
    with_home do |home, env|
      # history.jsonl proves codex records data here; the missing required
      # sessions store is then a real failure, not a never-used skip.
      touch(home, ".codex", "history.jsonl")
      status, out, = run_cli("doctor", "codex", env: env)
      assert_equal 1, status
      assert_includes out, "✗"
    end
  end

  def test_doctor_json
    with_home do |_home, env|
      status, out, = run_cli("doctor", "claude", "--json", env: env)
      assert_equal 0, status
      statuses = JSON.parse(out).map { |c| c.fetch("status") }
      assert_includes statuses, "skip"
    end
  end

  def test_audit_reports_totals
    with_home do |home, env|
      write("x" * 10, home, ".claude", "projects", "-p", "s.jsonl")
      status, out, = run_cli("audit", env: env)
      assert_equal 0, status
      assert_includes out, "synced locations"
    end
  end

  def test_version
    with_home do |_home, env|
      _, out, = run_cli("version", env: env)
      assert_includes out, AgentSessions::VERSION
    end
  end

  def test_unknown_flag_reports_cleanly
    with_home do |_home, env|
      status, _, err = run_cli("where", "--bogus", env: env)
      assert_equal 1, status
      assert_includes err, "invalid option"
    end
  end

  def test_byte_scale_sizes_have_no_decimal
    with_home do |home, env|
      write("x" * 814, home, ".claude", "projects", "-p", "s.jsonl")
      _, out, = run_cli("audit", env: env)
      assert_includes out, "814 B"
      refute_includes out, "814.0 B"
    end
  end

  def test_audit_aligns_columns
    with_home do |home, env|
      write("x" * 5, home, ".claude", "projects", "-p", "s.jsonl")
      write("x" * 500_000, home, ".claude", "history.jsonl")
      _, out, = run_cli("audit", env: env)
      offsets = out.lines.filter_map { |line| line.index(home) }
      assert_equal 1, offsets.uniq.size, out
    end
  end

  def claude_fixture(home, project: "/Users/you/app", id: "aa11", mtime: Time.now)
    encoded = project.gsub(/[^a-zA-Z0-9]/, "-")
    line = JSON.generate({ type: "attachment", cwd: project })
    path = write(line, home, ".claude", "projects", encoded, "#{id}.jsonl")
    FileUtils.touch(path, mtime: mtime)
    path
  end

  # Cursor's ids are two nested uuids joined by "/", so one Cursor row would
  # otherwise set the shared id_width to 73 where every other agent needs 36 —
  # padding every other row and pushing lines past 80 columns. No machine in
  # this suite has Cursor sessions, so nothing exercises the cap incidentally.
  def test_long_ids_are_elided_so_one_agent_cannot_widen_every_row
    cli = AgentSessions::CLI.new([])
    long = "0192aa11-2b3c-4d5e-8f90-a1b2c3d4e5f6/0192bb22-3c4d-5e6f-8091-b2c3d4e5f607"
    elided = cli.send(:elide, long)

    assert_operator elided.length, :<=, AgentSessions::CLI::ID_COLUMN_MAX
    assert elided.start_with?("0192aa11"), "kept the head: #{elided}"
    assert elided.end_with?("b2c3d4e5f607"), "kept the tail: #{elided}"

    short = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    assert_equal short, cli.send(:elide, short), "an id inside the cap is untouched"
  end

  def test_list_shows_sessions_newest_first
    with_home do |home, env|
      claude_fixture(home, id: "older", mtime: Time.now - 7200)
      claude_fixture(home, id: "newer", mtime: Time.now)
      status, out, = run_cli("list", env: env)
      assert_equal 0, status
      assert out.index("newer") < out.index("older"), "expected newest first:\n#{out}"
      assert_includes out, "claude"
    end
  end

  def test_list_agent_flag_scopes_to_one_agent
    with_home do |home, env|
      claude_fixture(home)
      # A full uuid is required here: Codex's FILENAME regex (Task 4) only
      # recognizes rollout-<timestamp>-<8-4-4-4-12 hex uuid>.jsonl. A short
      # placeholder like "u1" would silently fall back to the basename id,
      # which would still make this particular test pass (it only checks the
      # agent column) but would no longer be a faithful Codex fixture.
      codex_uuid = "11111111-1111-1111-1111-111111111111"
      write(JSON.generate({ type: "session_meta", payload: { cwd: "/x" } }),
            home, ".codex", "sessions", "2026", "07", "21", "rollout-2026-07-21T01-02-03-#{codex_uuid}.jsonl")
      _, out, = run_cli("list", "--agent", "codex", env: env)
      refute_includes out, "claude"
      assert_includes out, "codex"
    end
  end

  def test_list_since_filters_out_old_sessions
    with_home do |home, env|
      claude_fixture(home, id: "ancient", mtime: Time.now - (3 * 86_400))
      claude_fixture(home, id: "recent", mtime: Time.now)
      _, out, = run_cli("list", "--since", "1d", env: env)
      assert_includes out, "recent"
      refute_includes out, "ancient"
    end
  end

  def test_list_rejects_a_malformed_since
    with_home do |_home, env|
      status, _, err = run_cli("list", "--since", "fortnight", env: env)
      assert_equal 1, status
      assert_includes err, "fortnight"
    end
  end

  # "fortnight" has no digits at all, so it cannot tell an anchored regex from
  # an unanchored one — either rejects it for the same reason. Junk around an
  # otherwise-valid pattern is what actually exercises \A and \z: unanchored,
  # /(\d+)([hdw])/ finds "1d" inside either string via a plain search and
  # would silently accept both as one day.
  def test_list_rejects_since_with_leading_or_trailing_junk
    with_home do |_home, env|
      status, _, err = run_cli("list", "--since", "x1d", env: env)
      assert_equal 1, status
      assert_includes err, "x1d"

      status2, _, err2 = run_cli("list", "--since", "1dx", env: env)
      assert_equal 1, status2
      assert_includes err2, "1dx"
    end
  end

  # The one prior --since test used fixtures 3 days apart against a 1-day
  # window — wide enough that even a wrong multiplier (h and d swapped, or a
  # 604_800 typo'd to 86_400) would still happen to sort into the right
  # bucket. Straddling each unit's own boundary tightly is what actually pins
  # SINCE_UNITS's three values independently.
  def test_list_since_unit_multipliers_are_pinned_at_their_boundaries
    with_home do |home, env|
      claude_fixture(home, id: "within_hour", mtime: Time.now - (30 * 60))
      claude_fixture(home, id: "before_hour", mtime: Time.now - (90 * 60))
      claude_fixture(home, id: "within_day", mtime: Time.now - (12 * 3600))
      claude_fixture(home, id: "before_day", mtime: Time.now - (36 * 3600))
      claude_fixture(home, id: "within_week", mtime: Time.now - (6 * 86_400))
      claude_fixture(home, id: "before_week", mtime: Time.now - (8 * 86_400))

      _, hour_out, = run_cli("list", "--since", "1h", env: env)
      assert_includes hour_out, "within_hour"
      refute_includes hour_out, "before_hour"

      _, day_out, = run_cli("list", "--since", "1d", env: env)
      assert_includes day_out, "within_day"
      refute_includes day_out, "before_day"

      _, week_out, = run_cli("list", "--since", "1w", env: env)
      assert_includes week_out, "within_week"
      refute_includes week_out, "before_week"
    end
  end

  def test_list_project_filters_across_agents
    with_home do |home, env|
      claude_fixture(home, project: "/Users/you/app", id: "inproj")
      claude_fixture(home, project: "/Users/you/other", id: "outproj")
      _, out, = run_cli("list", "--project", "/Users/you/app", env: env)
      assert_includes out, "inproj"
      refute_includes out, "outproj"
    end
  end

  # --project and --since are the only two flags that walk different code
  # paths inside collect_sessions (for_project vs AgentSessions.sessions), so
  # this is the only test exercising both at once.
  def test_list_project_and_since_combine
    with_home do |home, env|
      claude_fixture(home, project: "/Users/you/app", id: "recent_in_project", mtime: Time.now)
      claude_fixture(home, project: "/Users/you/app", id: "old_in_project", mtime: Time.now - (3 * 86_400))
      claude_fixture(home, project: "/Users/you/other", id: "recent_other_project", mtime: Time.now)
      _, out, = run_cli("list", "--project", "/Users/you/app", "--since", "1d", env: env)
      assert_includes out, "recent_in_project"
      refute_includes out, "old_in_project"
      refute_includes out, "recent_other_project"
    end
  end

  def test_list_json_rows_omit_project_path_and_format_times
    with_home do |home, env|
      claude_fixture(home)
      _, out, = run_cli("list", "--json", env: env)
      rows = JSON.parse(out)
      assert_equal 1, rows.size
      row = rows.first
      assert_equal "claude", row.fetch("agent")
      assert_equal "claude:aa11", row.fetch("uid")
      refute row.key?("project_path"), "listing must stay stat-only; project_path forces a read"
      assert_match(/\A\d{4}-\d{2}-\d{2}T/, row.fetch("updated_at"))
    end
  end

  # Dropping any one of path/started_at/bytes/format/fidelity from session_row
  # leaves the suite green otherwise, since no other test asserts against the
  # full field set. For the machine-facing surface a silent field drop is a
  # breaking change nothing else would catch.
  def test_list_json_row_field_set_is_pinned
    with_home do |home, env|
      claude_fixture(home)
      _, out, = run_cli("list", "--json", env: env)
      row = JSON.parse(out).first
      expected_keys = %w[agent id uid path started_at updated_at bytes format fidelity]
      assert_equal expected_keys.sort, row.keys.sort
    end
  end

  # opencode's Session#bytes is nil (design decision 7: a session is rows in a
  # shared database, not a file, so its size isn't a file size), and nothing
  # else in this suite produces a nil-bytes session, so bytes_cell's "?"
  # branch has never actually run. Lifted from Task 11's du fixture shape,
  # which needs the identical construct.
  def test_list_shows_question_mark_for_unknown_bytes
    sizeless = Class.new(AgentSessions::Adapters::Base) do
      agent :sizeless
      label "Sizeless"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      base_dir default: "~/.sizeless"
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [AgentSessions::Session.new(agent: :sizeless, id: "s1", path: "/db", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: nil,
                                    format: :sqlite, fidelity: :full)].lazy
      end
    end
    AgentSessions.register(sizeless)

    with_home do |_home, env|
      _, out, = run_cli("list", "--agent", "sizeless", env: env)
      assert_match(/sizeless\s+s1\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}\s+\?\z/, out.chomp)

      _, json_out, = run_cli("list", "--agent", "sizeless", "--json", env: env)
      row = JSON.parse(json_out).first
      assert_nil row.fetch("bytes")
    end
  ensure
    AgentSessions.registry.delete(:sizeless)
  end

  def test_list_rejects_a_stray_positional_argument
    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("list", "claude", env: env)
      assert_equal 1, status
      assert_includes err, "claude"
      assert_equal "", out
    end
  end

  # Proves the agent and id columns are actually padded (ljust), not just
  # concatenated: "claude" and "codex" differ in length, and so do a 1-char
  # and a 36-char uuid id, so the timestamp column only lands at a consistent
  # offset on every line if both columns are justified to a shared width.
  def test_list_aligns_agent_and_id_columns
    with_home do |home, env|
      claude_fixture(home, id: "a")
      codex_uuid = "22222222-2222-2222-2222-222222222222"
      write(JSON.generate({ type: "session_meta", payload: { cwd: "/y" } }),
            home, ".codex", "sessions", "2026", "07", "21", "rollout-2026-07-21T04-05-06-#{codex_uuid}.jsonl")
      _, out, = run_cli("list", env: env)
      offsets = out.lines.filter_map { |line| line =~ /\d{4}-\d{2}-\d{2} \d{2}:\d{2}/ }
      assert_equal 1, offsets.uniq.size, out
    end
  end

  # print_audit already right-justifies its size column; list quietly did not
  # justify it at all (a no-op for the last column only when every row's size
  # text happens to be the same width). Two files with very differently sized
  # content forces the difference to show: a fixed-width mutation (padding
  # removed entirely) makes the two lines different lengths, and a left- vs
  # right-justify mutation leaves the shorter line ending in trailing spaces.
  def test_list_right_aligns_the_size_column
    with_home do |home, env|
      write(JSON.generate({ type: "attachment", cwd: "/Users/you/app" }),
            home, ".claude", "projects", "-Users-you-app", "small.jsonl")
      write("x" * 500_000, home, ".claude", "projects", "-Users-you-app", "big.jsonl")
      _, out, = run_cli("list", env: env)
      lines = out.lines.map(&:chomp)
      assert_equal 2, lines.size
      assert_equal 1, lines.map(&:length).uniq.size, "size column must be padded to a fixed width:\n#{out}"

      small_line = lines.find { |line| line.include?("small") }
      refute_match(/\s\z/, small_line,
                   "size column must be right-justified (leading spaces), not left " \
                   "(trailing spaces): #{small_line.inspect}")
    end
  end

  # End-to-end through actual rendering, not elide called in isolation: a unit
  # test on elide alone cannot tell whether print_session_table calls it, or
  # whether id_width is computed from the elided or the raw length — removing
  # the cap from print_session_table entirely leaves an isolated elide test
  # green. The 73-char id and the 38-char boundary id are both literals, not
  # references to ID_COLUMN_MAX, so a change to the constant's value (bigger
  # or smaller) changes what these fixtures need and this test catches it,
  # rather than silently following the mutated constant.
  def test_list_elides_long_ids_through_the_real_rendering_path
    with_home do |home, env|
      chat_uuid = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
      nested_uuid = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
      write("", home, ".cursor", "chats", chat_uuid, nested_uuid, "store.db")
      meta = { schemaVersion: 1, createdAtMs: 1_752_484_323_000,
               updatedAtMs: 1_752_490_000_000, cwd: "/Users/you/app", title: "fixture" }
      write(JSON.generate(meta), home, ".cursor", "chats", chat_uuid, nested_uuid, "meta.json")

      boundary_id = "z" * 38 # exactly today's ID_COLUMN_MAX -- must print whole, not elided
      write(JSON.generate({ type: "attachment", cwd: "/Users/you/app" }),
            home, ".claude", "projects", "-Users-you-app", "#{boundary_id}.jsonl")

      _, out, = run_cli("list", env: env)
      lines = out.lines.map(&:chomp)
      refute_empty lines
      lines.each { |line| assert_operator line.length, :<=, 80, "line wraps an 80-column terminal:\n#{line}" }

      full_id = "#{chat_uuid}/#{nested_uuid}"
      assert_equal 73, full_id.length, "fixture must reproduce the 73-char id the cap is sized against"
      expected_elided = "#{full_id[0, 18]}…#{full_id[-18..]}"

      assert_includes out, expected_elided, "the long Cursor id must be elided to exactly this"
      refute_includes out, full_id, "the unelided 73-char id must never reach the table"
      assert_includes out, boundary_id, "an id exactly at the cap must print whole, not be elided"
    end
  end

  # Exit code is 1 even though the rest of the listing printed successfully:
  # --json is the door built for a machine consumer, and a machine reading a
  # shorter-than-true array off stdout has no way to see the "blocked: skipped"
  # line that only ever reaches stderr. A green exit code next to an
  # incomplete array is the silent-under-reporting failure mode (decision 11)
  # wearing a disguise.
  def test_list_reports_skipped_agents_instead_of_silently_omitting_them
    blocked = Class.new(AgentSessions::Adapters::Base) do
      agent :blocked
      label "Blocked"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      base_dir default: "~/.blocked"
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions = raise AgentSessions::MissingDependency, "needs a gem"
    end
    AgentSessions.register(blocked)

    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("list", env: env)
      assert_equal 1, status
      assert_includes out, "claude"
      assert_includes err, "blocked: skipped (needs a gem)"
    end
  ensure
    AgentSessions.registry.delete(:blocked)
  end

  # decision 11 was widened to UnreadableStore specifically after Task 8
  # (opencode: a corrupt database, a non-writable store directory, or a writer
  # stuck past busy_timeout). A rescue clause that only names MissingDependency
  # would leave the suite green with no coverage of that half at all — this
  # fixture is MissingDependency's sibling, raising the other one.
  def test_list_reports_unreadable_store_agents_and_exits_nonzero
    broken = Class.new(AgentSessions::Adapters::Base) do
      agent :broken
      label "Broken"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      base_dir default: "~/.broken"
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions = raise AgentSessions::UnreadableStore, "database is locked"
    end
    AgentSessions.register(broken)

    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("list", env: env)
      assert_equal 1, status
      assert_includes out, "claude"
      assert_includes err, "broken: skipped (database is locked)"
    end
  ensure
    AgentSessions.registry.delete(:broken)
  end

  def test_list_of_nothing_is_quietly_empty
    with_home do |_home, env|
      status, out, = run_cli("list", env: env)
      assert_equal 0, status
      assert_equal "", out
    end
  end
end
