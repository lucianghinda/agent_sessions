# agent_sessions

Where do AI coding agents store their session logs? This gem knows.

Resolves session store paths for Claude Code, Codex CLI, Cursor (CLI and IDE), Amp CLI, opencode, pi, Gemini CLI, GitHub Copilot CLI, Qwen Code, and Grok Build. Verifies those paths against disk. Audits whether plaintext transcripts sit inside anything that syncs.

Read-only by design. Runtime dependencies: `agent_homedir` and `zeitwerk`.

Most of these eleven layouts are undocumented, or only partly documented, by their vendors and can move in any release — Copilot CLI's moved from JSONL files to SQLite, and Cursor IDE's was found in a different directory than the one previously believed. Each adapter carries the date its claims were last checked against a real install, and `agent-sessions doctor` reports both that date and what disk says now.

Two adapters, Qwen Code and Grok Build, are marked provisional: no such store existed on the machine they were written against, so they follow another tool's working parser of the same format rather than direct observation. They say so at runtime.

## Installation

Add to your Gemfile:

```ruby
gem "agent_sessions"
```

## Quick start

```sh
agent-sessions where
agent-sessions doctor
agent-sessions audit
agent-sessions list --since 30d
agent-sessions du --by project
```

Add `--json` to `where`, `doctor`, `audit`, `list`, or `du` for machine-readable output. `du --by project` is the one command in the gem that is not stat-only: resolving a project name pays one bounded read per session for the file-based agents (opencode answers from its own SQL query instead, so it pays nothing extra).

## Ruby API

```ruby
require "agent_sessions" # compatibility shim for Agent::Sessions

store = Agent::Sessions.locate(:codex)
store.effective.path   # => "/Users/you/.codex/sessions"
store.format           # => :jsonl
store.documented?      # => false
store.retention        # => nil ("grows forever")
```

List agents:

```ruby
Agent::Sessions.all        # every supported agent
Agent::Sessions.installed  # only agents present on this machine
```

Verify claims against disk:

```ruby
Agent::Sessions.verify(:codex)
# => [#<Check status: :pass, claim: "store sessions exists", ...>]
```

Resolve for an environment that is not your own:

```ruby
Agent::Sessions.locate(:codex, env: { "CODEX_HOME" => "/tmp/x" })
```

Enumerate sessions and map them to projects:

```ruby
Agent::Sessions.sessions(:claude).first(5)      # lazy; stats files, never parses them
Agent::Sessions.for_project(Dir.pwd)            # every agent's sessions for one project
Agent::Sessions.projects(:codex)                # distinct recorded project paths (reads headers)
```

Enumerating the SQLite-backed agents — opencode, Cursor IDE and Copilot CLI — needs the optional `sqlite3` gem. Readers exist for opencode and Copilot CLI; Cursor IDE remains metadata-only. The other adapters do not need that additional optional dependency.

Read a session's messages and token usage (Claude, Codex, Amp, opencode, pi, Gemini CLI, Copilot CLI, Qwen and Grok):

```ruby
reader = Agent::Sessions.read(session)
reader.each_message { |m| puts "#{m.role}: #{m.text}" }  # streams; raw is never dropped
reader.usage                                  # session token totals, or nil if not recorded
reader.usage&.input                           # disjoint buckets: input, output, cache_read,
                                              #   cache_creation, reasoning, cost
```

`Usage` is normalized across agents: `input` never includes cached tokens (Codex counts them inclusively; the reader subtracts), and a `nil` dimension means the format does not record it — never zero. `cost` is only ever what the agent itself reported; this gem ships no pricing table.

`Session#bytes` is what that session occupies on disk, not just its transcript. Claude Code writes a sidecar directory beside each transcript — `<id>/subagents/`, `<id>/tool-results/` — and those bytes belong to the session that produced them, which is why `du` and `audit` agree on the same store.

## Roadmap

- 0.2: enumerate sessions, map them to projects (`list`, `du`)
- **0.3 (this release):** read and normalize messages; Ruby API renamed to `Agent::Sessions` while `require "agent_sessions"` stays as the compatibility shim, and base-dir resolution delegates to `agent_homedir`
- 0.4: Cursor IDE remains metadata-only; the opencode and Copilot CLI SQLite readers landed in 0.3
- 0.5: `export` with secret redaction

## History

View the [changelog](CHANGELOG.md).
