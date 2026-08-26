# Class Agent::Sessions::Adapters::Pi <a id="class-Agent-Sessions-Adapters-Pi"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/pi.rb |

## Constants
### `FILENAME` <a id="constant-FILENAME"></a> <a id="FILENAME-constant"></a>
FILENAME's h{8} id specifically contradicts the one written source available:
design doc section 8.6 says pi's **entries** carry an 8-character hex id,
while the section 8 table gives the filename itself as <timestamp>_<uuid>.
Both cannot be right, and nothing on this machine can settle which one pi's
own encoder does. h{8} is what is implemented here; if a real file uses a full
uuid instead, this regex simply never matches it, and session_id_from below
falls back to the basename — a real but visibly non-canonical id, not a crash.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
The reader shares this adapter's provisional standing: written against
tokentelemetry's parser of the same format, since this machine's pi store
holds no session files to observe. Its own header comment says what remains
unverified.

## Public Instance Methods
### `encode_project(dir)` <a id="method-i-encode_project"></a> <a id="encode_project-instance_method"></a>
Verified against nine real pi project directories found on this machine on
2026-08-05 (~/.pi/agent/sessions/--*--, empty of .jsonl but real encoder
output regardless — see the class comment above) — see
test_encode_project_round_trips_the_nine_real_pi_directories in
test/pi_adapter_test.rb. Design doc section 7 described this only as "wrap the
dashed cwd in double dashes," ambiguous on two points neither of us had
settled by observation. Both are now settled by real output rather than by
carrying Claude's rule over into pi's:

    1. The dash count. Read literally — dash-encode the WHOLE cwd,
       including its leading "/", then wrap that in "--" — an
       absolute path would get THREE leading dashes. Real pi output
       has TWO: the leading "/" is absorbed into the wrap rather than
       separately encoded, matching the store's own "--*--/*.jsonl"
       glob (above).

    2. The character class. This used to read like Claude's "every
       non-alphanumeric character becomes -" and that was WRONG: pi
       preserves dots. Two of the nine real directories contain a
       literal "." (a domain name in the path) unchanged, while the
       "/" separators around it became "-". Claude has 45 project
       directories on this same machine and not one contains a dot —
       the two adapters' rules genuinely differ; they do not merely
       happen to agree on every example seen before now.

What remains a guess: "_", spaces, and any other non-"/" separator never
appear in the nine real directories, so nothing here confirms whether pi
encodes them or preserves them too, the way it preserves ".". Do not widen
this gsub back into a character class without new evidence — that is exactly
the mistake being corrected here.

This directory-name encoding is what sessions_for_project falls back to when a
session's own header cwd cannot be read (see Base#encode_project) — pi's whole
safety net for project_path_for's still-unverified "cwd" header key
assumption. That fallback is now solid: a wrong "cwd" key degrades to accurate
name matching instead of two guesses compounding into silent failure.

Expects an absolute, expanded path; sessions_for_project expands first.

### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
pi publishes its format: one header line, then typed entries (design doc 8.6)
— which argues for staying TIGHTER than Claude's 25, whose cwd genuinely was
not on line 1 and whose format was never published. But "publishes a spec" is
not the same evidence as "measured against a real file," and this machine has
zero pi sessions to measure against. limit: 25 matches Claude's number not
because pi is assumed to behave like Claude, but because scan_jsonl_for_key
returns as soon as it finds a usable record: the width costs nothing while the
line-1 assumption holds, and is only ever paid on the one case this file
cannot rule out — a preamble pi does not document, the same way Claude's
kebab-case preamble was not documented either. The one real cost of going
wide: the predicate below is type-checked but not otherwise selective, so a
longer window is more exposure to a later, unrelated record that happens to
carry a String "cwd" of its own — a decoy shadowing pi's real one —a risk this
file cannot bound without a real session to look at.

The predicate is mandatory, not decoration. scan_jsonl_for_key stops at the
first record merely CARRYING the key, so without a value guard a record
holding "cwd": null shadows a later usable one permanently, and a non-String
cwd reaches project_paths' .uniq.sort and raises.

### `session_id_from(path)` <a id="method-i-session_id_from"></a> <a id="session_id_from-instance_method"></a>
Not documented.

### `started_at_for(path, stat)` <a id="method-i-started_at_for"></a> <a id="started_at_for-instance_method"></a>
The rescue is not optional. d{2} accepts 00-99, and Time.new raises
ArgumentError on month 13, minute 60 and friends. build_session scopes its own
rescue to File.stat so that a raising hook surfaces as the adapter bug it
usually is — but this hook raises on FILE DATA, and without the rescue one
malformed filename returns zero sessions from `sessions`, `project_paths` and
`for_project` alike, and exits the CLI with a raw backtrace that takes every
other agent's rows with it. That failure mode was measured in Task 4, against
Codex — pi has no real filenames of its own to reproduce it against, but the
mechanism (Time.new rejecting digits d{2} happily accepted) belongs to Ruby,
not to any one adapter's data, so the same rescue applies here.

Local, not UTC: copied from Codex's VERIFIED behaviour (its rollout filenames
use the local clock, confirmed against 360 real files). pi's is UNVERIFIED —
no real pi filename exists on this machine to check it against. If pi instead
publishes UTC filenames, every pi started_at is silently off by the machine's
UTC offset, with no signal that it happened. The test fixture's header
timestamp and filename timestamp deliberately disagree (see build_fixture in
test/pi_adapter_test.rb) so that a started_at_for which quietly fell back to
reading the header would be caught returning the wrong hour, rather than
passing by coincidence on a UTC machine.

The rescue wraps Time.new alone rather than the whole method. A method-scoped
rescue would also swallow an ArgumentError from a future signature change —
the commonest Ruby programming error — and silently fall back to
stat.birthtime for every pi session: a plausible-looking wrong started_at with
no signal, which is worse than a crash.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
pi's *session files* are still absent from this machine: all nine directories
under ~/.pi/agent/sessions (real pi output — see encode_project below) are
empty of .jsonl (2026-08-05). Everything about a session's CONTENT is
therefore still inference from design doc 8.6, not observation: the header's
"cwd" key (project_path_for below), which line it is on (the limit: argument
there), and whether a session's id segment is 8 hex characters or a full uuid
(FILENAME below). `warnings` below repeats the gist where a CLI user will
actually see it, gated on the store existing.

The directory NAMING scheme is a different story: it is real pi output, not a
guess — see encode_project's comment.

To check the remaining unverified points against a real session:
    head -1 ~/.pi/agent/sessions/--*--/*.jsonl

and look for: which key actually holds the cwd (assumed "cwd"), which line it
is on (assumed line 1), and whether the id segment is 8 hex characters or a
full uuid (assumed 8 hex). A mismatch means fixing the matching line below and
the warning above it, not just the comment next to it.
