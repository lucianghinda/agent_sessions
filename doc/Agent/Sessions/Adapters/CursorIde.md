# Class Agent::Sessions::Adapters::CursorIde <a id="class-Agent-Sessions-Adapters-CursorIde"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/cursor_ide.rb |

Cursor's IDE agent (Composer). Repointed 2026-08-24 at the store the 0.2
adapter's own warning named as the real one, now that it has been opened
rather than inferred: ~/Library/Application Support/Cursor/User/
globalStorage/state.vscdb, table cursorDiskKV, keys composerData:<uuid> — 6
real rows on the machine this was written on. The 0.2 declaration
(~/.cursor/projects/<strong>/agent-transcripts/</strong>) does not exist there
at all, so this adapter reported nothing for an agent that had sessions.

What is verified: the file, the table, the key prefix, and the record's own
composerId/createdAt. What is NOT: anything about the conversation itself —
all six records on this machine carry "conversation": [], so the shape of a
turn has never been seen here. fidelity stays :metadata and no reader exists,
which is the honest report: this adapter can say a session happened and when,
and must not pretend to say what was said.

## Constants
### `KEY_PREFIX` <a id="constant-KEY_PREFIX"></a> <a id="KEY_PREFIX-constant"></a>
Not documented.

## Public Instance Methods
### `project_path_for(_path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
Cursor's composer records do not name a project. context.fileSelections holds
paths of files ATTACHED to a turn — on this machine, a settings file from an
unrelated directory — and a workspace root inferred from one attachment would
be a guess dressed as a fact. nil is the honest answer, and `projects`
reporting nothing for this agent is correct rather than empty-looking.

### `project_paths()` <a id="method-i-project_paths"></a> <a id="project_paths-instance_method"></a>
Not documented.

### `sessions()` <a id="method-i-sessions"></a> <a id="sessions-instance_method"></a>
Rows, not files, so Base's glob enumeration is replaced the way opencode's is
— including the existence check FIRST, so a machine without Cursor never needs
the sqlite3 gem at all.

value is parsed for createdAt alone. It is the whole composer document
(context, capabilities, code blocks), which is why `bytes` stays nil: a row in
a shared database has no file size of its own, and the database's size belongs
to all 7 rows together.

### `sessions_for_project(_dir)` <a id="method-i-sessions_for_project"></a> <a id="sessions_for_project-instance_method"></a>
Not documented.
