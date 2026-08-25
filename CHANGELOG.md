## Unreleased

- `Usage` (`input`, `output`, `cache_read`, `cache_creation`, `reasoning`, `cost`): token counts normalized to disjoint buckets across agents. `nil` means "this format does not record that dimension", never zero; `cost` is only ever agent-reported, never derived from a pricing table
- `Message#usage` and `Message#model`, populated where the format puts them on the message (Claude); `reader.usage` returns session totals or nil
- Claude usage dedups by `message.id` before summing: one API response streams into one record per content block repeating identical usage (94 of 124 message ids in one real transcript), so a naive sum roughly doubles what was billed
- Codex usage reads the last `token_count` record's running total and subtracts `cached_input_tokens` from `input_tokens` (Codex counts them inclusively; Claude disjointly — verified against real stores on both sides, 2026-08-24)
- Claude reader recognizes `atis-latch` and `bridge-session` (session state postdating the 2026-08-12 corpus, observed live 2026-08-24) instead of warning about them
- opencode reader — the first over SQLite: 13,804 messages from 365 real sessions with zero warnings, and its summed usage equals the store's own per-session rollup columns on all 365. One `tool` part becomes a `:tool_use` and a `:tool_result`; a `subtask` spawn becomes a `:tool_use` named after its agent; step markers, patches and file attachments stay in `raw`. Needs the optional `sqlite3` gem
- pi reader, explicitly provisional: written against tokentelemetry's working parser of the format, since no pi session files exist on the machine it was written on — every mapping degrades to `:unknown` + warning rather than crashing if real pi output disagrees
- **Four new agents: Gemini CLI, GitHub Copilot CLI, Qwen Code and Grok Build**, taking the gem from 7 adapters to 11
- Gemini CLI adapter + reader, verified against a real store (12 sessions, 121 records): `~/.gemini/tmp/<projectHash>/chats/session-*.json`, one JSON document per chat. Its `cached` count sits INSIDE `input` — established arithmetically across all 97 real token records, where `total` equals `input + output + thoughts + tool` and never adds `cached` — so the reader subtracts it, as it does for Codex. `thoughts` become `:thinking` parts carrying subject and description; `info` records are opt-in events. Filenames are UTC, unlike Codex's and pi's local-clock ones, and their trailing hex is NOT a session id (two real files share one), so the id is the whole basename
- GitHub Copilot CLI adapter + reader, verified against a real store: **the format has moved** to `~/.copilot/session-store.db` (SQLite, schema_version 3) from the `session-state/<id>/events.jsonl` layout the reference tooling still reads — an adapter following the older spec reports nothing on a current install. One `turns` row is a whole exchange and becomes two messages. No token or cost column exists anywhere in that schema, and the adapter says so rather than letting nil read as zero
- Qwen Code adapter + reader, and Grok Build adapter + reader — both PROVISIONAL and declared as such at runtime: neither store exists on the machine they were written on, so they follow tokentelemetry's parsers rather than observation, and every mapping degrades to `:unknown` + a warning rather than crashing if real output disagrees
- Grok's session is a directory, not a file: Layer 2 enumerates `summary.json`, the reader streams `chat_history.jsonl` beside it, and billed usage comes from a third file — `~/.grok/logs/unified.jsonl`, shared by every session and keyed by session id. `Readers::Base#record_path` is a new hook for exactly that split
- **Cursor IDE is repointed at the store it actually uses** — `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`, table `cursorDiskKV`, keys `composerData:<uuid>` — confirmed by opening it (6 real sessions on the machine this was written on, where the 0.2 declaration `~/.cursor/projects/*/agent-transcripts/*` did not exist at all). Fidelity rises from `:unsupported` to `:metadata`; content is still unread, because every record seen carried an empty `conversation`, and the adapter says so rather than guessing the turn format
- opencode store discovery now tries `OPENCODE_DATA_DIR`, `XDG_DATA_HOME`, `~/.local/share/opencode`, macOS `~/Library/Application Support/opencode` and the Windows app-data dirs, and matches `opencode*.db` rather than the plain name — a macOS user, or one on a release channel that renames the database, previously got an empty result from an agent they had used. A candidate must actually hold a database to win, so an empty directory cannot shadow a real store; two databases holding the same session report it once
- `base_dir default:` accepts a Hash keyed by platform (`:macos`, `:linux`, `:windows`) for IDE-hosted agents whose store genuinely moves between operating systems; a Hash missing this machine's platform raises rather than falling back to another platform's path
- `AgentSessions::Sqlite` extracts the one safe way this gem opens a SQLite store (read-only URI, escaped path, 5s busy timeout), now shared by the opencode adapter and reader
- Layer 3 begins: `AgentSessions.read(session)` returns a streaming reader — `each_message`, `messages`, `compactions`, `warnings`, `fidelity`, `partial?`
- `Message` (`role`, `at`, `parts`, `text`, `raw`) and `Part` (`:text`, `:thinking`, `:tool_use`, `:tool_result`, `:image`, `:unknown`); `raw` is never dropped
- Codex reader, the first: reads 73,946 messages from 415 real sessions with zero warnings and zero exceptions, at 4.5 ms per session
- `compacted` records become boundaries rather than messages — replaying their `replacement_history` would report the same turns twice
- `event_msg` records (38% of the corpus) are excluded unless `include_events: true`
- Readers stream at an 8 MB per-record cap, not Layer 2's 1 MB: 14 real records exceed 1 MB and the largest is 2.41 MB, so the smaller cap would have dropped real messages. A record past the cap is reported, never silently skipped
- `AgentSessions.read` raises `UnsupportedFormat` for an agent with no reader, so "cannot read this format" never looks like "this session is empty"
- Claude reader: 18,111 messages from 142 real transcripts, zero exceptions, 5.6 ms per session
- Claude's spilled tool output is resolved from the sidecar file, so a `:tool_result` carries content instead of a pointer — bounded to the session's own sidecar tree, because the path is read out of tool output and must never become a file-read primitive. `resolve_spills: false` turns it off
- `reader.subagents` returns readers for the transcripts a session spawned, never merged into its own messages — 124 of them on the machine this was written against
- Claude's nine session-state record types and its `system`/`attachment` context records are separated from turns; the latter two arrive with `include_events: true`
- Amp reader: `partial?` is true there, since the server holds the canonical copy. A thread is one JSON document rather than JSONL, so it is read whole under a 32 MB cap — the bound the gem's one unbounded read never had
- `reader.tree` returns the conversation as roots and continuations for an agent that records parent links, with `reader.branching?` to ask first. Claude branches at 374 points across 83 of 151 real transcripts — a turn edited and re-run leaves two children under one parent, which reading in file order shows as two histories interleaved
- Readers that record no parent links raise `UnsupportedFormat` from `tree` rather than returning an empty list, so "this format does not record that" never reads as "this session has none"
- Agents other than Codex, Claude and Amp have no reader yet; `Session#fidelity` already says what each one will support

