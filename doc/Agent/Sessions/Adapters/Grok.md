# Class Agent::Sessions::Adapters::Grok <a id="class-Agent-Sessions-Adapters-Grok"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/grok.rb |

Grok Build (xAI). PROVISIONAL: ~/.grok does not exist on the machine this was
written on (2026-08-24), so every claim follows tokentelemetry's working
parser of the same store (resources/tokentelemetry, _scan_grok_sessions and
_grok_usage_from_unified_log) rather than observation.

A Grok session is a DIRECTORY, not a file:
    ~/.grok/sessions/<url-encoded cwd>/<session-uuid>/
      summary.json  chat_history.jsonl  events.jsonl  updates.jsonl
      signals.json  plan_mode.json  subagents/<spawn-id>/meta.json

summary.json is what this adapter enumerates, because it is the record that
always exists and carries the session's own metadata. The transcript beside it
is what the reader reads, and `bytes` counts the whole directory — the same
choice Claude's adapter makes for its sidecar tree, and for the same reason:
those bytes belong to this session, and a `du` that ignored them would
disagree with the disk.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `bytes_for(path, stat)` <a id="method-i-bytes_for"></a> <a id="bytes_for-instance_method"></a>
The whole session directory, not just summary.json: the transcript and every
sibling log live in it.

### `decode_project(name)` <a id="method-i-decode_project"></a> <a id="decode_project-instance_method"></a>
Not documented.

### `encode_project(dir)` <a id="method-i-encode_project"></a> <a id="encode_project-instance_method"></a>
Not documented.

### `project_dir_name(path)` <a id="method-i-project_dir_name"></a> <a id="project_dir_name-instance_method"></a>
Not documented.

### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
The project bucket is a URL-encoded absolute path (tokentelemetry unquotes
it), so unlike Claude's and pi's dash encodings this one is losslessly
reversible. summary.json's own info.cwd is preferred where readable, because a
recorded path beats a decoded directory name; the decode is the fallback, and
a good one.

### `session_id_from(path)` <a id="method-i-session_id_from"></a> <a id="session_id_from-instance_method"></a>
<sessions>/<url-encoded cwd>/<session-uuid>/summary.json — the id is the
directory holding the file, not the file's own basename, which is the constant
"summary".

### `started_at_for(path, stat)` <a id="method-i-started_at_for"></a> <a id="started_at_for-instance_method"></a>
summary.json carries the session's own clock; the file's mtime is only ever a
proxy for it. Both are ISO 8601 strings per the reference parser, with
created_at standing in when updated_at is absent.

### `updated_at_for(path, stat)` <a id="method-i-updated_at_for"></a> <a id="updated_at_for-instance_method"></a>
Not documented.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
Not documented.
