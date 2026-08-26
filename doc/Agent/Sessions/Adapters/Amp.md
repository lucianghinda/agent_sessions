# Class Agent::Sessions::Adapters::Amp <a id="class-Agent-Sessions-Adapters-Amp"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/amp.rb |

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
env.initial.trees is the array a workspace's roots live in (plural —the format
is shaped for more than one). Verified 2026-08-05: the one real thread on this
machine carries exactly one tree, so `trees` is reported and an actual
multi-root thread's other roots are silently unreachable through
sessions_for_project/project_paths — see the warning below, which is where a
user who hits that finds out, since nobody who has looked at real data has hit
it yet. Reporting only the first is still the right call: Session#project_path
is a single String, not a list, so supporting every root would be a data-model
change this task does not make, and the failure mode is a false NEGATIVE (a
real root that never matches), never a false positive.

started_at deliberately does NOT read `created` from this same JSON: that
would turn every session's stat-only listing into a content read, not just
project_path's already-deferred one, breaking the stat-only guarantee
`sessions` makes for every adapter (Base's class comment on `sessions`) — and
it cannot be fixed by memoizing the parse across both hooks, either:
build_session computes started_at_for eagerly at construction and defers only
project_path through Session's resolver block, so a memo would always be cold
when started_at runs. The ordering never reverses without a Session/Base
change, which is out of scope here. Base's stat.birthtime fallback stays in
effect, nil-on-Linux limitation and all (see rule 3) — that gap is not
Amp-specific; Claude's started_at has the identical gap from the identical
fallback. Worth revisiting if a caller needs started_at at all on a filesystem
without birthtime; nothing today does (Task 10 sorts by updated_at, matching
Codex's own note on the same trade-off).

URI.parse, not `uri.delete_prefix("file://")`: the naive strip mishandles the
authority-component form <code>file://localhost/Users/...</code> (it would
leave a leading "localhost/" in the path), which URI.parse's #path strips
correctly by design. That fix is only net-positive once its own new failure
modes are covered, and a partial mirror's JSON is exactly the kind of data
that can be present-but-wrong at every step, not merely absent (rule 1, one
level up: the CONTAINER at each step needs checking, not just the leaf):
    - opaque form "file:relative/x" parses with scheme "file" but
      #path nil — decode_uri_component(nil) raises NoMethodError.
    - "file:", "file://", "file://localhost" all parse to path "" —
      truthy, so left unchecked it becomes an empty-string project
      instead of the unknown-project nil an empty path actually means.
    - "file://nas/share" (a real host, e.g. a network share) parses to
      path "/share" with host "nas" — a location this machine cannot
      read as a local directory, silently rejected here rather than
      reported as if it were one.
    - a trailing slash ("file:///Users/you/app/") survives decoding
      unchanged and would never equal a caller's expanded path.
    - an unescaped character (a literal space) makes URI.parse itself
      raise URI::InvalidURIError — file DATA, not an adapter bug, so
      that raise is rescued rather than left to propagate and take
      every agent's listing down with it (rule 2). The rescue is
      scoped to the URI.parse call alone, not the whole method: Codex
      and pi both wrap only Time.new the same way, for the same
      reason — a method-scoped rescue would just as readily swallow a
      raise from a genuine adapter bug above it. decode_uri_component
      needs no rescue of its own: it only ever substitutes /%\h\h/, and
      URI.parse has already rejected any malformed escape by the time
      its #path reaches that call (verified against %FF%FE, %C3%28,
      %80 — none raise).

Every JSON level below is unwrapped by hand and type-checked, rather than one
#dig("env", "initial", "trees", 0, "uri") call: #dig raises TypeError the
moment an intermediate value is present but not itself diggable (a String
"env", a top-level Array, "trees" holding a String instead of an Array...),
which is the same present-but-wrong risk as above, one level higher. Each
<code>[]</code>/<code>.first</code> below is only called once its receiver has
already been confirmed the right shape, so none of them can raise on their
own. uri.is_a?(String) is kept even though URI.parse's own rescue above would
also catch every non-String value JSON can produce here (Hash, Array, Integer,
Float, true, false, nil all raise URI::InvalidURIError when handed to
URI.parse, verified 2026-08-05) — the guard is not load-bearing against those
specific values today, but it keeps this method's contract with URI.parse
explicit rather than resting on an undocumented side effect of what that call
happens to do with the wrong type, and it matches every sibling adapter's
convention of checking a value's type before use.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
Gated, unlike the warning above. That one is a permanent property of the agent
and is worth reading before adopting the gem; this one is a "here is what
breaks, please send this back" report, and the plan's rule for those is that
they reach only people who can act on them. Same gate pi uses.
