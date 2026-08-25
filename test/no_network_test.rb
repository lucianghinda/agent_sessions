# frozen_string_literal: true

require "agent/sessions"
require_relative "test_helper"

class NoNetworkTest < Minitest::Test
  include FixtureHelpers

  # Design doc section 10, promise #2. Net::HTTP is stdlib and never autoloaded,
  # so $LOADED_FEATURES answers "was it ever constituted" directly.
  def test_never_loads_net_http
    refute net_http_loaded?, "net/http was already loaded before the public API ran; this test needs a clean process"

    with_home do |home, env|
      touch(home, ".claude", "projects", "-p", "s.jsonl")
      touch(home, ".codex", "sessions", "2026", "07", "21", "rollout-a.jsonl")

      Agent::Sessions.all(env: env)
      Agent::Sessions.installed(env: env)
      Agent::Sessions.verify(env: env)
      Agent::Sessions.doctor(env: env)
      Agent::Sessions.audit(env: env)

      %w[where doctor audit].each do |command|
        [[command], [command, "--json"]].each do |argv|
          Agent::Sessions::CLI.new(argv, env: env, stdout: StringIO.new, stderr: StringIO.new).run
        end
      end
    end

    refute net_http_loaded?, "Agent::Sessions must never load net/http"
  end

  private

  def net_http_loaded?
    $LOADED_FEATURES.any? { |feature| feature.end_with?("net/http.rb") }
  end
end
