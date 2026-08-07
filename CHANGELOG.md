## 0.2.0 (unreleased)

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
