# frozen_string_literal: true

require_relative "test_helper"

class CursorAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Cursor

  def build_fixture(home)
    write("", home, ".cursor", "chats", "chat-1", "0192-uuid", "store.db")
  end

  def expected_default_path(home) = File.join(home, ".cursor", "chats")

  def override_env = nil

  def test_warns_that_chat_payloads_are_undecoded
    with_home do |_home, env|
      store = AgentSessions.locate(:cursor, env: env)
      assert(store.warnings.any? { |w| w.include?("blob") })
    end
  end

  def test_xdg_config_home_does_not_move_cursor
    store = AgentSessions.locate(:cursor, env: { "HOME" => "/h", "XDG_CONFIG_HOME" => "/xdg/config" })
    assert_equal "/h/.cursor/chats", store.effective.path
  end
end

class CursorIdeAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::CursorIde

  def build_fixture(home)
    touch(home, ".cursor", "projects", "my-app", "agent-transcripts", "t1")
  end

  def expected_default_path(home) = File.join(home, ".cursor", "projects")

  def override_env = nil

  def test_ide_is_a_separate_agent_from_the_cli
    refute_equal AgentSessions.registry[:cursor], AgentSessions.registry[:cursor_ide]
  end

  def test_warns_stores_do_not_sync
    with_home do |_home, env|
      store = AgentSessions.locate(:cursor_ide, env: env)
      assert(store.warnings.any? { |w| w.include?("sync") })
    end
  end
end
