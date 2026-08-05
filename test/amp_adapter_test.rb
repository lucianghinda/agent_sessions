# frozen_string_literal: true

require_relative "test_helper"

class AmpAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Amp

  # Real thread shape, verified 2026-08-05: created is epoch ms and
  # env.initial.trees[0].uri carries the project as a file:// URI.
  def build_fixture(home)
    thread = {
      v: 5, id: "T-0192aa", created: 1_752_484_323_000, title: "fixture",
      env: { initial: { trees: [{ displayName: "app", uri: "file:///Users/you/app" }] } },
      messages: []
    }
    write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-0192aa.json")
  end

  def expected_session_id = "T-0192aa"
  def expected_project_path = "/Users/you/app"

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

  def test_project_path_decodes_percent_escapes_in_the_file_uri
    with_home do |home, env|
      thread = { env: { initial: { trees: [{ uri: "file:///Users/you/My%20Drive/app" }] } } }
      write(JSON.generate(thread), home, ".local", "share", "amp", "threads", "T-b.json")
      session = AgentSessions::Adapters::Amp.new(env: env).sessions.first
      assert_equal "/Users/you/My Drive/app", session.project_path
    end
  end

  def test_threads_without_trees_have_no_project
    with_home do |home, env|
      write(JSON.generate({ id: "T-c", messages: [] }),
            home, ".local", "share", "amp", "threads", "T-c.json")
      assert_nil AgentSessions::Adapters::Amp.new(env: env).sessions.first.project_path
    end
  end

  def test_fidelity_is_messages
    assert_equal :messages, AgentSessions::Adapters::Amp.fidelity_value
  end
end
