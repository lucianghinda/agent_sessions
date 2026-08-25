# frozen_string_literal: true

class FakeAdapter < Agent::Sessions::Adapters::Base
  agent :fake
  label "Fake Agent"
  documented true
  verified_on "2026-07-01"
  fidelity :full

  base_dir default: "~/.fake", env: "FAKE_HOME"

  store :sessions, dir: "sessions", glob: "*.jsonl", format: :jsonl
  store :history, path: "history.jsonl", format: :jsonl, optional: true, env: "FAKE_HISTORY_FILE"

  warning "fake is fake"
end
