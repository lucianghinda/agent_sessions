# Class Agent::Sessions::Adapters::Cursor <a id="class-Agent-Sessions-Adapters-Cursor"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/cursor.rb |

## Public Instance Methods
### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
cwd's presence in meta.json is not enough on its own (rule 1): the key can
hold a Hash, an Integer, anything JSON allows, and project_paths' .uniq.sort
raises on a non-String member. is_a?(String) is the guard, not merely a style
preference.

### `session_id_from(path)` <a id="method-i-session_id_from"></a> <a id="session_id_from-instance_method"></a>
chats/<chat-id>/<uuid>/store.db — two nested ids (design doc 16 Q5), so the
session id keeps both. The blob store is never opened here; the sibling
meta.json is the metadata source (8.3), with stat as fallback.

Pure string manipulation on `path` — File.basename/File.dirname never raise
for any String input, so this hook cannot violate rule 3 (build_session lets a
raising hook propagate) regardless of shape. A path shallower than two
segments is not reachable through this store's OWN enumeration: the glob above
is "<strong>/</strong>/store.db", and Dir.glob's "*" never crosses a "/", so
every path this adapter actually enumerates is exactly two directories deep,
by construction, not by convention (see
test_session_id_from_does_not_raise_for_a_shallow_path, which calls this hook
directly to pin the behaviour for a caller that bypasses the glob).

### `started_at_for(path, stat)` <a id="method-i-started_at_for"></a> <a id="started_at_for-instance_method"></a>
Not documented.

### `updated_at_for(path, stat)` <a id="method-i-updated_at_for"></a> <a id="updated_at_for-instance_method"></a>
Not documented.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
meta.json's field names (createdAtMs, updatedAtMs, cwd) are read from design
doc 8.3, itself written from a machine that had them to check against — this
machine has no ~/.cursor/chats (Cursor CLI is a separate product from the
Cursor editor and is simply not installed here). Gated, the same shape as pi's
identical warning about its own unverified header key and cursor_ide's about
its real session location below: a "here is what breaks, please act on it"
report reaches only someone whose declared store actually exists.

Why THIS unverified assumption specifically needs a warning, where some others
might get away without one: the failure is silent and looks correct. If
createdAtMs/updatedAtMs are the wrong keys, meta_time returns nil and
started_at_for/updated_at_for fall back to stat.birthtime/mtime — real file
timestamps, not an obviously broken value. If cwd is the wrong key,
project_path_for returns nil exactly the way it correctly does for a chat that
genuinely has no recorded cwd. Nothing in the output distinguishes "Cursor
recorded no project" from "the gem read the wrong key" — `projects`, `du --by
project`, and `sessions_for_project` all silently under-report Cursor, with no
error and no implausible-looking number anywhere to notice.
