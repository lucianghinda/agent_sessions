# agent_sessions

Where do AI coding agents store their session logs? This gem knows.

Resolves session store paths for Claude Code, Codex CLI, Cursor (CLI and IDE), Amp CLI, opencode, and pi. Verifies those paths against disk. Audits whether plaintext transcripts sit inside anything that syncs.

Read-only by design. Zero runtime dependencies.

Supported agents were last verified on **2026-07-21**. Five of these seven layouts are undocumented, or only partly documented, by their vendors and can move in any release — run `agent-sessions doctor` to check yours.

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
store = AgentSessions.locate(:codex)
store.effective.path   # => "/Users/you/.codex/sessions"
store.format           # => :jsonl
store.documented?      # => false
store.retention        # => nil ("grows forever")
```

List agents:

```ruby
AgentSessions.all        # every supported agent
AgentSessions.installed  # only agents present on this machine
```

Verify claims against disk:

```ruby
AgentSessions.verify(:codex)
# => [#<Check status: :pass, claim: "store sessions exists", ...>]
```

Resolve for an environment that is not your own:

```ruby
AgentSessions.locate(:codex, env: { "CODEX_HOME" => "/tmp/x" })
```

Enumerate sessions and map them to projects:

```ruby
AgentSessions.sessions(:claude).first(5)      # lazy; stats files, never parses them
AgentSessions.for_project(Dir.pwd)            # every agent's sessions for one project
AgentSessions.projects(:codex)                # distinct recorded project paths (reads headers)
```

Enumerating opencode needs the optional `sqlite3` gem; every other agent enumerates with the standard library alone.

`Session#bytes` is what that session occupies on disk, not just its transcript. Claude Code writes a sidecar directory beside each transcript — `<id>/subagents/`, `<id>/tool-results/` — and those bytes belong to the session that produced them, which is why `du` and `audit` agree on the same store.

## Roadmap

- **0.2 (this release):** enumerate sessions, map them to projects (`list`, `du`)
- **0.3 (next):** read and normalize messages for the file-based agents
- 0.4: SQLite readers (opencode, Cursor) via optional `sqlite3`
- 0.5: `export` with secret redaction

## History

View the [changelog](CHANGELOG.md).
