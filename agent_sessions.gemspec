# frozen_string_literal: true

require_relative "lib/agent/sessions/version"

Gem::Specification.new do |spec|
  spec.name = "agent_sessions"
  spec.version = Agent::Sessions::VERSION
  spec.authors = ["Lucian Ghinda"]
  spec.email = ["dev@ghinda.com"]

  spec.summary = "Locate, verify, and read AI coding agent session logs"
  spec.description = "Supports 11 adapters for Claude Code, Codex CLI, Cursor CLI/IDE, Amp, opencode, pi, " \
                     "Gemini CLI, GitHub Copilot CLI, Qwen Code, and Grok Build; reads messages for nine " \
                     "agents, verifies store paths, maps sessions to projects, and audits sync exposure."
  spec.homepage = "https://github.com/lucianghinda/agent_sessions"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["*.{md,txt}", "{lib,exe}/**/*"]
  spec.bindir = "exe"
  spec.executables = ["agent-sessions"]
  spec.require_paths = ["lib"]

  spec.add_dependency "agent_homedir", "~> 0.3"
  spec.add_dependency "zeitwerk", "~> 2.8"
end
