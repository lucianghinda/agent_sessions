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

      # since is inclusive: a session updated exactly at the boundary is in.
      # Without this, mutating >= to > survives.
      assert_equal %w[fresh old],
                   AgentSessions.sessions(:fake, env: env, since: File.mtime(old)).force.map(&:id).sort
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

  # Plants a session a NON-scoped agent would match, so the assertion can tell
  # "swept only fake" from "swept everything". Asserting emptiness alone cannot:
  # under a synthetic HOME every agent returns nothing, so the scoped and
  # unscoped calls agree for the wrong reason. The unscoped call is the control.
  def test_for_project_agents_scopes_the_sweep
    with_home do |home, env|
      write(JSON.generate({ type: "attachment", cwd: "/Users/you/app" }),
            home, ".claude", "projects", "-Users-you-app", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jsonl")

      scoped = AgentSessions.for_project("/Users/you/app", env: env, agents: [:fake]).force
      assert_empty scoped, "expected agents: [:fake] to exclude claude's matching session"

      unscoped = AgentSessions.for_project("/Users/you/app", env: env).force
      assert_equal [:claude], unscoped.map(&:agent), "control: unscoped must find it"
    end
  end

  def test_for_project_rejects_unknown_agents_in_the_scope
    assert_raises(AgentSessions::UnknownAgent) do
      AgentSessions.for_project("/x", env: { "HOME" => "/h" }, agents: [:nope])
    end
  end

  # Asserting empty against an adapter with no projects passes for any
  # implementation returning anything empty — gutting the body to `[]`, ignoring
  # `env:`, or routing to the wrong adapter all survived it. The second
  # assertion is what pins the agent argument: without it, projects(:codex)
  # could return Claude's projects and nothing would notice.
  def test_projects_returns_the_named_agents_recorded_project_paths
    with_home do |home, env|
      write(JSON.generate({ type: "attachment", cwd: "/Users/you/app" }),
            home, ".claude", "projects", "-Users-you-app", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jsonl")

      assert_equal ["/Users/you/app"], AgentSessions.projects(:claude, env: env)
      assert_empty AgentSessions.projects(:fake, env: env), "the agent argument must pick the adapter"
    end
  end
end