## 0.2.0 (2026-08-10)

First public release. 0.1.0 was never tagged or published, so its work is
folded into this entry rather than shipping a changelog with two consecutive
"(unreleased)" headings under two different version numbers.

- Layer 1: resolve session store paths for Claude Code, Codex CLI, Cursor CLI, Cursor IDE, Amp CLI, opencode, and pi
- Layer 2: `Session`, lazy `sessions`, `for_project`, `projects` across all seven adapters
- `AgentSessions.sessions(agent, since:)`, `.for_project(dir, agents:)`, `.projects(agent)`
- `Session` is a plain, lazily-resolved value object: `project_path` is computed on first access and memoized
- `Location#files` replaces `matches`, aware of single-file layers (`single_file`, `enumerable?`)
- opencode session enumeration via a deferred read-only SQLite query, behind an **optional** `sqlite3` gem — the gemspec stays runtime-dependency-free
- CLI: `where`, `doctor`, `audit`, `list` (`--agent`, `--project`, `--since`), and `du` (`--by agent|project`), all with `--json` output
- Amp's `secrets.json` is now optional: a missing file reports drift, not failure
- `verify`'s skip gate now keys on store existence, not base-dir existence
- `doctor` takes its agent positionally, matching `where`
- `list`/`du` now exit non-zero when any agent's store had to be skipped, instead of exiting 0 with only a stderr notice
- Codex declares `archived_sessions/` (flat, optional) and enumerates it: an archived rollout file is a session, and `sessions`, `list`, `du`, and `audit` all report it now
- Claude's `Session#bytes` counts the sidecar directory each transcript gets — `<id>/subagents/`, `<id>/tool-results/` — so `du` and `audit` no longer disagree by 29% about the same store
- `Adapters::Base#bytes_for(path, stat)` is a new overridable hook, defaulting to the transcript's own size
