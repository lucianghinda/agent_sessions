# Class Agent::Sessions::Adapters::Codex <a id="class-Agent-Sessions-Adapters-Codex"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/codex.rb |

## Constants
### `FILENAME` <a id="constant-FILENAME"></a> <a id="FILENAME-constant"></a>
rollout-<YYYY-MM-DDTHH-MM-SS>-<uuid>.jsonl (verified 2026-08-05 against 360
real session files on this machine — every one matched). The timestamp uses
the local clock and dashes where ISO 8601 has colons. started_at_for's comment
says what "local" costs elsewhere. The uuid group is pinned to its actual
shape (8-4-4-4-12 hex), not (.+): greedy against .jsonlz, (.+) would swallow a
sync tool's or backup's " (conflicted copy)" suffix into what looks like a
canonical id rather than falling back to the basename, where such a copy is at
least visibly non-canonical.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
Line 1 is session_meta; the cwd lives in its payload (design doc section 6 and
8.2, verified 2026-08-05 — 360/360 real files carry a usable
session_meta/payload/cwd on line 1). limit: 3 is slack against that guarantee,
not a fit to any observed multi-line case: it tolerates a truncated or blank
first line without paying for an unbounded scan. "3" counts iterations of
File.foreach(path, "n", MAX_LINE_BYTES), not lines: a >1MB record is chunked
and each chunk is one iteration, so this is really 3MB of read headroom, not
"3 records." A future adapter copying this pattern with limit: 1 would lose
that tolerance entirely.

The predicate requires more than scan_jsonl_for_key's key-presence check can:
real sessions on this machine also carry a "payload" key on later,
non-session_meta records (turn_context observed 2026-08-05) whose payload
itself carries "cwd" — a presence-only scan would stop at whichever comes
first, right only by coincidence. Requiring type == "session_meta" pins the
read to the one documented source of truth (design doc 8.2), and requiring a
Hash payload with a String cwd stops a malformed record (payload not a Hash,
or cwd not a String) from permanently shadowing a later, usable session_meta
or reaching project_paths' .uniq.sort with the wrong type.

### `session_id_from(path)` <a id="method-i-session_id_from"></a> <a id="session_id_from-instance_method"></a>
Not documented.

### `sessions()` <a id="method-i-sessions"></a> <a id="sessions-instance_method"></a>
Codex writes rollout files to two stores, and Base enumerates only the primary
one. An archived session is still a session — a real one was found outside the
sessions/ glob on 2026-08-10 — and a session the gem does not report is the
silent under-reporting this design treats as its worst failure mode. Every
filename hook below applies unchanged: the archived files carry the same
rollout-<timestamp>-<uuid>.jsonl name.

`super` first, so the guard it raises when the primary store has no known
layout still fires, and so live sessions come out before archived ones.
Chained rather than concatenated to keep the result lazy: a caller taking
first(n) must not stat an archived file it never asked about.

### `started_at_for(path, stat)` <a id="method-i-started_at_for"></a> <a id="started_at_for-instance_method"></a>
The digit groups accept 00-99 each, which Time.new does not: month 13, minute
60, and similar out-of-range values raise ArgumentError rather than being
normalized. That is file DATA, not an adapter bug, so it must not cross the
line build_session draws between the two (a raising hook is meant to surface
as a programming error) — one such filename among many good ones would
otherwise take sessions, project_paths, and sessions_for_project down to zero
for every agent, not just Codex.

Local, not UTC: session_meta's own "timestamp" field is UTC and agrees with
this to within 1s across all 360 real files here, but a machine whose TZ
changed, or a store copied from another machine, would make this off by the
offset delta while Claude's birthtime-based started_at stays an absolute
instant. Harmless today because Task 10 sorts sessions by updated_at, not
started_at. The rescue wraps Time.new alone rather than the whole method. A
method-scoped rescue would also swallow an ArgumentError from a future
signature change — the commonest Ruby programming error — and silently return
birthtime for every Codex session: a plausible-looking wrong started_at with
no signal, which is worse than a crash.
