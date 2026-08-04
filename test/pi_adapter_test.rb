# frozen_string_literal: true

require_relative "test_helper"

class PiAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Pi

  def build_fixture(home)
    touch(home, ".pi", "agent", "sessions", "--Users-you-app--", "2026-07-14T09-12-03_ab12cd34.jsonl")
  end

  def expected_default_path(home) = File.join(home, ".pi", "agent", "sessions")

  def override_env = { "PI_CODING_AGENT_DIR" => "/custom/pi" }
  def expected_override_path = "/custom/pi/sessions"

  def test_session_dir_env_overrides_the_store_directly
    store = AgentSessions.locate(:pi, env: { "HOME" => "/h", "PI_CODING_AGENT_SESSION_DIR" => "/elsewhere" })
    assert_equal "/elsewhere", store.effective.path
  end

  def test_session_dir_env_beats_base_dir_env
    env = { "HOME" => "/h", "PI_CODING_AGENT_DIR" => "/custom/pi", "PI_CODING_AGENT_SESSION_DIR" => "/elsewhere" }
    store = AgentSessions.locate(:pi, env: env)
    assert_equal "/elsewhere", store.effective.path
  end
end
