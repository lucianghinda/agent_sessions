# frozen_string_literal: true

require_relative "test_helper"

class OpencodeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Opencode

  def build_fixture(home)
    write("", home, ".local", "share", "opencode", "opencode.db")
  end

  def expected_default_path(home) = File.join(home, ".local", "share", "opencode", "opencode.db")

  def override_env = { "XDG_DATA_HOME" => "/xdg/data" }
  def expected_override_path = "/xdg/data/opencode/opencode.db"

  def test_database_is_sqlite_format
    with_home do |_home, env|
      assert_equal :sqlite, AgentSessions.locate(:opencode, env: env).format
    end
  end

  def test_legacy_storage_tree_is_a_separate_optional_layer
    with_home do |_home, env|
      store = AgentSessions.locate(:opencode, env: env)
      legacy = store.layers.find { |l| l.kind == :legacy }
      refute_nil legacy
      assert_equal :json, legacy.format
    end
  end
end
