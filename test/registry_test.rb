# frozen_string_literal: true

require_relative "test_helper"

class RegistryTest < Minitest::Test
  include FixtureHelpers

  def setup
    Agent::Sessions.register(FakeAdapter)
  end

  def teardown
    Agent::Sessions.registry.delete(:fake)
  end

  def test_locate_builds_a_store
    store = Agent::Sessions.locate(:fake, env: { "HOME" => "/h" })
    assert_equal :fake, store.agent
  end

  def test_locate_raises_on_unknown_agent
    error = assert_raises(Agent::Sessions::UnknownAgent) { Agent::Sessions.locate(:nope) }
    assert_includes error.message, "nope"
  end

  def test_agents_lists_registered_names
    assert_includes Agent::Sessions.agents, :fake
  end

  def test_all_returns_one_store_per_agent
    with_home do |_home, env|
      stores = Agent::Sessions.all(env: env)
      assert_equal Agent::Sessions.agents.sort, stores.map(&:agent).sort
    end
  end

  def test_installed_filters_to_agents_present_on_disk
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      assert_includes Agent::Sessions.installed(env: env).map(&:agent), :fake
    end
  end

  def test_installed_excludes_absent_agents
    with_home do |_home, env|
      refute_includes Agent::Sessions.installed(env: env).map(&:agent), :fake
    end
  end

  def test_register_rejects_an_adapter_without_an_agent_name
    anonymous = Class.new(Agent::Sessions::Adapters::Base)
    error = assert_raises(Agent::Sessions::Error) { Agent::Sessions.register(anonymous) }
    assert_includes error.message, "agent name"
  end

  def test_verified_on_is_the_oldest_adapter_date
    assert_equal Date.new(2026, 7, 21), Agent::Sessions::VERIFIED_ON
  end
end
