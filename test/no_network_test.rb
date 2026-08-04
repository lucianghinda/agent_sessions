# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/agent_sessions/cli"

class NoNetworkTest < Minitest::Test
  include FixtureHelpers

  # Design doc section 10, promise #2. Net::HTTP is stdlib and never autoloaded,
  # so $LOADED_FEATURES answers "was it ever constituted" directly.
  def test_never_loads_net_http
    refute net_http_loaded?, "net/http was already loaded before the public API ran; this test needs a clean process"

    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      touch(home, ".codex", "sessions", "2026", "07", "21", "rollout-a.jsonl")

      AgentSessions.all(env: env)
      AgentSessions.installed(env: env)
      AgentSessions.verify(env: env)
      AgentSessions.doctor(env: env)
      AgentSessions.audit(env: env)

      %w[where doctor audit].each do |command|
        [[command], [command, "--json"]].each do |argv|
          AgentSessions::CLI.new(argv, env: env, stdout: StringIO.new, stderr: StringIO.new).run
        end
      end
    end

    refute net_http_loaded?, "AgentSessions must never load net/http"
  end

  private

  def net_http_loaded?
    $LOADED_FEATURES.any? { |feature| feature.end_with?("net/http.rb") }
  end
end
