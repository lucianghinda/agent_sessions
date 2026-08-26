# agent_sessions

Where do AI coding agents store their session logs? This gem knows.

![agent-sessions demo](demo.gif)

Resolves session store paths for Claude Code, Codex CLI, Cursor (CLI and IDE), Amp CLI, opencode, pi, Gemini CLI, GitHub Copilot CLI, Qwen Code, and Grok Build. Verifies those paths against disk. Audits whether plaintext transcripts sit inside anything that syncs.

Read-only by design. Runtime dependencies: `agent_homedir` and `zeitwerk`.

Most of these eleven layouts are undocumented, or only partly documented, by their vendors and can move in any release — Copilot CLI's moved from JSONL files to SQLite, and Cursor IDE's was found in a different directory than the one previously believed. Each adapter carries the date its claims were last checked against a real install, and `agent-sessions doctor` reports both that date and what disk says now.

Two adapters, Qwen Code and Grok Build, are marked provisional: no such store existed on the machine they were written against, so they follow another tool's working parser of the same format rather than direct observation. They say so at runtime.

## Installation

Use Ruby 3.2 or newer.

Install the CLI directly:

```sh
gem install agent_sessions
```

Or add to your application's Gemfile:

```ruby
gem "agent_sessions"
```

Enumerating the SQLite-backed agents — opencode, Cursor IDE, and GitHub Copilot CLI — needs the optional `sqlite3` gem. Every other adapter works without it.

## Quick start

```sh
agent-sessions where
agent-sessions doctor
agent-sessions audit
agent-sessions list --since 30d
agent-sessions du --by project
```

Add `--json` to `where`, `doctor`, `audit`, `list`, or `du` for machine-readable output. `du --by project` is the one command in the gem that is not stat-only: resolving a project name pays one bounded read per session for the file-based agents (opencode answers from its own SQL query instead, so it pays nothing extra).

## Supported agents

Use the bare name in CLI arguments and the symbol in Ruby calls:

| Agent | CLI | Ruby |
| --- | --- | --- |
| Claude Code | `claude` | `:claude` |
| Codex CLI | `codex` | `:codex` |
| Cursor CLI | `cursor` | `:cursor` |
| Cursor IDE | `cursor_ide` | `:cursor_ide` |
| Amp CLI | `amp` | `:amp` |
| opencode | `opencode` | `:opencode` |
| pi | `pi` | `:pi` |
| Gemini CLI | `gemini` | `:gemini` |
| GitHub Copilot CLI | `copilot` | `:copilot` |
| Qwen Code | `qwen` | `:qwen` |
| Grok Build | `grok` | `:grok` |

Ruby callers passing any other symbol get `Agent::Sessions::UnknownAgent`; its message lists the valid names. The CLI catches that error, prints its message, and exits with status 1.

## Ruby API

![agent_sessions Ruby API demo](demo-ruby.gif)

Browse the [generated API documentation](https://github.com/lucianghinda/agent_sessions/blob/main/doc/Agent/Sessions.md) or the consolidated [`llm.txt`](https://github.com/lucianghinda/agent_sessions/blob/main/llm.txt) reference.

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

Among the SQLite-backed agents, readers exist for opencode and Copilot CLI; Cursor IDE remains metadata-only.

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

### Errors

Every domain-specific error the gem raises descends from `Agent::Sessions::Error`:

- Catch `Agent::Sessions::UnknownAgent` for a name outside the supported-agents table; the message lists valid names.
- Catch `Agent::Sessions::MissingDependency` when a SQLite-backed agent is enumerated without the optional `sqlite3` gem installed.
- Catch `Agent::Sessions::UnsupportedFormat` when `read` is called on a session whose format has no reader (Cursor CLI and Cursor IDE).
- Catch `Agent::Sessions::UnreadableStore` when a store exists but cannot be opened.

## Roadmap

- 0.2: enumerate sessions, map them to projects (`list`, `du`)
- **0.3 (this release):** read and normalize messages; Ruby API renamed to `Agent::Sessions` while `require "agent_sessions"` stays as the compatibility shim, and base-dir resolution delegates to `agent_homedir`
- 0.4: a reader for Cursor IDE, which is metadata-only today
- 0.5: `export` with secret redaction

## Contributing

Activate Ruby 3.2 or newer.

Run the tests before sending a change:

```sh
bundle install
bundle exec rake test
```

Before a release, run:

```sh
bin/prepare_release
```

It runs the test suite, regenerates the API documentation and `llm.txt`, and builds the gem without publishing it.

## License

MIT

## History

View the [changelog](CHANGELOG.md).
