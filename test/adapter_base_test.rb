# frozen_string_literal: true

require_relative "test_helper"

class AdapterBaseTest < Minitest::Test
  include FixtureHelpers

  def test_resolves_default_base_dir_under_injected_home
    with_home do |home, env|
      store = FakeAdapter.new(env: env).locate
      assert_equal File.join(home, ".fake", "sessions"), store.effective.path
      assert_equal :jsonl, store.format
      assert_equal :fake, store.agent
      assert_equal "Fake Agent", store.label
      assert store.documented?
      assert_equal Date.new(2026, 7, 1), store.verified_on
    end
  end

  def test_base_env_override_replaces_base_dir
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "/custom" }).locate
    assert_equal "/custom/sessions", store.effective.path
  end

  def test_store_level_env_override_replaces_store_root
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HISTORY_FILE" => "/elsewhere/hist.jsonl" }).locate
    history = store.layers.find { |l| l.kind == :history }
    assert_equal "/elsewhere/hist.jsonl", history.path
  end

  def test_reports_all_env_overrides_with_state
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "/custom" }).locate
    by_name = store.env_overrides.to_h { |o| [o.name, o] }
    assert by_name.fetch("FAKE_HOME").active?
    refute by_name.fetch("FAKE_HISTORY_FILE").active?
  end

  def test_empty_env_value_is_ignored
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "" }).locate
    assert_equal "/h/.fake/sessions", store.effective.path
  end

  def test_declared_warnings_surface
    store = FakeAdapter.new(env: { "HOME" => "/h" }).locate
    assert_includes store.warnings, "fake is fake"
  end

  def test_retention_defaults_to_none
    store = FakeAdapter.new(env: { "HOME" => "/h" }).locate
    assert_nil store.retention
    assert_equal :none, store.retention_source
  end

  def test_installed_reflects_disk
    with_home do |home, env|
      refute FakeAdapter.new(env: env).locate.installed?
      touch(home, ".fake", "sessions", "a.jsonl")
      assert FakeAdapter.new(env: env).locate.installed?
    end
  end

  def test_dsl_macros_are_private
    refute_respond_to AgentSessions::Adapters::Base, :store
    refute_respond_to AgentSessions::Adapters::Base, :base_dir
  end

  def test_tilde_user_paths_stay_literal
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HOME" => "~root" }).locate
    assert_equal "~root/sessions", store.effective.path
  end

  def test_store_requires_exactly_one_of_dir_or_path
    missing = assert_raises(ArgumentError) do
      Class.new(AgentSessions::Adapters::Base) { store :bad, format: :jsonl }
    end
    assert_includes missing.message, "dir:"

    assert_raises(ArgumentError) do
      Class.new(AgentSessions::Adapters::Base) { store :bad, dir: "d", path: "p.jsonl", format: :jsonl }
    end
  end

  def test_adapter_without_stores_names_what_is_missing
    adapter = Class.new(AgentSessions::Adapters::Base) do
      agent :bare
      base_dir default: "~/.bare"
    end
    error = assert_raises(AgentSessions::Error) { adapter.new(env: { "HOME" => "/h" }).locate }
    assert_includes error.message, "store"
  end

  def test_adapter_without_base_dir_names_what_is_missing
    adapter = Class.new(AgentSessions::Adapters::Base) do
      agent :bare
      store :sessions, dir: "s", format: :jsonl
    end
    error = assert_raises(AgentSessions::Error) { adapter.new(env: { "HOME" => "/h" }).locate }
    assert_includes error.message, "base_dir"
  end
end
