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

  # The dir:/path: distinction is the only place the gem knows a layer is one file
  # rather than a directory. Discarding it at resolution time is what made
  # layers.flat_map(&:files) silently skip every single-file layer.
  def test_path_stores_resolve_to_single_file_locations
    store = FakeAdapter.new(env: { "HOME" => "/h" }).locate
    by_kind = store.layers.to_h { |l| [l.kind, l] }
    assert by_kind.fetch(:history).single_file
    refute by_kind.fetch(:sessions).single_file
  end

  def test_env_overridden_path_store_is_still_a_single_file
    store = FakeAdapter.new(env: { "HOME" => "/h", "FAKE_HISTORY_FILE" => "/elsewhere/hist.jsonl" }).locate
    assert store.layers.find { |l| l.kind == :history }.single_file
  end

  def test_gathering_every_layer_includes_single_file_layers
    with_home do |home, env|
      touch(home, ".fake", "sessions", "a.jsonl")
      touch(home, ".fake", "history.jsonl")
      files = FakeAdapter.new(env: env).locate.layers.flat_map(&:files)
      assert_includes files, File.join(home, ".fake", "sessions", "a.jsonl")
      assert_includes files, File.join(home, ".fake", "history.jsonl")
    end
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

  def test_empty_home_falls_back_like_an_absent_one
    with_default = FakeAdapter.new(env: {}).locate.effective.path
    assert_equal with_default, FakeAdapter.new(env: { "HOME" => "" }).locate.effective.path
  end

  def test_sessions_is_a_lazy_enumerator
    with_home do |_home, env|
      assert_instance_of Enumerator::Lazy, FakeAdapter.new(env: env).sessions
    end
  end

  def test_sessions_builds_one_session_per_primary_store_file
    with_home do |home, env|
      touch(home, ".fake", "sessions", "abc.jsonl")
      touch(home, ".fake", "history.jsonl") # a different layer — not a session
      sessions = FakeAdapter.new(env: env).sessions.force
      assert_equal ["abc"], sessions.map(&:id)
      session = sessions.first
      assert_equal :fake, session.agent
      assert_equal File.join(home, ".fake", "sessions", "abc.jsonl"), session.path
      assert_equal :jsonl, session.format
      assert_equal :full, session.fidelity
      assert_equal File.mtime(session.path), session.updated_at
      assert_equal 0, session.bytes
    end
  end

  def test_default_project_path_is_nil
    with_home do |home, env|
      touch(home, ".fake", "sessions", "abc.jsonl")
      assert_nil FakeAdapter.new(env: env).sessions.first.project_path
    end
  end

  def test_fidelity_defaults_to_unsupported_when_undeclared
    adapter = Class.new(AgentSessions::Adapters::Base) { agent :bare }
    assert_equal :unsupported, adapter.fidelity_value
  end

  def test_fidelity_rejects_unknown_values
    error = assert_raises(ArgumentError) do
      Class.new(AgentSessions::Adapters::Base) { fidelity :excellent }
    end
    assert_includes error.message, "excellent"
  end

  def test_sessions_for_project_uses_the_encoded_dir_when_the_adapter_has_a_rule
    encoding = Class.new(AgentSessions::Adapters::Base) do
      agent :cheap
      label "Cheap"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.cheap"
      store :sessions, dir: "sessions", glob: "*/*.jsonl", format: :jsonl

      def encode_project(dir) = dir.gsub(/[^a-zA-Z0-9]/, "-")
      # No project_path_for: if the cheap path reads file content, this raises.
      def project_path_for(_path) = raise("cheap path must not read")
    end

    with_home do |home, env|
      touch(home, ".cheap", "sessions", "-Users-you-app", "s1.jsonl")
      touch(home, ".cheap", "sessions", "-Users-you-other", "s2.jsonl")
      found = encoding.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["s1"], found.map(&:id)
    end
  end

  def test_sessions_for_project_falls_back_to_reading_project_paths
    reading = Class.new(AgentSessions::Adapters::Base) do
      agent :slow
      label "Slow"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.slow"
      store :sessions, dir: "sessions", glob: "*.json", format: :json

      def project_path_for(path) = read_json(path)["cwd"]
    end

    with_home do |home, env|
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s1.json")
      write('{"cwd":"/Users/you/other"}', home, ".slow", "sessions", "s2.json")
      found = reading.new(env: env).sessions_for_project("/Users/you/app").force
      assert_equal ["s1"], found.map(&:id)
    end
  end

  def test_project_paths_reads_distinct_recorded_projects
    reading = Class.new(AgentSessions::Adapters::Base) do
      agent :slow
      label "Slow"
      documented true
      verified_on "2026-07-01"
      base_dir default: "~/.slow"
      store :sessions, dir: "sessions", glob: "*.json", format: :json

      def project_path_for(path) = read_json(path)["cwd"]
    end

    with_home do |home, env|
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s1.json")
      write('{"cwd":"/Users/you/app"}', home, ".slow", "sessions", "s2.json")
      write("{}", home, ".slow", "sessions", "s3.json") # unknowable — excluded, not nil
      assert_equal ["/Users/you/app"], reading.new(env: env).project_paths
    end
  end
end
