# Class Agent::Sessions::Adapters::Gemini <a id="class-Agent-Sessions-Adapters-Gemini"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/gemini.rb |

Gemini CLI. Verified against a real store on this machine (2026-08-24): 9
project directories, 12 chat files, 121 records.

The store is keyed by an opaque project hash, not by an encoded path:
~/.gemini/tmp/<projectHash>/chats/session-<UTC stamp>-<hex8>.json, with a
sibling logs.json holding a flat prompt log. Nothing anywhere under the store
names a working directory — grepping every JSON file in it for cwd, workspace,
projectPath, rootPath and directory found zero — which is why project
resolution below depends on a separate map file rather than on decoding the
hash.

## Constants
### `FILENAME` <a id="constant-FILENAME"></a> <a id="FILENAME-constant"></a>
session-2025-11-29T20-08-b20947ab.json. The trailing hex is NOT a session id:
two files in the real store share d4abc9ce while being different sessions, so
the whole basename is the id — unique, stable, and derivable without opening
the file, which is what Layer 2 is for. The agent's own sessionId lives inside
the document and reaches a caller through the reader.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `encode_project(dir)` <a id="method-i-encode_project"></a> <a id="encode_project-instance_method"></a>
Not documented.

### `project_dir_name(path)` <a id="method-i-project_dir_name"></a> <a id="project_dir_name-instance_method"></a>
<base>/tmp/<projectHash>/chats/<file>.json — two levels up from the file, not
one, so Base's default (the immediate parent) would answer "chats" for every
session.

### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
The store groups sessions under a hash of the project directory that this gem
cannot reverse: it is not a plain SHA-256 of the path (tested directly against
real directories), and the store records the path nowhere else.
~/.gemini/projects.json is the map Gemini itself keeps —when it exists, this
reads it; when it does not, nil is the honest answer and `projects` reports
nothing rather than inventing a name from the hash.

### `project_paths()` <a id="method-i-project_paths"></a> <a id="project_paths-instance_method"></a>
Not documented.

### `started_at_for(path, stat)` <a id="method-i-started_at_for"></a> <a id="started_at_for-instance_method"></a>
UTC, unlike Codex and pi, whose rollout filenames use the local clock.
Verified rather than assumed: four real filenames match their own document's
startTime to the minute when read as UTC (12-42 against
2025-12-12T12:42:50.033Z), and would be three hours out as local time on the
machine this was written on.

Minute precision only — the document's startTime carries seconds, but reading
it would cost a parse per session, and Layer 2 is stat-only.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
The delta-log variant: tokentelemetry's parser of this same store handles
chats written as JSONL with a header line and `$set` deltas. No such file
exists here (zero .jsonl anywhere under the store), so this adapter reads the
verified .json spelling only — and says so where a user with the other
spelling will see it, rather than silently enumerating nothing for half their
sessions.
