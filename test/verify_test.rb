# frozen_string_literal: true

require_relative "test_helper"

class VerifyTest < Minitest::Test
  include FixtureHelpers

  def test_skip_when_agent_not_installed
    with_home do |_home, env|
      checks = AgentSessions.verify(:claude, env: env)
      assert_equal [:skip], checks.map(&:status).uniq
    end
  end

  def test_all_pass_when_stores_present
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      touch(home, ".claude", "history.jsonl")
      checks = AgentSessions.verify(:claude, env: env)
      assert checks.all?(&:pass?), checks.map(&:detail).inspect
    end
  end

  def test_glob_stores_report_match_counts
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      checks = AgentSessions.verify(:claude, env: env)
      projects = checks.find { |c| c.claim.include?("projects") }
      assert_includes projects.detail, "1 file"
    end
  end

  def test_fail_when_required_store_missing
    with_home do |home, env|
      FileUtils.mkdir_p(File.join(home, ".codex"))
      checks = AgentSessions.verify(:codex, env: env)
      assert_equal :fail, checks.find { |c| c.claim.include?("sessions") }.status
    end
  end

  def test_drift_when_optional_store_missing
    with_home do |home, env|
      touch(home, ".codex", "sessions", "2026", "07", "21", "rollout-a.jsonl")
      checks = AgentSessions.verify(:codex, env: env)
      assert_equal :drift, checks.find { |c| c.claim.include?("history") }.status
    end
  end

  # Design doc 8.4 names threads/ and secrets.json as Amp's two stable paths, so a
  # missing secrets.json is a failure rather than the layout drift Amp is prone to.
  def test_amp_secrets_is_a_failure_not_drift
    with_home do |home, env|
      touch(home, ".local", "share", "amp", "threads", "T-1.json")
      checks = AgentSessions.verify(:amp, env: env)
      assert_equal :fail, checks.find { |c| c.claim.include?("secrets") }.status
    end
  end

  def test_verify_without_agent_covers_every_adapter
    with_home do |_home, env|
      agents = AgentSessions.verify(env: env).map(&:agent).uniq
      assert_equal AgentSessions.agents.sort, agents.sort
    end
  end

  def test_doctor_flags_stale_verification
    checks = AgentSessions.doctor(:claude, env: { "HOME" => "/nonexistent" }, today: Date.new(2026, 12, 1))
    staleness = checks.find { |c| c.claim.include?("verified") }
    assert_equal :drift, staleness.status
    assert_includes staleness.detail, "2026-07-21"
  end

  def test_doctor_passes_fresh_verification
    checks = AgentSessions.doctor(:claude, env: { "HOME" => "/nonexistent" }, today: Date.new(2026, 8, 1))
    assert_equal :pass, checks.find { |c| c.claim.include?("verified") }.status
  end
end
