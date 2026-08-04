# frozen_string_literal: true

require_relative "lib/agent_sessions/version"

Gem::Specification.new do |spec|
  spec.name = "agent_sessions"
  spec.version = AgentSessions::VERSION
  spec.authors = ["Lucian Ghinda"]
  spec.email = ["dev@ghinda.com"]

  spec.summary = "Locate, enumerate, and read AI coding agent session logs"
  spec.description = "Resolves where AI coding agents (Claude Code, Codex CLI, Cursor, Amp, opencode, pi) " \
                     "store their session logs, verifies those paths against disk, and audits sync and " \
                     "backup exposure. Read-only by design."
  spec.homepage = "https://github.com/lucianghinda/agent_sessions"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["*.{md,txt}", "{lib,exe}/**/*"]
  spec.bindir = "exe"
  spec.executables = ["agent-sessions"]
  spec.require_paths = ["lib"]
end
