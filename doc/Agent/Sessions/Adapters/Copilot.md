# Class Agent::Sessions::Adapters::Copilot <a id="class-Agent-Sessions-Adapters-Copilot"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/copilot.rb |

GitHub Copilot CLI. Verified against a real store on this machine
(2026-08-24): ~/.copilot/session-store.db, schema_version 3, one session.

This store has MOVED since tokentelemetry's parser was written against it:
that reads ~/.copilot/session-state/<id>/events.jsonl, and no such file exists
here. The session-state/<id>/ directory does still exist as a companion
(workspace.yaml, checkpoints/, files/, research/), but the session record
itself is now a row in SQLite. An adapter following the older spec would
report nothing on a current install — the failure this gem's `verified_on`
dates exist to make visible.

## Constants
### `SESSION_COLUMNS` <a id="constant-SESSION_COLUMNS"></a> <a id="SESSION_COLUMNS-constant"></a>
created_at/updated_at are ISO 8601 strings here, not the epoch milliseconds
opencode and Cursor use — verified against a real row
("2026-05-26T04:36:01.288Z").

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `project_paths()` <a id="method-i-project_paths"></a> <a id="project_paths-instance_method"></a>
Not documented.

### `sessions()` <a id="method-i-sessions"></a> <a id="sessions-instance_method"></a>
Not documented.

### `sessions_for_project(dir)` <a id="method-i-sessions_for_project"></a> <a id="sessions_for_project-instance_method"></a>
cwd is a real column holding a real absolute path, so filtering is a WHERE
clause rather than a read-and-compare loop.
