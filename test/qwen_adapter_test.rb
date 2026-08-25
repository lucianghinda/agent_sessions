# frozen_string_literal: true

require_relative "test_helper"

# PROVISIONAL, like the adapter and reader: no ~/.qwen exists on the machine
# this was written on, so these fixtures encode tokentelemetry's parser of the
# format rather than observed Qwen output. A real Qwen session that
# contradicts one of them means fixing the fixture AND the adapter together.
class QwenAdapterTest < Minitest::Test
  include AdapterConformance

  def adapter_class = AgentSessions::Adapters::Qwen

  def build_fixture(home)
    records = [{ type: "user", timestamp: STAMP, cwd: "/Users/you/app",
                 message: { role: "user", content: "hello" } }]
    write(records.map { |r| JSON.generate(r) }.join("\n") + "\n",
          home, ".qwen", "projects", "my-app", "chats", "#{SESSION}.jsonl")
  end

  def expected_default_path(home) = File.join(home, ".qwen", "projects")

  def override_env = nil

  def expected_session_id = SESSION
  def expected_project_path = "/Users/you/app"

  def test_provisional_shape_is_declared_once_the_store_exists
    with_home do |home, env|
      refute(AgentSessions.locate(:qwen, env: env).warnings.any? { |w| w.include?("unverified") })
      build_fixture(home)
      assert(AgentSessions.locate(:qwen, env: env).warnings.any? { |w| w.include?("unverified") })
    end
  end

  # A record carrying "cwd": null must not shadow a later usable one — the
  # reason project_path_for passes a predicate to scan_jsonl_for_key.
  def test_a_null_cwd_does_not_shadow_a_later_usable_one
    with_home do |home, env|
      records = [{ type: "user", timestamp: STAMP, cwd: nil, message: { role: "user", content: "hi" } },
                 { type: "assistant", timestamp: STAMP, cwd: "/Users/you/app",
                   message: { role: "assistant", content: "hey" } }]
      write(records.map { |r| JSON.generate(r) }.join("\n") + "\n",
            home, ".qwen", "projects", "my-app", "chats", "#{SESSION}.jsonl")
      assert_equal "/Users/you/app", AgentSessions.sessions(:qwen, env: env).first.project_path
    end
  end

  private

  SESSION = "8f2c1e00-1111-4222-8333-444455556666"
  STAMP = "2026-07-21T09:12:03.000Z"
end
