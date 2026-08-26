# Module Agent::Sessions <a id="module-Agent-Sessions"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/agent/sessions.rb, lib/agent/sessions/cli.rb, lib/agent/sessions/node.rb, lib/agent/sessions/part.rb, lib/agent/sessions/audit.rb, lib/agent/sessions/check.rb, lib/agent/sessions/error.rb, lib/agent/sessions/store.rb, lib/agent/sessions/usage.rb, lib/agent/sessions/sqlite.rb, lib/agent/sessions/message.rb, lib/agent/sessions/session.rb, lib/agent/sessions/version.rb, lib/agent/sessions/location.rb, lib/agent/sessions/compaction.rb, lib/agent/sessions/readers/pi.rb, lib/agent/sessions/adapters/pi.rb, lib/agent/sessions/readers/amp.rb, lib/agent/sessions/adapters/amp.rb, lib/agent/sessions/env_override.rb, lib/agent/sessions/readers/base.rb, lib/agent/sessions/readers/grok.rb, lib/agent/sessions/readers/qwen.rb, lib/agent/sessions/adapters/base.rb, lib/agent/sessions/adapters/grok.rb, lib/agent/sessions/adapters/qwen.rb, lib/agent/sessions/readers/codex.rb, lib/agent/sessions/unknown_agent.rb, lib/agent/sessions/adapters/codex.rb, lib/agent/sessions/home_expansion.rb, lib/agent/sessions/readers/claude.rb, lib/agent/sessions/readers/gemini.rb, lib/agent/sessions/adapters/claude.rb, lib/agent/sessions/adapters/cursor.rb, lib/agent/sessions/adapters/gemini.rb, lib/agent/sessions/readers/copilot.rb, lib/agent/sessions/adapters/copilot.rb, lib/agent/sessions/readers/opencode.rb, lib/agent/sessions/unreadable_store.rb, lib/agent/sessions/adapters/opencode.rb, lib/agent/sessions/missing_dependency.rb, lib/agent/sessions/unsupported_format.rb, lib/agent/sessions/adapters/cursor_ide.rb, lib/agent/sessions/adapters/enumeration.rb |

## Constants
### `LOADER` <a id="constant-LOADER"></a> <a id="LOADER-constant"></a>
Not documented.

### `STALE_AFTER_DAYS` <a id="constant-STALE_AFTER_DAYS"></a> <a id="STALE_AFTER_DAYS-constant"></a>
Not documented.

### `VERIFIED_ON` <a id="constant-VERIFIED_ON"></a> <a id="VERIFIED_ON-constant"></a>
The oldest verified_on among the built-in adapters. A claim about somebody
else's software is only as current as its weakest link, so this is the honest
answer to "when was this last known to be true".

### `VERSION` <a id="constant-VERSION"></a> <a id="VERSION-constant"></a>
Not documented.

## Public Class Methods
### `agents()` <a id="method-c-agents"></a> <a id="agents-class_method"></a>
Not documented.

### `all(env: ENV)` <a id="method-c-all"></a> <a id="all-class_method"></a>
Not documented.

### `audit(env: ENV)` <a id="method-c-audit"></a> <a id="audit-class_method"></a>
Not documented.

### `doctor(agent = nil, env: ENV, today: Date.today)` <a id="method-c-doctor"></a> <a id="doctor-class_method"></a>
Not documented.

### `for_project(dir, env: ENV, agents: nil)` <a id="method-c-for_project"></a> <a id="for_project-class_method"></a>
One project across every agent (or the agents: subset), lazily: adapters
earlier in the sweep satisfy `first(n)` without the later ones ever being
asked. Within one adapter, though, laziness cannot skip non-matching sessions
— sessions_for_project must still stat and check each candidate to know it
does not match, so an adapter with zero matches costs a full scan of its store
before the sweep moves on. True of the six Base-driven adapters; opencode
pushes the filter into SQL (WHERE directory = ?) and stats nothing.

