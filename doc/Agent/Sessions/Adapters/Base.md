# Class Agent::Sessions::Adapters::Base <a id="class-Agent-Sessions-Adapters-Base"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Includes** | [Agent::Sessions::Adapters::Enumeration](Enumeration.md), [Agent::Sessions::HomeExpansion](../HomeExpansion.md) |
| **Defined in** | lib/agent/sessions/adapters/base.rb |

Base class for every agent adapter. Subclass this directly, never another
adapter: the DSL keeps its configuration in singleton instance variables,
which Ruby does not carry down a second level of inheritance, so a subclass of
a subclass would silently declare nothing.

An instance memoizes what it resolves. Build a new instance per resolution
rather than reusing one across changes to the env hash.

What lives here is Layer 1: where a store is, what it declares, and whether
disk agrees. Turning that store into sessions is Layer 2 and lives in
Enumeration, included below — the two halves met at 460 lines in one class and
were split before Layer 3 readers could make it three.

## Constants
### `FIDELITIES` <a id="constant-FIDELITIES"></a> <a id="FIDELITIES-constant"></a>
Not documented.

## Attributes
### `agent_name` [R] <a id="attribute-c-agent_name"></a> <a id="agent_name-class_method"></a>
Returns the value of attribute agent_name.

### `declared_warnings` [R] <a id="attribute-c-declared_warnings"></a> <a id="declared_warnings-class_method"></a>
Returns the value of attribute declared_warnings.

### `documented_value` [R] <a id="attribute-c-documented_value"></a> <a id="documented_value-class_method"></a>
Returns the value of attribute documented_value.

### `label_text` [R] <a id="attribute-c-label_text"></a> <a id="label_text-class_method"></a>
Returns the value of attribute label_text.

### `verified_on_date` [R] <a id="attribute-c-verified_on_date"></a> <a id="verified_on_date-class_method"></a>
Returns the value of attribute verified_on_date.

## Public Class Methods
### `fidelity_value()` <a id="method-c-fidelity_value"></a> <a id="fidelity_value-class_method"></a>
:unsupported is the honest default for an adapter that has not declared what a
reader could reconstruct from its format.

### `homedir_config()` <a id="method-c-homedir_config"></a> <a id="homedir_config-class_method"></a>
Not documented.

### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
The Layer 3 reader for this agent, or nil while it has none. nil is what makes
Agent::Sessions.read raise UnsupportedFormat instead of handing back a reader
that quietly yields nothing.

### `store_configs()` <a id="method-c-store_configs"></a> <a id="store_configs-class_method"></a>
Not documented.

## Public Instance Methods
### `base_dir()` <a id="method-i-base_dir"></a> <a id="base_dir-instance_method"></a>
Not documented.

### `bytes_for(_path, stat)` <a id="method-i-bytes_for"></a> <a id="bytes_for-instance_method"></a>
Bytes this session occupies on disk. The transcript alone for a store that
keeps one file per session; an adapter whose agent writes sidecar files beside
the transcript overrides this and adds them. Like the two time hooks it takes
the stat the enumerator already holds, so the common case still costs nothing
beyond the syscall already made.

An override runs EAGERLY for every session, so it carries build_session's
constraint: it must not raise on an unreadable path, or one bad sidecar takes
down the whole listing rather than its own row.

### `encode_project(_dir)` <a id="method-i-encode_project"></a> <a id="encode_project-instance_method"></a>
nil means this adapter has no directory-name fallback rule. Used only by
sessions_for_project, and only for a session whose own recorded cwd could not
be read. When overridden: dir arrives pre-expanded here from
sessions_for_project (File.expand_path), which is the precondition an override
may rely on — a direct caller must pass an absolute, expanded path itself, or
the encoding is nonsense ("app", "~/app", and a trailing slash all encode
differently from the canonical form real project directories were named from).

### `initialize(env: ENV)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Base] a new instance of Base

### `locate()` <a id="method-i-locate"></a> <a id="locate-instance_method"></a>
Not documented.

