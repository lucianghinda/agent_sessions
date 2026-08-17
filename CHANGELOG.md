## Unreleased

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