Deliberately does NOT rescue MissingDependency or UnreadableStore: opencode
without the sqlite3 gem, or with a corrupt/locked database, raises. Since
`flat_map` is lazy, that raise surfaces only once enumeration reaches the
failing adapter — possibly after other agents' sessions have already been
yielded to the caller mid-iteration, and possibly not at all if `first(n)` is
satisfied first. Silently omitting an agent's sessions is this gem's worst
failure mode (design doc decision 11), so this method never trades a raised,
attributable error for a quietly incomplete list. A caller that wants the
sweep to survive one bad agent should rescue per call, e.g. by driving
<code>agents:</code> itself and catching around each adapter; a caller who
just wants to route around a known-bad agent can pass <code>agents:</code>
naming every registered agent except it. The CLI (Task 10) does the former,
turning the same exceptions into per-agent "skipped" lines instead of one
failed sweep. Note a rescue cannot resume this enumerator: re-calling each
after a raise re-raises from the same adapter. The only recovery is a fresh
call with a narrower <code>agents:</code>. Adapters are resolved eagerly, so
an unknown name in <code>agents:</code> raises here rather than mid-sweep. The
deferral above is about DATA conditions, where the raise carries information
about a store; a typo'd agent symbol is a programmer error knowable before any
I/O, and `agents: [:claude, :nope]` otherwise hands back Claude's sessions and
then crashes. Base#initialize only stores @env, so constructing all seven up
front costs nothing, and the sweep stays lazy — first(n) still stops at the
first matching adapter.

### `installed(env: ENV)` <a id="method-c-installed"></a> <a id="installed-class_method"></a>
Not documented.

### `locate(agent, env: ENV)` <a id="method-c-locate"></a> <a id="locate-class_method"></a>
Not documented.

### `projects(agent, env: ENV)` <a id="method-c-projects"></a> <a id="projects-class_method"></a>
Eager, unlike sessions/for_project: project_paths already reads every session
to answer (design doc section 7 — the on-disk encodings are lossy, so the
recorded cwd is the only reliable source), sorts, and dedupes, so a lazy
return type here would promise a laziness the work underneath cannot honor.
Returns a plain, already-sorted Array. Raises MissingDependency or
UnreadableStore for opencode, as sessions does.

### `read(session, **options)` <a id="method-c-read"></a> <a id="read-class_method"></a>
Layer 3. Takes a Session (from `sessions`, `for_project`), not an agent name,
because reading is per-session — the adapter comes from the session itself.
Raises UnsupportedFormat for an agent with no reader yet, rather than
returning a reader that yields nothing: "this gem cannot read that format" and
"that session has no messages" must never look alike.

include_events: true adds the agent's UI-level records to the stream where an
adapter has them. They are excluded by default because they are bookkeeping,
not conversation, and they outnumber real messages.

### `register(adapter_class)` <a id="method-c-register"></a> <a id="register-class_method"></a>
Re-registering a name deliberately replaces it, so a consumer can ship a
corrected adapter for an agent whose layout moved before the gem catches up.
- **@raise** [Error]

### `registry()` <a id="method-c-registry"></a> <a id="registry-class_method"></a>
Not documented.