### `project_dir_name(path)` <a id="method-i-project_dir_name"></a> <a id="project_dir_name-instance_method"></a>
The directory whose name the encoding must match, when sessions_for_project
falls back to it. Overridable: not every store puts the encoded project
directly above the session file — cursor_ide nests
projects/<name>/agent-transcripts/*, where the immediate parent is
agent-transcripts and matching it would find nothing, silently.

### `project_path_for(_path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
nil means the project is unknown for this session. Adapters override with a
bounded read of their own metadata; Base cannot guess.

### `project_paths()` <a id="method-i-project_paths"></a> <a id="project_paths-instance_method"></a>
Distinct recorded project paths, sorted. This is the read-everything direction
(design doc section 7): the encodings cannot be reversed, so the recorded cwd
inside each file is the only reliable source. Sessions whose project cannot be
determined are excluded, not returned as nil.

Sorted rather than left in glob order because a stable order is what makes
`projects` output diffable and `du --by project` deterministic — and adapters
answering from a database would otherwise impose their own.

### `retention()` <a id="method-i-retention"></a> <a id="retention-instance_method"></a>
Not documented.

### `retention_source()` <a id="method-i-retention_source"></a> <a id="retention_source-instance_method"></a>
Not documented.

### `session_id_from(path)` <a id="method-i-session_id_from"></a> <a id="session_id_from-instance_method"></a>
--- Layer 2 hooks, overridable per adapter ---

### `sessions()` <a id="method-i-sessions"></a> <a id="sessions-instance_method"></a>
Lazily enumerates the primary store. Each consumed session costs one stat plus
filename parsing — never a content read. project_path is the exception and
pays for itself on first access.

A store the gem has no layout for is refused rather than reported empty:
Location#enumerable? exists precisely so "nothing here to enumerate" and
"enumerated, found none" stay distinguishable, and silently returning no
sessions is this gem's worst failure mode.

### `sessions_for_project(dir)` <a id="method-i-sessions_for_project"></a> <a id="sessions_for_project-instance_method"></a>
Match by RECORDED cwd, exact, per session (design doc section 7, revised
2026-08-05 — the third design for this method, kept honest here because the
next reader deserves to know why it is not "cheap"). The first two designs
were built and disproved against a real store, not in theory:

    1. Directory-name matching (the original design) assumed a
       session's parent directory equals encode(its own recorded cwd).
       A project rename breaks that: the agent keeps writing under the
       OLD encoded directory, so two directories can hold live sessions
       for the SAME current cwd, and name-only matching silently
       dropped the stale one — false negatives, the failure mode this
       gem treats as worst (decision 11).

    2. One-read-per-directory sampling (the first fix for #1) assumed
       sessions within a directory share a cwd, to keep the match
       sublinear. Reading a real renamed project's stale directory
       disproved that: two of its three sessions had been resumed after
       the rename and recorded the NEW cwd; the third was never resumed
       and still recorded the OLD one. Sampling one session and
       applying its verdict to the whole directory is wrong in BOTH
       directions on the same store — it invented a false positive
       here, and a different glob order would just as easily have
       reproduced #1's false negative for that same directory.
       Approximate cwd resolution doesn't make the error smaller; it
       just moves where it lands.

Measured cost of reading every session instead of sampling: 0.17 ms per
session (68 real Claude sessions, full sweep, 0.012s total) — 0.7s
extrapolated to a 4,000-session store. That is what the sampling complexity
was buying, and it is not a trade worth making: the enumerator is already
lazy, so a caller taking first(n) never pays for sessions it never asked
about, and even the worst case (every session checked, no match) stays under a
second on a store two orders of magnitude larger than anything observed.

A session whose own cwd cannot be read (the scan gave up, the file is
unreadable, the adapter declares no reader) falls back to comparing ITS OWN
directory's name against the encoding, when the adapter declares one — this is
the only thing encode_project still buys: it keeps a session with an
unreadable header from becoming invisible, without resolving an unknown
project for every other session that happens to share its directory.

### `started_at_for(_path, stat)` <a id="method-i-started_at_for"></a> <a id="started_at_for-instance_method"></a>
Both time hooks take the stat the enumerator already holds, so a session still
costs one syscall. path is passed for adapters that answer from a sibling
metadata file instead.

nil beats a wrong guess when the filesystem cannot answer at all — and it says
so through ENOSYS/EPERM from statx as often as NotImplementedError.

### `updated_at_for(_path, stat)` <a id="method-i-updated_at_for"></a> <a id="updated_at_for-instance_method"></a>
Not documented.

### `verify()` <a id="method-i-verify"></a> <a id="verify-instance_method"></a>
Checks every declared store against disk. The design doc says each adapter
declares its own checks, and each one does: its store_configs decide what is
looked for and whether an absence is a failure or drift. Content-level checks
(first record type, encoding round-trip) need file reads and wait for Layer 3.
An adapter that needs its own can override this and call super.

The skip gate is the same signal Store#installed? uses: any declared store
exists. It is deliberately NOT base-dir existence — ~/.cursor is created by
the Cursor editor with no agent store in it (observed 2026-08-05), and the old
gate made doctor report FAIL while `where` said "(not installed)". A missing
store proves nothing on its own (never used? layout moved? the gem cannot
tell), so :fail is reserved for the one case with evidence: some store exists,
proving the agent records data here, while a required one is absent — the
layout-moved signature.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
Not documented.
