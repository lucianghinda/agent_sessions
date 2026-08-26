# Class Agent::Sessions::Adapters::Opencode <a id="class-Agent-Sessions-Adapters-Opencode"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/opencode.rb |

## Constants
### `DATABASE_GLOB` <a id="constant-DATABASE_GLOB"></a> <a id="DATABASE_GLOB-constant"></a>
opencode names its database per release channel — opencode.db,
opencode-stable.db — so the filename is a glob, not a constant (tokentelemetry
globs the same pattern). Unverified here: this machine has only the plain
name.

### `SESSION_COLUMNS` <a id="constant-SESSION_COLUMNS"></a> <a id="SESSION_COLUMNS-constant"></a>
Not documented.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `base_dir()` <a id="method-i-base_dir"></a> <a id="base_dir-instance_method"></a>
The declared default stands unless another candidate actually holds a
database. Falling back to it rather than to the first candidate that merely
exists keeps `where` printing a concrete, conventional path on a machine with
no opencode at all.

### `project_paths()` <a id="method-i-project_paths"></a> <a id="project_paths-instance_method"></a>
ORDER BY matches the sorted order Base guarantees, so `projects` output is
stable and diffable whichever adapter answers it. is_a?(String) excludes a row
whose directory is NULL (build_db_session's guard, same rule 2 container
check) rather than letting a literal nil sort in among real paths — "excluded,
not nil", matching Base's project_paths docstring. .uniq is needed on top of
SQL's own DISTINCT: SQLite's DISTINCT treats a BLOB and a byte-identical TEXT
value as different rows (confirmed directly — typeof reports "text" vs "blob"
for the same bytes even though the sqlite3 gem returns both to Ruby as String,
see build_db_session's comment), so without this a blob/text pair with
identical bytes would surface as two entries where Base's own
<code>.uniq.sort</code> would collapse them to one.

### `sessions()` <a id="method-i-sessions"></a> <a id="sessions-instance_method"></a>
Sessions are rows, not files, so the Base glob enumeration is replaced by a
deferred query: it runs at first consumption, and only if the database exists.
The existence check comes FIRST so machines without opencode never need
sqlite3 at all (design doc section 9).

Row order is deliberately unspecified: no ORDER BY, so rows arrive in whatever
order SQLite's own scan produces (rowid order, absent an index that would
change it) — unlike the other six adapters, which are path-sorted for free by
Dir.glob. Invisible today because nothing here sorts before Task 10 does its
own sort_by(&:updated_at); stated so a future caller of THIS method directly
does not come to depend on insertion order looking stable.

The gap between this check and the open below is a real TOCTOU window
—opencode could delete or migrate the file in between — but the open that
follows a vanished file raises SQLite3::CantOpenException (verified directly),
which each_session_row already turns into UnreadableStore. That is judged the
right answer, not a bug to special-case: unlike Base's own glob-then-stat race
(one file silently missing from a multi-file listing, so build_session's
rescue drops it and moves on), a vanished DATABASE is the store's only source
for every session, so there is nothing partial to return — "the store I just
confirmed exists is now unreadable" is what happened, and UnreadableStore says
exactly that.

Opens once per consumption, not once per instance: `sessions`,
`sessions_for_project` and `project_paths` each open, query and close their
own connection through each_session_row. That costs an extra open when a
caller uses more than one of the three, but keeps every method independently
correct rather than threading a shared handle through them — and
Enumerator.new's block does not even run until the RETURNED lazy enumerator is
consumed, so a caller that builds `sessions` and never touches it opens
nothing at all. Confirmed empirically (not just assumed from Enumerator's
docs) that the `ensure db&.close` inside each_session_row fires promptly
either way a caller can stop early —`.lazy.first(n)` and an external `each {
break }` both unwind the generator fiber immediately, before the outer call
returns — so a caller taking <code>sessions.first</code> never leaves a
connection open waiting for GC to reclaim the fiber.

### `sessions_for_project(dir)` <a id="method-i-sessions_for_project"></a> <a id="sessions_for_project-instance_method"></a>
The directory column holds the full recorded path, so filtering is a WHERE
clause instead of the Base read-and-compare loop.

### `verify()` <a id="method-i-verify"></a> <a id="verify-instance_method"></a>
Base checks the declared path literally, which gets a machine holding only a
channel-named database wrong twice: its "is this agent installed" gate sees no
declared layer and skips the store checks entirely, and the store check itself
would report :fail on a real store that is merely called something the
declaration did not predict.

Any file matching the glob satisfies the claim. The detail names what was
actually found, so a non-canonical filename is visible rather than merely
tolerated — the same reason detail_for prints a file count.
