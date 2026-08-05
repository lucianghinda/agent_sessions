# frozen_string_literal: true

require_relative "test_helper"

class ClaudeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Claude

  # Mirrors the real invariant: the project directory name is the encoded cwd
  # recorded inside the file. Real sessions put the first cwd-bearing record a
  # few lines in (verified line 4 on 2026-08-05), never on line 1.
  def build_fixture(home)
    lines = [
      { type: "summary", summary: "fixture", leafUuid: "x" },
      { type: "mode", mode: "default", sessionId: "018f2a7c" },
      { type: "permissionMode", permissionMode: "default", sessionId: "018f2a7c" },
      { type: "attachment", cwd: "/Users/you/app", sessionId: "018f2a7c",
        timestamp: "2026-07-14T09:12:03.000Z" }
    ]
    write(lines.map(&JSON.method(:generate)).join("\n"), home, ".claude", "projects", "-Users-you-app", "018f2a7c.jsonl")
  end

  def expected_session_id = "018f2a7c"
  def expected_project_path = "/Users/you/app"

  def expected_default_path(home) = File.join(home, ".claude", "projects")

  def override_env = { "CLAUDE_CONFIG_DIR" => "/custom/claude" }
  def expected_override_path = "/custom/claude/projects"

  def test_retention_defaults_to_30_days
    with_home do |_home, env|
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 30, store.retention
      assert_equal :default, store.retention_source
    end
  end

  def test_retention_reads_cleanup_period_from_settings
    with_home do |home, env|
      write('{"cleanupPeriodDays": 7}', home, ".claude", "settings.json")
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 7, store.retention
      assert_equal :setting, store.retention_source
    end
  end

  def test_corrupt_settings_fall_back_to_default
    with_home do |home, env|
      write("{not json", home, ".claude", "settings.json")
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 30, store.retention
    end
  end

  def test_nonsense_retention_settings_fall_back_to_default
    [nil, "7", 7.5, -5].each do |value|
      with_home do |home, env|
        write(JSON.generate({ "cleanupPeriodDays" => value }), home, ".claude", "settings.json")
        store = AgentSessions.locate(:claude, env: env)
        assert_equal 30, store.retention, "expected #{value.inspect} to fall back"
        assert_equal :default, store.retention_source, "expected #{value.inspect} to report :default"
      end
    end
  end

  def test_zero_retention_is_a_real_setting
    with_home do |home, env|
      write('{"cleanupPeriodDays": 0}', home, ".claude", "settings.json")
      store = AgentSessions.locate(:claude, env: env)
      assert_equal 0, store.retention
      assert_equal :setting, store.retention_source
    end
  end

  def test_skip_prompt_history_env_adds_warning
    with_home do |_home, env|
      store = AgentSessions.locate(:claude, env: env.merge("CLAUDE_CODE_SKIP_PROMPT_HISTORY" => "1"))
      assert(store.warnings.any? { |w| w.include?("CLAUDE_CODE_SKIP_PROMPT_HISTORY") })
    end
  end

  def test_no_history_warning_by_default
    with_home do |_home, env|
      store = AgentSessions.locate(:claude, env: env)
      refute(store.warnings.any? { |w| w.include?("CLAUDE_CODE_SKIP_PROMPT_HISTORY") })
    end
  end

  def test_encode_project_collapses_every_non_alphanumeric_to_a_dash
    adapter = AgentSessions::Adapters::Claude.new(env: { "HOME" => "/h" })
    assert_equal "-Users-you-state-of-mind-til", adapter.encode_project("/Users/you/state_of_mind/til")
    assert_equal "-Users-luciang--codex", adapter.encode_project("/Users/luciang/.codex")
  end

  def test_project_path_survives_junk_lines
    with_home do |home, env|
      content = "not json at all\n" + JSON.generate({ type: "attachment", cwd: "/Users/you/app" })
      write(content, home, ".claude", "projects", "-Users-you-app", "aa.jsonl")
      session = AgentSessions::Adapters::Claude.new(env: env).sessions.first
      assert_equal "/Users/you/app", session.project_path
    end
  end

  def test_project_path_gives_up_beyond_the_scan_cap
    with_home do |home, env|
      filler = Array.new(30) { JSON.generate({ type: "noise" }) }
      filler << JSON.generate({ type: "attachment", cwd: "/Users/you/app" })
      write(filler.join("\n"), home, ".claude", "projects", "-Users-you-app", "bb.jsonl")
      assert_nil AgentSessions::Adapters::Claude.new(env: env).sessions.first.project_path
    end
  end

  def test_fidelity_is_full
    assert_equal :full, AgentSessions::Adapters::Claude.fidelity_value
  end
end
