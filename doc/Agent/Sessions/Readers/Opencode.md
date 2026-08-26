# Class Agent::Sessions::Readers::Opencode <a id="class-Agent-Sessions-Readers-Opencode"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/opencode.rb |

opencode sessions, read from the shared SQLite database the adapter already
enumerates. Written against a real store on this machine (2026-08-24): 365
sessions, whose message and part rows settled every mapping below — this is
the first reader whose "corpus" is a database rather than files.

A "record" here is synthetic: one message row's parsed `data` plus every part
row belonging to it, as {"message" => ..., "parts" => [...]}. That composite
IS the raw a Message carries — rule 1 needs the parts included, because the
content lives in them, not in the message row.

## Constants
### `CONTENT_PARTS` <a id="constant-CONTENT_PARTS"></a> <a id="CONTENT_PARTS-constant"></a>
Conversation content. text and reasoning map 1:1; a `tool` part holds BOTH the
call and its result in one row (state.input / state.output), so it becomes two
Parts — the assistant's act and the tool answering —rather than flattening one
of them away.

### `STATE_PARTS` <a id="constant-STATE_PARTS"></a> <a id="STATE_PARTS-constant"></a>
State, not conversation, skipped in silence — the same judgement Claude's
session-state records get. Observed counts in the real store: step-start
4,391, step-finish 4,380 (consumed for usage below), patch 569 (files a step
touched), file 25 (attachments), agent 1, compaction 1 (surfaced through
`compactions`, not as a message).

## Public Instance Methods
### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Session totals, summed per message. No dedup is needed: one row is one API
response, and the sum was verified against the store's own per-session rollup
columns — 9,727,437 input / 94,266 output / 22,184,157 cache-read, exactly
equal both ways on the real store.
