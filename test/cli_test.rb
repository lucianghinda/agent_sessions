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

  def test_list_project_filters_across_agents
    with_home do |home, env|
      claude_fixture(home, project: "/Users/you/app", id: "inproj")
      claude_fixture(home, project: "/Users/you/other", id: "outproj")
      _, out, = run_cli("list", "--project", "/Users/you/app", env: env)
      assert_includes out, "inproj"
      refute_includes out, "outproj"
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
      assert_equal 0, status
      assert_includes out, "claude"
      assert_includes err, "blocked: skipped (needs a gem)"
    end
  ensure
    AgentSessions.registry.delete(:blocked)
  end

  def test_list_of_nothing_is_quietly_empty
    with_home do |_home, env|
      status, out, = run_cli("list", env: env)
      assert_equal 0, status
      assert_equal "", out
    end
  end
end
