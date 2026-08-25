# frozen_string_literal: true

require_relative "test_helper"

class VerifyTest < Minitest::Test
  include FixtureHelpers

  def test_skip_when_agent_not_installed
    with_home do |_home, env|
      checks = Agent::Sessions.verify(:claude, env: env)
      assert_equal [:skip], checks.map(&:status).uniq
      assert_includes checks.first.detail, "does not exist"
    end
  end

  # The Cursor case that forced this rule (2026-08-05): ~/.cursor existed on a
  # machine where only the editor had run — argv.json and extensions/, no agent
  # stores. Gating verify on base-dir existence made doctor report FAIL while
  # `where` said "(not installed)": the gem contradicting itself. verify now
  # keys on the same signal as Store#installed?: any declared store exists.
  def test_skip_when_base_dir_holds_no_declared_store
    with_home do |home, env|
      touch(home, ".cursor", "argv.json")
      touch(home, ".cursor", "extensions", "some-ext", "package.json")
      checks = Agent::Sessions.verify(:cursor, env: env)
      assert_equal [:skip], checks.map(&:status).uniq
      assert_includes checks.first.detail, "holds none of the declared stores"
    end
  end

  def test_verify_agrees_with_installed
    with_home do |home, env|
      touch(home, ".cursor", "argv.json")
      store = Agent::Sessions.locate(:cursor, env: env)
      checks = Agent::Sessions.verify(:cursor, env: env)
      refute store.installed?
      assert_equal [:skip], checks.map(&:status).uniq
    end
  end

  # An env override can move a store outside the base dir entirely. The old
  # base-dir gate would skip pi here even though its sessions demonstrably
  # exist at the overridden path.
  def test_env_overridden_store_is_verified_without_the_base_dir
    with_home do |home, env|
      elsewhere = File.join(home, "elsewhere")
      touch(elsewhere, "s.jsonl")
      checks = Agent::Sessions.verify(:pi, env: env.merge("PI_CODING_AGENT_SESSION_DIR" => elsewhere))
      assert_equal :pass, checks.find { |c| c.claim.include?("sessions") }.status
    end
  end

  def test_all_pass_when_stores_present
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      touch(home, ".claude", "history.jsonl")
      checks = Agent::Sessions.verify(:claude, env: env)
      assert checks.all?(&:pass?), checks.map(&:detail).inspect
    end
  end

  def test_glob_stores_report_match_counts
    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      checks = Agent::Sessions.verify(:claude, env: env)
      projects = checks.find { |c| c.claim.include?("projects") }
      assert_includes projects.detail, "1 file"
    end
  end

  # :fail is reserved for the layout-moved signature: some store proves the
  # agent records data here, yet a required one is missing. An agent with no
  # stores at all is a :skip, never a :fail — absence proves nothing.
  def test_fail_when_required_store_missing_but_another_store_exists
    with_home do |home, env|
      touch(home, ".codex", "history.jsonl")
      checks = Agent::Sessions.verify(:codex, env: env)
      assert_equal :fail, checks.find { |c| c.claim.include?("sessions") }.status
    end
  end

  def test_drift_when_optional_store_missing
    with_home do |home, env|
      touch(home, ".codex", "sessions", "2026", "07", "21", "rollout-a.jsonl")
      checks = Agent::Sessions.verify(:codex, env: env)
      assert_equal :drift, checks.find { |c| c.claim.include?("history") }.status
    end
  end

  # threads/ is Amp's one stable path, so when other stores prove Amp records
  # data here, its absence is a real failure.
  def test_amp_threads_is_a_failure_when_missing
    with_home do |home, env|
      touch(home, ".local", "share", "amp", "secrets.json")
      checks = Agent::Sessions.verify(:amp, env: env)
      assert_equal :fail, checks.find { |c| c.claim.include?("threads") }.status
    end
  end

  # secrets.json does not exist until `amp login` runs. An earlier version required it
  # (design doc 8.4 named it alongside threads/), which showed a red failure to anyone
  # who installed Amp and never authenticated — for a credentials file whose absence
  # says nothing about whether the session layout claim holds.
  def test_amp_secrets_is_drift_not_a_failure
    with_home do |home, env|
      touch(home, ".local", "share", "amp", "threads", "T-1.json")
      checks = Agent::Sessions.verify(:amp, env: env)
      assert_equal :drift, checks.find { |c| c.claim.include?("secrets") }.status
    end
  end

  def test_verify_without_agent_covers_every_adapter
    with_home do |_home, env|
      agents = Agent::Sessions.verify(env: env).map(&:agent).uniq
      assert_equal Agent::Sessions.agents.sort, agents.sort
    end
  end

  def test_doctor_flags_stale_verification
    checks = Agent::Sessions.doctor(:claude, env: { "HOME" => "/nonexistent" }, today: Date.new(2026, 12, 1))
    staleness = checks.find { |c| c.claim.include?("verified") }
    assert_equal :drift, staleness.status
    assert_includes staleness.detail, "2026-08-05"
  end

  def test_doctor_passes_fresh_verification
    checks = Agent::Sessions.doctor(:claude, env: { "HOME" => "/nonexistent" }, today: Date.new(2026, 8, 1))
    assert_equal :pass, checks.find { |c| c.claim.include?("verified") }.status
  end
end
