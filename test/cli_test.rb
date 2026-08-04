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
      assert_equal "2026-07-21", payload.first.fetch("verified_on")
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
      FileUtils.mkdir_p(File.join(home, ".codex"))
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
end
