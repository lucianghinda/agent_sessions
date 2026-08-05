# frozen_string_literal: true

require_relative "test_helper"

class AmpAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Amp

  def build_fixture(home)
    touch(home, ".local", "share", "amp", "threads", "T-0192aa.json")
  end

  def expected_default_path(home) = File.join(home, ".local", "share", "amp", "threads")

  def override_env = { "XDG_DATA_HOME" => "/xdg/data" }
  def expected_override_path = "/xdg/data/amp/threads"

  def test_partly_documented_is_not_documented
    with_home do |_home, env|
      store = AgentSessions.locate(:amp, env: env)
      assert_equal :partly, store.documented
      refute store.documented?
    end
  end

  def test_warns_that_local_copy_is_partial
    with_home do |_home, env|
      store = AgentSessions.locate(:amp, env: env)
      assert(store.warnings.any? { |w| w.include?("canonical") })
    end
  end

  # secrets.json is optional (see verify_test) but must stay declared, so that audit
  # can still report a plaintext token file sitting inside a sync folder.
  def test_secrets_stays_a_layer_so_audit_can_see_it
    with_home do |_home, env|
      store = AgentSessions.locate(:amp, env: env)
      assert_includes store.layers.map(&:kind), :secrets
    end
  end
end
