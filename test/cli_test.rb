# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/agent/sessions/cli"

class CLITest < Minitest::Test
  include FixtureHelpers

  def run_cli(*argv, env:)
    stdout = StringIO.new
    stderr = StringIO.new
    status = Agent::Sessions::CLI.new(argv, env: env, stdout: stdout, stderr: stderr).run
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
      assert_includes out, Agent::Sessions::VERSION
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
    cli = Agent::Sessions::CLI.new([])
    long = "0192aa11-2b3c-4d5e-8f90-a1b2c3d4e5f6/0192bb22-3c4d-5e6f-8091-b2c3d4e5f607"
    elided = cli.send(:elide, long)

    assert_operator elided.length, :<=, Agent::Sessions::CLI::ID_COLUMN_MAX
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
  # paths inside collect_sessions (for_project vs Agent::Sessions.sessions), so
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

  # A fake agent whose sessions never resolve a project (Base's default
  # project_path_for hook, undeclared here) must announce itself under
  # --project, the one list mode that already pays to read project_path
  # (decision 12) — a claude session that DOES resolve must not be counted
  # alongside it, which is what the exact "1 sessions" (not 2) pins.
  def test_list_project_reports_unresolved_project_count_on_stderr
    with_home do |home, env|
      claude_fixture(home, project: "/Users/you/app")
      touch(home, ".fake", "sessions", "unresolved.jsonl")
      Agent::Sessions.register(FakeAdapter)
      _, _, err = run_cli("list", "--project", "/Users/you/app", env: env)
      assert_includes err, "1 sessions with unresolved project"
    end
  ensure
    Agent::Sessions.registry.delete(:fake)
  end

  # A plain `list` (no --project) must never pay for a project_path read —
  # session_row deliberately omits the column for exactly this reason — so
  # the unresolved-project note must not appear even when an agent's
  # sessions would trip it under --project.
  def test_list_without_project_never_reports_unresolved_project_count
    with_home do |home, env|
      claude_fixture(home)
      touch(home, ".fake", "sessions", "unresolved.jsonl")
      Agent::Sessions.register(FakeAdapter)
      _, _, err = run_cli("list", env: env)
      refute_includes err, "unresolved project"
    end
  ensure
    Agent::Sessions.registry.delete(:fake)
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

  # Step 3b (Task 12 review): confirms jsonable's String scrub covers `path`,
  # not only `project_path`/`group`. On this machine (macOS/APFS) a filename
  # cannot actually carry invalid UTF-8 -- Errno::EILSEQ at write time -- so
  # a real fixture file can't reproduce a Linux filename doing this. Built
  # in-memory instead, the same way test_du_by_project_json_survives_invalid_
  # utf8_in_a_recorded_project_path constructs its bad string by hand rather
  # than through a JSON round-trip that would itself raise.
  def test_list_json_survives_invalid_utf8_in_path
    bad_path = Class.new(Agent::Sessions::Adapters::Base) do
      agent :bad_path
      label "Bad path"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :bad_path_homedir, entry: { paths: "~/.bad_path" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [Agent::Sessions::Session.new(agent: :bad_path, id: "p1", path: "/x/y-\xFF.jsonl", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: 1,
                                    format: :jsonl, fidelity: :full)].lazy
      end
    end
    Agent::Sessions.register(bad_path)

    with_home do |_home, env|
      status, out, = run_cli("list", "--json", env: env)
      assert_equal 0, status

      rows = JSON.parse(out)
      row = rows.find { |r| r["agent"] == "bad_path" }
      refute_nil row, "expected the malformed-path session's row:\n#{out}"
      assert_equal "/x/y-?.jsonl", row.fetch("path"), "the invalid byte must be scrubbed, not dropped silently"
    end
  ensure
    Agent::Sessions.registry.delete(:bad_path)
  end

  # opencode's Session#bytes is nil (design decision 7: a session is rows in a
  # shared database, not a file, so its size isn't a file size), and nothing
  # else in this suite produces a nil-bytes session, so bytes_cell's "?"
  # branch has never actually run. Lifted from Task 11's du fixture shape,
  # which needs the identical construct.
  def test_list_shows_question_mark_for_unknown_bytes
    sizeless = Class.new(Agent::Sessions::Adapters::Base) do
      agent :sizeless
      label "Sizeless"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :sizeless_list_homedir, entry: { paths: "~/.sizeless" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [Agent::Sessions::Session.new(agent: :sizeless, id: "s1", path: "/db", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: nil,
                                    format: :sqlite, fidelity: :full)].lazy
      end
    end
    Agent::Sessions.register(sizeless)

    with_home do |_home, env|
      _, out, = run_cli("list", "--agent", "sizeless", env: env)
      assert_match(/sizeless\s+s1\s+\d{4}-\d{2}-\d{2} \d{2}:\d{2}\s+\?\z/, out.chomp)

      _, json_out, = run_cli("list", "--agent", "sizeless", "--json", env: env)
      row = JSON.parse(json_out).first
      assert_nil row.fetch("bytes")
    end
  ensure
    Agent::Sessions.registry.delete(:sizeless)
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
    blocked = Class.new(Agent::Sessions::Adapters::Base) do
      agent :blocked
      label "Blocked"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :blocked_homedir, entry: { paths: "~/.blocked" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions = raise Agent::Sessions::MissingDependency, "needs a gem"
    end
    Agent::Sessions.register(blocked)

    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("list", env: env)
      assert_equal 1, status
      assert_includes out, "claude"
      assert_includes err, "blocked: skipped (needs a gem)"
    end
  ensure
    Agent::Sessions.registry.delete(:blocked)
  end

  # decision 11 was widened to UnreadableStore specifically after Task 8
  # (opencode: a corrupt database, a non-writable store directory, or a writer
  # stuck past busy_timeout). A rescue clause that only names MissingDependency
  # would leave the suite green with no coverage of that half at all — this
  # fixture is MissingDependency's sibling, raising the other one.
  def test_list_reports_unreadable_store_agents_and_exits_nonzero
    broken = Class.new(Agent::Sessions::Adapters::Base) do
      agent :broken
      label "Broken"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :broken_list_homedir, entry: { paths: "~/.broken" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions = raise Agent::Sessions::UnreadableStore, "database is locked"
    end
    Agent::Sessions.register(broken)

    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("list", env: env)
      assert_equal 1, status
      assert_includes out, "claude"
      assert_includes err, "broken: skipped (database is locked)"
    end
  ensure
    Agent::Sessions.registry.delete(:broken)
  end

  def test_list_of_nothing_is_quietly_empty
    with_home do |_home, env|
      status, out, = run_cli("list", env: env)
      assert_equal 0, status
      assert_equal "", out
    end
  end

  def test_du_groups_by_agent_with_totals
    with_home do |home, env|
      path_a = claude_fixture(home, id: "a1")
      path_b = claude_fixture(home, id: "a2")
      status, out, = run_cli("du", env: env)
      assert_equal 0, status

      expected = Agent::Sessions::CLI.new([]).send(:human_bytes, File.size(path_a) + File.size(path_b))
      assert_match(/\Aclaude\s+2\s+#{Regexp.escape(expected)}\z/, out.lines.first.chomp)

      total_line = out.lines.find { |line| line.start_with?("TOTAL") }
      refute_nil total_line, "expected a TOTAL row:\n#{out}"
      assert_match(/\ATOTAL\s+2\s+#{Regexp.escape(expected)}\z/, total_line.chomp)
    end
  end

  def test_du_by_project_pays_the_read_and_groups_by_recorded_cwd
    with_home do |home, env|
      claude_fixture(home, project: "/Users/you/app", id: "p1")
      claude_fixture(home, project: "/Users/you/other", id: "p2")
      _, out, = run_cli("du", "--by", "project", env: env)
      assert_includes out, "/Users/you/app"
      assert_includes out, "/Users/you/other"
    end
  end

  # Three of seven adapters can legitimately fail to resolve a project (Amp
  # with no workspace tree, cursor_ide by design, pi if its unverified header
  # key is wrong). Grouping those sessions under "(unknown)" rather than
  # dropping them is what decision 3 in the task asks for; without this
  # branch a session with no recorded cwd would simply vanish from the table.
  def test_du_by_project_groups_unresolvable_sessions_under_unknown
    with_home do |home, env|
      write(JSON.generate({ type: "attachment" }), home, ".claude", "projects", "-nowhere", "u1.jsonl")
      _, out, = run_cli("du", "--by", "project", env: env)
      assert_includes out, "(unknown)"
    end
  end

  def test_du_shows_question_mark_when_sizes_are_unknown
    sizeless = Class.new(Agent::Sessions::Adapters::Base) do
      agent :sizeless
      label "Sizeless"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :sizeless_du_homedir, entry: { paths: "~/.sizeless" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [Agent::Sessions::Session.new(agent: :sizeless, id: "s1", path: "/db", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: nil,
                                    format: :sqlite, fidelity: :full)].lazy
      end
    end
    Agent::Sessions.register(sizeless)

    with_home do |_home, env|
      _, out, = run_cli("du", env: env)
      assert_match(/sizeless\s+1\s+\?/, out)

      _, json_out, = run_cli("du", "--json", env: env)
      row = JSON.parse(json_out).find { |r| r["group"] == "sizeless" }
      assert_nil row.fetch("bytes")
      assert_equal 1, row.fetch("unknown_sessions")
    end
  ensure
    Agent::Sessions.registry.delete(:sizeless)
  end

  # A group with SOME known and SOME unknown sizes must say so with a "+",
  # not report a plain (silently short) total and not fall back to "?" as if
  # nothing in the group were known. This is the one case a fixture built
  # from all-known or all-unknown sessions alone cannot exercise.
  def test_du_shows_a_plus_suffix_when_only_some_sizes_in_a_group_are_known
    mixed = Class.new(Agent::Sessions::Adapters::Base) do
      agent :mixed
      label "Mixed"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :mixed_homedir, entry: { paths: "~/.mixed" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [
          Agent::Sessions::Session.new(agent: :mixed, id: "known", path: "/a", project_path: nil,
                                      started_at: nil, updated_at: Time.now, bytes: 1024,
                                      format: :sqlite, fidelity: :full),
          Agent::Sessions::Session.new(agent: :mixed, id: "unknown", path: "/b", project_path: nil,
                                      started_at: nil, updated_at: Time.now, bytes: nil,
                                      format: :sqlite, fidelity: :full)
        ].lazy
      end
    end
    Agent::Sessions.register(mixed)

    with_home do |_home, env|
      _, out, = run_cli("du", env: env)
      assert_match(/mixed\s+2\s+1\.0 KB\+/, out)

      _, json_out, = run_cli("du", "--json", env: env)
      row = JSON.parse(json_out).find { |r| r["group"] == "mixed" }
      assert_equal 1024, row.fetch("bytes"), "the known portion must still be reported, not nulled out"
      assert_equal 1, row.fetch("unknown_sessions")
    end
  ensure
    Agent::Sessions.registry.delete(:mixed)
  end

  def test_du_rejects_unknown_by
    with_home do |_home, env|
      status, _, err = run_cli("du", "--by", "vibes", env: env)
      assert_equal 1, status
      assert_includes err, "vibes"
    end
  end

  def test_du_rejects_a_stray_positional_argument
    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("du", "agent", env: env)
      assert_equal 1, status
      assert_includes err, "agent"
      assert_equal "", out
    end
  end

  def test_du_json
    with_home do |home, env|
      claude_fixture(home)
      _, out, = run_cli("du", "--json", env: env)
      rows = JSON.parse(out)
      row = rows.find { |r| r["group"] == "claude" }
      assert_equal 1, row.fetch("sessions")
      assert_kind_of Integer, row.fetch("bytes")
      assert_equal 0, row.fetch("unknown_sessions")
    end
  end

  # Dropping any one of group/sessions/bytes/unknown_sessions leaves the
  # suite green otherwise, since no other test asserts against the full
  # field set — the same reasoning as list's pinned-field-set test.
  def test_du_json_row_field_set_is_pinned
    with_home do |home, env|
      claude_fixture(home)
      _, out, = run_cli("du", "--json", env: env)
      row = JSON.parse(out).first
      assert_equal %w[group sessions bytes unknown_sessions].sort, row.keys.sort
    end
  end

  def test_du_of_nothing_is_quietly_empty
    with_home do |_home, env|
      status, out, = run_cli("du", env: env)
      assert_equal 0, status
      assert_equal "", out
    end
  end

  def test_du_json_of_nothing_is_an_empty_array
    with_home do |_home, env|
      _, out, = run_cli("du", "--json", env: env)
      assert_equal [], JSON.parse(out)
    end
  end

  # Exit code is 1 even though the rest of the table printed successfully —
  # the same reasoning list's equivalent test documents: a skip notice lives
  # only on stderr, and a green exit code next to a table that quietly
  # dropped an agent's bytes is the silent-under-reporting failure mode
  # wearing a disguise (decision 11, widened to du by decision 11a).
  def test_du_exits_nonzero_when_an_agent_is_skipped
    broken = Class.new(Agent::Sessions::Adapters::Base) do
      agent :broken
      label "Broken"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :broken_du_homedir, entry: { paths: "~/.broken" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions = raise Agent::Sessions::UnreadableStore, "database is locked"
    end
    Agent::Sessions.register(broken)

    with_home do |home, env|
      claude_fixture(home)
      status, out, err = run_cli("du", env: env)
      assert_equal 1, status
      assert_includes out, "claude"
      assert_includes err, "broken: skipped (database is locked)"
    end
  ensure
    Agent::Sessions.registry.delete(:broken)
  end

  # Groups are sorted by known bytes descending, but every all-unknown group
  # (opencode's real shape: 359 sessions, every one nil bytes) ties at zero
  # known bytes. Without a tiebreaker, that tie resolves to group_by's
  # insertion order — which is registration order, an accident of how
  # Agent::Sessions.agents happens to be built, not a fact about the data. The
  # session-count tiebreaker at least ranks the biggest all-unknown group
  # above a smaller one, rather than leaving it to that accident.
  def test_du_sorts_known_bytes_first_then_larger_unknown_groups_before_smaller_ones
    big_unknown = Class.new(Agent::Sessions::Adapters::Base) do
      agent :big_unknown
      label "Big unknown"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :big_unknown_homedir, entry: { paths: "~/.big_unknown" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        Array.new(10) do |i|
          Agent::Sessions::Session.new(agent: :big_unknown, id: "s#{i}", path: "/x#{i}", project_path: nil,
                                      started_at: nil, updated_at: Time.now, bytes: nil,
                                      format: :sqlite, fidelity: :full)
        end.lazy
      end
    end
    small_unknown = Class.new(Agent::Sessions::Adapters::Base) do
      agent :small_unknown
      label "Small unknown"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :small_unknown_homedir, entry: { paths: "~/.small_unknown" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [Agent::Sessions::Session.new(agent: :small_unknown, id: "s0", path: "/y", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: nil,
                                    format: :sqlite, fidelity: :full)].lazy
      end
    end
    # Registered SMALL-before-big deliberately: group_by (and Agent::Sessions.agents,
    # which drives collect_sessions) walks registration order, so without the
    # count tiebreaker the natural fallback order is already
    # ["claude", "small_unknown", "big_unknown"] — identical to what a correct
    # tiebreaker also produces if the fixture registers big first. Registering
    # small first makes the two hypotheses disagree: only the actual tiebreaker
    # logic reorders small_unknown behind big_unknown; deleting `.sort_by`
    # entirely, or dropping just the count key, both leave small_unknown first.
    Agent::Sessions.register(small_unknown)
    Agent::Sessions.register(big_unknown)

    with_home do |home, env|
      claude_fixture(home)
      _, out, = run_cli("du", env: env)
      lines = out.lines.map(&:chomp)
      claude_index = lines.index { |line| line.start_with?("claude") }
      big_index = lines.index { |line| line.start_with?("big_unknown") }
      small_index = lines.index { |line| line.start_with?("small_unknown") }

      assert claude_index < big_index, "a group with known bytes must rank above an all-unknown group:\n#{out}"
      assert big_index < small_index, "among equally-unknown groups, more sessions must rank first:\n#{out}"
    end
  ensure
    Agent::Sessions.registry.delete(:big_unknown)
    Agent::Sessions.registry.delete(:small_unknown)
  end

  # print_du_table right-aligns its size column the same way audit and list
  # already do (shared convention) — proven end to end, the same way list's
  # equivalent test is: two rows whose byte-cell text differs in length,
  # checking both that the column is padded to one width and that the
  # shorter cell's padding is on the LEFT (right-justified), not the right.
  def test_du_right_aligns_the_bytes_column
    small = Class.new(Agent::Sessions::Adapters::Base) do
      agent :small
      label "Small"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :small_homedir, entry: { paths: "~/.small" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [Agent::Sessions::Session.new(agent: :small, id: "s", path: "/s", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: 5,
                                    format: :sqlite, fidelity: :full)].lazy
      end
    end
    Agent::Sessions.register(small)

    with_home do |home, env|
      write("x" * 500_000, home, ".claude", "projects", "-p", "big.jsonl")
      _, out, = run_cli("du", env: env)
      lines = out.lines.map(&:chomp)
      assert_equal 1, lines.map(&:length).uniq.size, "the bytes column must be padded to a fixed width:\n#{out}"

      small_line = lines.find { |line| line.start_with?("small") }
      refute_match(/\s\z/, small_line,
                   "the bytes column must be right-justified (leading spaces), not left " \
                   "(trailing spaces): #{small_line.inspect}")
    end
  ensure
    Agent::Sessions.registry.delete(:small)
  end

  # Decision from the four questions this task must answer: every gated
  # warning across pi/amp/cursor/cursor_ide names its own symptom as
  # "projects or du --by project report nothing" — but the only place that
  # warning text lives is `where`, a command the affected user has no reason
  # to run. du is where the symptom shows up, so du is where the pointer to
  # `where` belongs.
  def test_du_points_to_where_when_an_installed_gated_warning_agent_has_zero_rows
    flagged = Class.new(Agent::Sessions::Adapters::Base) do
      agent :flagged
      label "Flagged"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :flagged_homedir, entry: { paths: "~/.flagged" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def warnings
        list = super
        list << "if `projects` or `du --by project` report nothing, open an issue" if primary_layer.exists?
        list
      end
    end
    Agent::Sessions.register(flagged)

    with_home do |home, env|
      # The store directory exists (Store#installed? true, so the gated
      # warning fires) but holds no *.jsonl — exactly the shape pi's real
      # gated warning describes: nine real project directories on disk, zero
      # session files inside any of them.
      touch(home, ".flagged", "sessions", ".keep")
      claude_fixture(home)
      status, _, err = run_cli("du", env: env)
      assert_equal 0, status, "an installed-but-warned agent is not the same failure as a skip"
      assert_includes err, "flagged"
      assert_includes err, "where flagged"
    end
  ensure
    Agent::Sessions.registry.delete(:flagged)
  end

  # The other half of the same decision: an agent nobody has ever installed
  # (no store on disk at all) must stay silent. Real pi/cursor/cursor_ide on
  # a machine that has never used them are exactly this case, and the task's
  # own reasoning says zero rows from an agent nobody has used is not a
  # symptom worth a line.
  def test_du_does_not_point_at_an_agent_that_was_never_installed
    uninstalled = Class.new(Agent::Sessions::Adapters::Base) do
      agent :uninstalled
      label "Uninstalled"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :uninstalled_homedir, entry: { paths: "~/.never-installed-anywhere" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def warnings
        list = super
        list << "gated warning that must not fire" if primary_layer.exists?
        list
      end
    end
    Agent::Sessions.register(uninstalled)

    with_home do |home, env|
      claude_fixture(home)
      _, _, err = run_cli("du", env: env)
      refute_includes err, "uninstalled"
    end
  ensure
    Agent::Sessions.registry.delete(:uninstalled)
  end

  # Isolates the OTHER half of the `installed? && !warnings.empty?` guard:
  # an agent can be genuinely installed (its store directory is really there)
  # and still contribute zero rows for a completely ordinary reason — an
  # empty store — with no warning at all. Without the warnings check, this
  # would fire on every empty-but-real store on a user's machine, which is
  # noise, not signal.
  def test_du_does_not_point_at_an_installed_agent_with_no_warnings_and_zero_rows
    quiet = Class.new(Agent::Sessions::Adapters::Base) do
      agent :quiet
      label "Quiet"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :quiet_homedir, entry: { paths: "~/.quiet" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl
      # No warnings declared at all -- Base#warnings returns [].
    end
    Agent::Sessions.register(quiet)

    with_home do |home, env|
      touch(home, ".quiet", "sessions", ".keep") # installed, but zero .jsonl and zero warnings
      claude_fixture(home)
      _, _, err = run_cli("du", env: env)
      refute_includes err, "quiet"
    end
  ensure
    Agent::Sessions.registry.delete(:quiet)
  end

  # Isolates the @skipped_agents exclusion: an agent whose store IS installed
  # AND carries a gated warning AND raises inside `sessions` must get only
  # its "skipped (reason)" line, not a second, confusing "contributed 0
  # sessions" line for the same underlying failure.
  def test_du_does_not_double_report_a_skipped_agent_as_a_gated_warning_agent
    broken = Class.new(Agent::Sessions::Adapters::Base) do
      agent :broken_and_warned
      label "Broken and warned"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :broken_and_warned_homedir, entry: { paths: "~/.broken_and_warned" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def warnings
        list = super
        list << "gated warning" if primary_layer.exists?
        list
      end

      def sessions = raise Agent::Sessions::UnreadableStore, "database is locked"
    end
    Agent::Sessions.register(broken)

    with_home do |home, env|
      touch(home, ".broken_and_warned", "sessions", ".keep") # installed AND warned
      claude_fixture(home)
      status, _, err = run_cli("du", env: env)
      assert_equal 1, status
      assert_includes err, "broken_and_warned: skipped (database is locked)"
      refute_includes err, "contributed 0 sessions"
    end
  ensure
    Agent::Sessions.registry.delete(:broken_and_warned)
  end

  # Isolates the `- reporting` half of the exclusion (the `- @skipped_agents`
  # half already has its own test above): an agent that is installed, carries
  # a gated warning, AND actually contributed rows must not also get the
  # zero-rows note. On the real machine this is codex/amp/opencode territory —
  # all three are installed, all three carry a warning, and dropping
  # `- reporting` would print "codex: installed but contributed 0 sessions
  # here" directly above a row reading "codex 414 287.5 MB".
  def test_du_does_not_flag_a_gated_warning_agent_that_actually_reported_rows
    flagged = Class.new(Agent::Sessions::Adapters::Base) do
      agent :flagged_with_rows
      label "Flagged with rows"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :flagged_with_rows_homedir, entry: { paths: "~/.flagged_with_rows" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def warnings
        list = super
        list << "gated warning" if primary_layer.exists?
        list
      end
    end
    Agent::Sessions.register(flagged)

    with_home do |home, env|
      write(JSON.generate({ type: "attachment" }), home, ".flagged_with_rows", "sessions", "s1.jsonl")
      claude_fixture(home)
      _, out, err = run_cli("du", env: env)
      assert_includes out, "flagged_with_rows"
      refute_includes err, "contributed 0 sessions"
    end
  ensure
    Agent::Sessions.registry.delete(:flagged_with_rows)
  end

  # The warning count in the stderr note must reflect the agent's ACTUAL
  # warnings, not a hardcoded number — this agent carries two (one permanent,
  # one gated) so a survivor that hardcodes "(1 warning(s))" or "(0
  # warning(s))" fails here even though it would pass every other du test,
  # each of which happens to use a single-warning fixture.
  def test_du_gated_warning_note_reports_the_actual_warning_count
    flagged = Class.new(Agent::Sessions::Adapters::Base) do
      agent :flagged_two_warnings
      label "Flagged two warnings"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :flagged_two_warnings_homedir, entry: { paths: "~/.flagged_two_warnings" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      warning "an always-present warning"

      def warnings
        list = super
        list << "a second, gated warning" if primary_layer.exists?
        list
      end
    end
    Agent::Sessions.register(flagged)

    with_home do |home, env|
      touch(home, ".flagged_two_warnings", "sessions", ".keep")
      claude_fixture(home)
      _, _, err = run_cli("du", env: env)
      assert_includes err, "(2 warning(s))"
    end
  ensure
    Agent::Sessions.registry.delete(:flagged_two_warnings)
  end

  # Reproduces the live crash: a recorded cwd carrying invalid UTF-8 (a raw
  # byte, not something JSON.generate could have produced itself — it has to
  # be written directly, the way a malformed real session log would arrive)
  # used to reach JSON.pretty_generate unscrubbed and raise
  # JSON::GeneratorError, which is not an Agent::Sessions::Error and so escaped
  # the CLI's top-level rescue entirely. du --by project is the first path
  # that puts a recorded cwd into a JSON value at all (list omits
  # project_path — decision 12), which is what made this reachable only here.
  def test_du_by_project_json_survives_invalid_utf8_in_a_recorded_project_path
    with_home do |home, env|
      path = File.join(home, ".claude", "projects", "-Users-you-app", "bad.jsonl")
      FileUtils.mkdir_p(File.dirname(path))
      # Written directly, bypassing JSON.generate: JSON.generate itself raises
      # on a String carrying invalid UTF-8, so this is not producible through
      # this codebase's own writers -- exactly why it has to be constructed by
      # hand to stand in for a malformed real-world session log.
      File.write(path, "{\"type\":\"attachment\",\"cwd\":\"/Users/you/app-\xFF\"}")

      status, out, = run_cli("du", "--by", "project", "--json", env: env)
      assert_equal 0, status

      rows = JSON.parse(out)
      row = rows.find { |r| r["group"].start_with?("/Users/you/app-") }
      refute_nil row, "expected the malformed-cwd session's project row:\n#{out}"
      assert_equal "/Users/you/app-?", row.fetch("group"), "the invalid byte must be scrubbed, not dropped silently"
    end
  end

  # Two sessions sharing a project must MERGE into one row with count == 2 —
  # the previous project-grouping tests only ever used one session per
  # project, so grouping (as opposed to a 1:1 listing) was never actually
  # exercised. The regex is anchored end to end, the same way the --by agent
  # totals test is, so appending anything to the group key (an agent name
  # suffix, say) fails this test even though it would still pass a plain
  # assert_includes.
  def test_du_by_project_merges_multiple_sessions_into_one_row
    with_home do |home, env|
      path_a = claude_fixture(home, project: "/Users/you/app", id: "m1")
      path_b = claude_fixture(home, project: "/Users/you/app", id: "m2")
      _, out, = run_cli("du", "--by", "project", env: env)

      expected = Agent::Sessions::CLI.new([]).send(:human_bytes, File.size(path_a) + File.size(path_b))
      line = out.lines.find { |l| l.include?("/Users/you/app") }
      refute_nil line, "expected a merged row for the shared project:\n#{out}"
      assert_match(/\A\/Users\/you\/app\s+2\s+#{Regexp.escape(expected)}\z/, line.chomp)
    end
  end

  # The --json equivalent of the merge test above, with an exact (not
  # substring) match on the group key — closes the gap a mutation that
  # appends extra characters to the group (an agent name, say) would sail
  # through under assert_includes.
  def test_du_by_project_json
    with_home do |home, env|
      path_a = claude_fixture(home, project: "/Users/you/app", id: "j1")
      path_b = claude_fixture(home, project: "/Users/you/other", id: "j2")
      _, out, = run_cli("du", "--by", "project", "--json", env: env)
      rows = JSON.parse(out)

      app_row = rows.find { |r| r["group"] == "/Users/you/app" }
      other_row = rows.find { |r| r["group"] == "/Users/you/other" }
      refute_nil app_row, "expected an exact-match row for /Users/you/app:\n#{out}"
      refute_nil other_row, "expected an exact-match row for /Users/you/other:\n#{out}"
      assert_equal 1, app_row.fetch("sessions")
      assert_equal File.size(path_a), app_row.fetch("bytes")
      assert_equal 1, other_row.fetch("sessions")
      assert_equal File.size(path_b), other_row.fetch("bytes")
    end
  end

  # A long project path must be elided in the TEXT table (the same mechanism
  # `list` already applies to Cursor's 73-char ids), so a du --by project row
  # cannot wrap an 80-column terminal the way an unbounded 169-char path did
  # on the real machine. The JSON payload must NOT be elided -- callers that
  # need the exact path (feeding it back into --project, say) need the real
  # thing, not a display truncation.
  def test_du_by_project_elides_long_paths_in_the_table_but_not_in_json
    with_home do |home, env|
      long_project = "/Users/you/#{"a" * 40}/#{"b" * 40}/leaf"
      claude_fixture(home, project: long_project, id: "long1")

      _, out, = run_cli("du", "--by", "project", env: env)
      lines = out.lines.map(&:chomp)
      refute(lines.any? { |l| l.include?(long_project) }, "the full, unelided path must not reach the table:\n#{out}")
      assert(lines.any? { |l| l.include?("…") }, "expected an elided row:\n#{out}")
      assert(lines.all? { |l| l.length <= 80 }, "a row must not wrap an 80-column terminal:\n#{out}")

      _, json_out, = run_cli("du", "--by", "project", "--json", env: env)
      rows = JSON.parse(json_out)
      assert(rows.any? { |r| r["group"] == long_project }, "JSON must keep the full, unelided path")
    end
  end

  # Isolates the TOTAL row's own contribution to every column's width: TOTAL's
  # count (10) is wider than either data row's (9 and 1), and TOTAL's bytes
  # cell ("10 B") is wider than either data row's ("9 B" / "1 B"). If
  # print_du_table computed widths from `rows` alone and only appended TOTAL
  # afterward, TOTAL's own line would be the one that's a different length —
  # this pins the exact three lines, not just "all equal length", so it also
  # catches a rjust/ljust swap on either the count or the bytes column, not
  # just a missing pad.
  def test_du_widens_every_column_to_fit_the_total_row
    nine = Class.new(Agent::Sessions::Adapters::Base) do
      agent :nine
      label "Nine"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :nine_homedir, entry: { paths: "~/.nine" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        Array.new(9) do |i|
          Agent::Sessions::Session.new(agent: :nine, id: "n#{i}", path: "/n#{i}", project_path: nil,
                                      started_at: nil, updated_at: Time.now, bytes: 1,
                                      format: :sqlite, fidelity: :full)
        end.lazy
      end
    end
    one = Class.new(Agent::Sessions::Adapters::Base) do
      agent :one
      label "One"
      documented true
      verified_on "2026-07-01"
      fidelity :full
      homedir :one_homedir, entry: { paths: "~/.one" }
      store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl

      def sessions
        [Agent::Sessions::Session.new(agent: :one, id: "o0", path: "/o0", project_path: nil,
                                    started_at: nil, updated_at: Time.now, bytes: 1,
                                    format: :sqlite, fidelity: :full)].lazy
      end
    end
    Agent::Sessions.register(nine)
    Agent::Sessions.register(one)

    with_home do |_home, env|
      _, out, = run_cli("du", env: env)
      lines = out.lines.map(&:chomp)

      assert_equal "nine    9   9 B", lines.find { |l| l.start_with?("nine") }
      assert_equal "one     1   1 B", lines.find { |l| l.start_with?("one") }
      assert_equal "TOTAL  10  10 B", lines.find { |l| l.start_with?("TOTAL") }
    end
  ensure
    Agent::Sessions.registry.delete(:nine)
    Agent::Sessions.registry.delete(:one)
  end
end
