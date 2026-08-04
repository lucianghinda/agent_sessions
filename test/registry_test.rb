# frozen_string_literal: true

require_relative "test_helper"

class RegistryTest < Minitest::Test
  include FixtureHelpers

  def setup
    AgentSessions.register(FakeAdapter)
  end

  def teardown
    AgentSessions.registry.delete(:fake)
  end

  def test_locate_builds_a_store
    store = AgentSessions.locate(:fake, env: { "HOME" => "/h" })
    assert_equal :fake, store.agent
  end

  def test_locate_raises_on_unknown_agent
    error = assert_raises(AgentSessions::UnknownAgent) { AgentSessions.locate(:nope) }
    assert_includes error.message, "nope"
  end

  def test_agents_lists_registered_names
    assert_includes AgentSessions.agents, :fake
  end

  def test_all_returns_one_store_per_agent
    with_home do |_home, env|
      stores = AgentSessions.all(env: env)
      assert_equal AgentSessions.agents.sort, stores.map(&:agent).sort
    end
  end

  def test_installed_filters_to_agents_present_on_disk
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      assert_includes AgentSessions.installed(env: env).map(&:agent), :fake
    end
  end

  def test_installed_excludes_absent_agents
    with_home do |_home, env|
      refute_includes AgentSessions.installed(env: env).map(&:agent), :fake
    end
  end

  def test_register_rejects_an_adapter_without_an_agent_name
    anonymous = Class.new(AgentSessions::Adapters::Base)
    error = assert_raises(AgentSessions::Error) { AgentSessions.register(anonymous) }
    assert_includes error.message, "agent name"
  end
end
