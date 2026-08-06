# frozen_string_literal: true

require_relative "test_helper"

class EnumerationTest < Minitest::Test
  include FixtureHelpers

  def setup
    AgentSessions.register(FakeAdapter)
  end

  def teardown
    AgentSessions.registry.delete(:fake)
  end

  def test_sessions_is_lazy_and_scoped_to_one_agent
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      sessions = AgentSessions.sessions(:fake, env: env)
      assert_instance_of Enumerator::Lazy, sessions
      assert_equal ["a"], sessions.force.map(&:id)
    end
  end

  def test_sessions_since_filters_on_updated_at
    with_home do |home, env|
      old = touch(home, ".fake", "sessions", "old.jsonl")
      fresh = touch(home, ".fake", "sessions", "fresh.jsonl")
      FileUtils.touch(old, mtime: Time.now - 3600)
      FileUtils.touch(fresh, mtime: Time.now)
      ids = AgentSessions.sessions(:fake, env: env, since: Time.now - 60).force.map(&:id)
      assert_equal ["fresh"], ids
    end
  end

  def test_sessions_raises_on_unknown_agent
    assert_raises(AgentSessions::UnknownAgent) { AgentSessions.sessions(:nope) }
  end

  def test_for_project_sweeps_registered_agents_lazily
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl") # fake has no project rule: never matches
      result = AgentSessions.for_project("/Users/you/app", env: env)
      assert_instance_of Enumerator::Lazy, result
      assert_empty result.force
    end
  end

  def test_for_project_agents_scopes_the_sweep
    with_home do |_home, env|
      result = AgentSessions.for_project("/Users/you/app", env: env, agents: [:fake]).force
      assert_empty result
    end
  end

  def test_for_project_rejects_unknown_agents_in_the_scope
    assert_raises(AgentSessions::UnknownAgent) do
      AgentSessions.for_project("/x", env: { "HOME" => "/h" }, agents: [:nope]).force
    end
  end

  def test_projects_delegates_to_the_adapter
    with_home do |_home, env|
      assert_empty AgentSessions.projects(:fake, env: env)
    end
  end
end