### `sessions(agent, env: ENV, since: nil)` <a id="method-c-sessions"></a> <a id="sessions-class_method"></a>
Lazy: consuming N sessions stats N files, never more. `since`, when given,
must be a Time (or anything Time#>= accepts) — comparing updated_at (always a
Time; every adapter populates it, from mtime or store metadata) against a
Date, Integer, or String raises ArgumentError("comparison of Time with ...
failed"), which already names the mistake, so no extra guard is added here.
That raise happens on enumeration, not on this call, because the filter itself
is lazy — `sessions(:x, since: bad).first(1)` can raise from inside `first`,
not from this line. Raises MissingDependency or UnreadableStore for opencode
under the same conditions described on for_project below.

### `unresolved_project_count(agent, env: ENV)` <a id="method-c-unresolved_project_count"></a> <a id="unresolved_project_count-class_method"></a>
Companion to `projects`/`project_paths`, which both exclude a session whose
project could not be resolved rather than counting it (design doc section 7) —
so "this agent genuinely records no projects" and "this agent's project
resolution is broken" read identically from the outside. Three of seven
adapters can legitimately return a nil project_path (Amp threads with no
`trees`, cursor_ide by design, pi whenever its unverified header assumption is
wrong); this counts it for any of them, uniformly, using only the public
`sessions` enumerator —no adapter needs to know this exists. Eager and a
second full sweep of the store, same cost class as `projects` itself, so it is
opt-in (called by the CLI only under `list --project`, never under plain
`list`) rather than folded into `projects`' own return value, which is a
documented, tested plain Array and would otherwise need a shape change to
carry both numbers. Raises MissingDependency or UnreadableStore for opencode,
as sessions does.

### `verify(agent = nil, env: ENV)` <a id="method-c-verify"></a> <a id="verify-class_method"></a>
Not documented.

# Documentation

- [Sessions/Adapters.md](Sessions/Adapters.md)
- [Sessions/Adapters/Amp.md](Sessions/Adapters/Amp.md)
- [Sessions/Adapters/Base.md](Sessions/Adapters/Base.md)
- [Sessions/Adapters/Claude.md](Sessions/Adapters/Claude.md)
- [Sessions/Adapters/Codex.md](Sessions/Adapters/Codex.md)
- [Sessions/Adapters/Copilot.md](Sessions/Adapters/Copilot.md)
- [Sessions/Adapters/Cursor.md](Sessions/Adapters/Cursor.md)
- [Sessions/Adapters/CursorIde.md](Sessions/Adapters/CursorIde.md)
- [Sessions/Adapters/Enumeration.md](Sessions/Adapters/Enumeration.md)
- [Sessions/Adapters/Gemini.md](Sessions/Adapters/Gemini.md)
- [Sessions/Adapters/Grok.md](Sessions/Adapters/Grok.md)
- [Sessions/Adapters/Opencode.md](Sessions/Adapters/Opencode.md)
- [Sessions/Adapters/Pi.md](Sessions/Adapters/Pi.md)
- [Sessions/Adapters/Qwen.md](Sessions/Adapters/Qwen.md)
- [Sessions/Audit.md](Sessions/Audit.md)
- [Sessions/Audit/Finding.md](Sessions/Audit/Finding.md)
- [Sessions/CLI.md](Sessions/CLI.md)
- [Sessions/Check.md](Sessions/Check.md)
- [Sessions/Compaction.md](Sessions/Compaction.md)
- [Sessions/EnvOverride.md](Sessions/EnvOverride.md)
- [Sessions/Error.md](Sessions/Error.md)
- [Sessions/HomeExpansion.md](Sessions/HomeExpansion.md)
- [Sessions/Location.md](Sessions/Location.md)
- [Sessions/Message.md](Sessions/Message.md)
- [Sessions/MissingDependency.md](Sessions/MissingDependency.md)
- [Sessions/Node.md](Sessions/Node.md)
- [Sessions/Part.md](Sessions/Part.md)
- [Sessions/Readers.md](Sessions/Readers.md)
- [Sessions/Readers/Amp.md](Sessions/Readers/Amp.md)
- [Sessions/Readers/Base.md](Sessions/Readers/Base.md)
- [Sessions/Readers/Claude.md](Sessions/Readers/Claude.md)
- [Sessions/Readers/Codex.md](Sessions/Readers/Codex.md)
- [Sessions/Readers/Copilot.md](Sessions/Readers/Copilot.md)
- [Sessions/Readers/Gemini.md](Sessions/Readers/Gemini.md)
- [Sessions/Readers/Grok.md](Sessions/Readers/Grok.md)
- [Sessions/Readers/Opencode.md](Sessions/Readers/Opencode.md)
- [Sessions/Readers/Pi.md](Sessions/Readers/Pi.md)
- [Sessions/Readers/Qwen.md](Sessions/Readers/Qwen.md)
- [Sessions/Session.md](Sessions/Session.md)
- [Sessions/Sqlite.md](Sessions/Sqlite.md)
- [Sessions/Store.md](Sessions/Store.md)
- [Sessions/UnknownAgent.md](Sessions/UnknownAgent.md)
- [Sessions/UnreadableStore.md](Sessions/UnreadableStore.md)
- [Sessions/UnsupportedFormat.md](Sessions/UnsupportedFormat.md)
- [Sessions/Usage.md](Sessions/Usage.md)
