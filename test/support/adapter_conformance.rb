# frozen_string_literal: true

# Include in an adapter test and define:
#   adapter_class            -> the adapter class
#   build_fixture(home)      -> create the agent's on-disk layout under home
#   expected_default_path(home) -> effective path when only HOME is set
#   override_env             -> env hash exercising the primary env override
#   expected_override_path   -> effective path under override_env
module AdapterConformance
  include FixtureHelpers

  def test_conformance_is_registered
    assert_equal adapter_class, AgentSessions.registry[adapter_class.agent_name]
  end

  def test_conformance_declares_required_metadata
    assert_kind_of Symbol, adapter_class.agent_name
    assert_kind_of String, adapter_class.label_text
    assert_kind_of Date, adapter_class.verified_on_date
    assert_includes [true, false, :partly], adapter_class.documented_value
    refute_empty adapter_class.store_configs
  end

  def test_conformance_locates_under_default_home
    with_home do |home, env|
      build_fixture(home)
      store = adapter_class.new(env: env).locate
      assert_equal expected_default_path(home), store.effective.path
      assert store.effective.exists?
      assert store.installed?
    end
  end

  def test_conformance_env_override_wins
    skip "#{adapter_class.agent_name} declares no verified env override" if override_env.nil?

    with_home do |_home, env|
      store = adapter_class.new(env: env.merge(override_env)).locate
      assert_equal expected_override_path, store.effective.path
    end
  end

  def test_conformance_locate_never_raises_when_absent
    with_home do |_home, env|
      store = adapter_class.new(env: env).locate
      refute store.installed?
    end
  end

  def test_conformance_instances_do_not_share_state
    first = adapter_class.new(env: { "HOME" => "/home-one" }).locate.effective.path
    second = adapter_class.new(env: { "HOME" => "/home-two" }).locate.effective.path
    refute_equal first, second
  end

  # --- Layer 2 conformance ---------------------------------------------------
  # Opt in by additionally defining:
  #   expected_session_id     -> id of the single session build_fixture creates
  #   expected_project_path   -> the project recorded in that fixture, or nil
  #                              when the agent genuinely cannot know it
  # Tests skip when these are absent, so Layer-1-only adapters stay green.

  def test_conformance_sessions_are_lazy
    with_home do |_home, env|
      assert_instance_of Enumerator::Lazy, adapter_class.new(env: env).sessions
    end
  end

  def test_conformance_absent_agent_has_no_sessions
    with_home do |_home, env|
      assert_empty adapter_class.new(env: env).sessions.force
    end
  end

  def test_conformance_enumerates_exactly_the_fixture_session
    skip_unless_layer2
    with_home do |home, env|
      build_fixture(home)
      sessions = adapter_class.new(env: env).sessions.force
      assert_equal [expected_session_id], sessions.map(&:id)
      session = sessions.first
      assert_equal adapter_class.agent_name, session.agent
      assert_equal "#{adapter_class.agent_name}:#{expected_session_id}", session.uid
      refute_nil session.updated_at
      assert_includes %i[full messages metadata unsupported], session.fidelity
    end
  end

  def test_conformance_project_path_matches_the_fixture
    skip_unless_layer2
    with_home do |home, env|
      build_fixture(home)
      session = adapter_class.new(env: env).sessions.first
      if expected_project_path.nil?
        assert_nil session.project_path
      else
        assert_equal expected_project_path, session.project_path
      end
    end
  end

  def test_conformance_for_project_round_trips
    skip_unless_layer2
    skip "#{adapter_class.agent_name} cannot know its project paths" if expected_project_path.nil?

    with_home do |home, env|
      build_fixture(home)
      adapter = adapter_class.new(env: env)
      found = adapter.sessions_for_project(expected_project_path).force
      assert_equal [expected_session_id], found.map(&:id)
      assert_empty adapter.sessions_for_project("/definitely/not/this/project").force
    end
  end

  private

  def skip_unless_layer2
    return if respond_to?(:expected_session_id, true)

    skip "define expected_session_id and expected_project_path for Layer 2 conformance"
  end
end
