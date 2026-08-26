# Class Agent::Sessions::Adapters::Claude <a id="class-Agent-Sessions-Adapters-Claude"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/claude.rb |

## Constants
### `DEFAULT_CLEANUP_PERIOD_DAYS` <a id="constant-DEFAULT_CLEANUP_PERIOD_DAYS"></a> <a id="DEFAULT_CLEANUP_PERIOD_DAYS-constant"></a>
Not documented.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `bytes_for(path, stat)` <a id="method-i-bytes_for"></a> <a id="bytes_for-instance_method"></a>
Claude Code writes a directory beside each transcript, named after the session
id with the extension dropped: subagents/ holds the transcripts of agents this
session spawned, tool-results/ holds tool output too large to inline. Those
bytes are this session's, and until they were counted `du` reported 122.1 MB
for a store `audit` reported 173.0 MB for — 71% — because audit sums the store
directory whole while du sums sessions. Two commands, one directory, a 29%
disagreement.

Measured over 128 real sessions on 2026-08-10: 0.002 ms per session when there
is no sidecar (one stat, the common case on a fresh install) and 0.080 ms when
there is. That is under half what project_path's content read costs, and
unlike project_path this cannot be deferred —bytes is eager, and a
lazily-corrected byte total would leave `list` printing one number while `du`
summed another.

### `encode_project(dir)` <a id="method-i-encode_project"></a> <a id="encode_project-instance_method"></a>
Every non-alphanumeric character becomes "-" (design doc section 7). dir must
already be absolute and expanded — sessions_for_project guarantees that; a
direct caller passing "app", "~/app", or a trailing slash gets a nonsense
encoding (see Base#encode_project). Verified against real project directories
on 2026-08-05: /Users/dev/.local -> -Users-dev--local

### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
cwd is NOT on line 1. Real sessions open with a kebab-case preamble (ai-title,
agent-name, mode, permission-mode) followed by a variable-length run of
file-history-snapshot records — that run is what pushes the first cwd-bearing
record out further on some files, and nothing bounds its length. Observed on
this machine on 2026-08-05: line 3 (19 files), line 4 (48 files), line 9 (1
file, a longer snapshot run). limit: 25 is ~2.8x that observed maximum —
headroom for the variable-length run, not a tight fit to the common case — and
keeps this a few-KB read even on multi-GB files.

The block guards against a record that carries "cwd" but not usably: null
shadows a later valid record, and a wrong type (Integer, Hash) would otherwise
reach project_paths' .uniq.sort and raise there. scan_jsonl_for_key already
guarantees the key is present once the block accepts, so a plain fetch (no
default) is safe.

### `retention()` <a id="method-i-retention"></a> <a id="retention-instance_method"></a>
Not documented.

### `retention_source()` <a id="method-i-retention_source"></a> <a id="retention_source-instance_method"></a>
Not documented.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
Not documented.
