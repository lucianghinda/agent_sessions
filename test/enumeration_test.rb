# frozen_string_literal: true

require_relative "test_helper"

class EnumerationTest < Minitest::Test
  include FixtureHelpers

  def setup
    Agent::Sessions.register(FakeAdapter)
  end

  def teardown
    Agent::Sessions.registry.delete(:fake)
  end

  def test_sessions_is_lazy_and_scoped_to_one_agent
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      sessions = Agent::Sessions.sessions(:fake, env: env)
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
      ids = Agent::Sessions.sessions(:fake, env: env, since: Time.now - 60).force.map(&:id)
      assert_equal ["fresh"], ids

      # since is inclusive: a session updated exactly at the boundary is in.
      # Without this, mutating >= to > survives.
      assert_equal %w[fresh old],
                   Agent::Sessions.sessions(:fake, env: env, since: File.mtime(old)).force.map(&:id).sort
    end
  end

  def test_sessions_raises_on_unknown_agent
    assert_raises(Agent::Sessions::UnknownAgent) { Agent::Sessions.sessions(:nope) }
  end

  def test_for_project_sweeps_registered_agents_lazily
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl") # fake has no project rule: never matches
      result = Agent::Sessions.for_project("/Users/you/app", env: env)
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

      scoped = Agent::Sessions.for_project("/Users/you/app", env: env, agents: [:fake]).force
      assert_empty scoped, "expected agents: [:fake] to exclude claude's matching session"

      unscoped = Agent::Sessions.for_project("/Users/you/app", env: env).force
      assert_equal [:claude], unscoped.map(&:agent), "control: unscoped must find it"
    end
  end

  def test_for_project_rejects_unknown_agents_in_the_scope
    assert_raises(Agent::Sessions::UnknownAgent) do
      Agent::Sessions.for_project("/x", env: { "HOME" => "/h" }, agents: [:nope])
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

      assert_equal ["/Users/you/app"], Agent::Sessions.projects(:claude, env: env)
      assert_empty Agent::Sessions.projects(:fake, env: env), "the agent argument must pick the adapter"
    end
  end

  # FakeAdapter declares no project_path_for override, so every session it
  # yields carries a nil project_path from Base's default hook — exactly the
  # "resolution never even ran" case unresolved_project_count exists to
  # count. The claude fixture pins the other side: a resolvable session must
  # NOT be counted, so a survivor that counts total sessions instead of nil
  # ones fails here.
  def test_unresolved_project_count_counts_sessions_with_no_recorded_project
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      touch(home, ".fake", "sessions", "b.jsonl")
      write(JSON.generate({ type: "attachment", cwd: "/Users/you/app" }),
            home, ".claude", "projects", "-Users-you-app", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.jsonl")

      assert_equal 2, Agent::Sessions.unresolved_project_count(:fake, env: env)
      assert_equal 0, Agent::Sessions.unresolved_project_count(:claude, env: env)
    end
  end

  # The Layer 2 conformance gate skips when a test class does not define
  # expected_session_id. That was right while adapters adopted one at a time;
  # from 0.2 on, a skip means a test class lost its opt-in, which would hide
  # three real tests per adapter behind an expected-looking skip count.
  #
  # FakeAdapter is deleted first: this class's own setup registers it as a
  # test double for Layer 1 fixtures, it is never shipped, and no test class
  # opts it into Layer 2 conformance (nor should one — it has no on-disk
  # format to enumerate), so leaving it registered would make this assertion
  # fail for a reason that has nothing to do with the seven real adapters it
  # exists to police. teardown's own `registry.delete(:fake)` still runs
  # after this test and is a harmless no-op against an already-missing key.
  def test_every_registered_adapter_opts_into_layer_2_conformance
    Agent::Sessions.registry.delete(:fake)

    missing = Agent::Sessions.agents.reject do |agent|
      klass = Agent::Sessions.registry.fetch(agent)
      test_class = ObjectSpace.each_object(Class).find do |candidate|
        candidate < Minitest::Test &&
          candidate.method_defined?(:adapter_class) &&
          candidate.instance_method(:adapter_class).bind_call(candidate.allocate) == klass
      rescue StandardError
        false
      end
      test_class&.private_method_defined?(:expected_session_id) ||
        test_class&.method_defined?(:expected_session_id)
    end
    assert_empty missing, "adapters with no Layer 2 conformance opt-in: #{missing.inspect}"
  end
end
