# frozen_string_literal: true

require_relative "test_helper"

class ClaudeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Claude

  def build_fixture(home)
    touch(home, ".claude", "projects", "-Users-you-app", "018f2a7c.jsonl")
  end

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
end
