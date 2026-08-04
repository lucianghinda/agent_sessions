# frozen_string_literal: true

require_relative "test_helper"

class CodexAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Codex

  def build_fixture(home)
    touch(home, ".codex", "sessions", "2026", "07", "21", "rollout-2026-07-21-abc.jsonl")
  end

  def expected_default_path(home) = File.join(home, ".codex", "sessions")

  def override_env = { "CODEX_HOME" => "/custom/codex" }
  def expected_override_path = "/custom/codex/sessions"

  def test_declares_history_and_index_as_optional_layers
    with_home do |_home, env|
      store = AgentSessions.locate(:codex, env: env)
      assert_equal %i[sessions history index], store.layers.map(&:kind)
    end
  end

  def test_carries_the_history_config_warning
    with_home do |_home, env|
      store = AgentSessions.locate(:codex, env: env)
      assert(store.warnings.any? { |w| w.include?("history.jsonl") })
    end
  end
end
