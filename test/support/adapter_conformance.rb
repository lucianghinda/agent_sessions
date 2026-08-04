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
    refute_nil adapter_class.documented_value
    refute_empty adapter_class.store_configs
  end

  def test_conformance_locates_under_default_home
    with_home do |home, env|
      build_fixture(home)
      store = AgentSessions.locate(adapter_class.agent_name, env: env)
      assert_equal expected_default_path(home), store.effective.path
      assert store.effective.exists?
      assert store.installed?
    end
  end

  def test_conformance_env_override_wins
    with_home do |_home, env|
      store = AgentSessions.locate(adapter_class.agent_name, env: env.merge(override_env))
      assert_equal expected_override_path, store.effective.path
    end
  end

  def test_conformance_locate_never_raises_when_absent
    with_home do |_home, env|
      store = AgentSessions.locate(adapter_class.agent_name, env: env)
      refute store.installed?
    end
  end
end
