# Class Agent::Sessions::Readers::Codex <a id="class-Agent-Sessions-Readers-Codex"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/codex.rb |

Codex rollout files. Every mapping here was written against a real corpus
rather than from the format notes: 415 files, 128,987 records, inventoried
2026-08-12. The distribution is the reason for several decisions below
—response_item 57%, event_msg 38%, turn_context 4%, session_meta 416,
world_state 182, inter_agent_communication_metadata 129, compacted 18.

Codex was chosen as the first reader for exactly this reason. pi was the
planned reference implementation, but its store held no session files at all
on the machine available, so every claim about its content would have been
inference. A reference implementation has to be falsifiable.

## Constants
### `CALL_INPUTS` <a id="constant-CALL_INPUTS"></a> <a id="CALL_INPUTS-constant"></a>
Where a tool call keeps what it was called with. custom_tool_call uses input,
function_call uses arguments, web_search_call uses action, and
tool_search_call uses arguments as a Hash rather than a String.

### `CALL_OUTPUTS` <a id="constant-CALL_OUTPUTS"></a> <a id="CALL_OUTPUTS-constant"></a>
And where an output keeps its result.

### `CONTENT_PARTS` <a id="constant-CONTENT_PARTS"></a> <a id="CONTENT_PARTS-constant"></a>
encrypted_content maps to :unknown deliberately, not for want of a better
bucket: 80 real content items are encrypted by the model and this gem will
never read them. Recognized-and-unreadable is a different thing from
unrecognized, and only the second deserves a warning — a warning that fires on
a permanent, understood condition is noise on every read.

### `NON_MESSAGE_ITEMS` <a id="constant-NON_MESSAGE_ITEMS"></a> <a id="NON_MESSAGE_ITEMS-constant"></a>
Internal state that happens to travel as a response_item. Skipped in silence
for the same reason turn_context is: it is not conversation, and a warning a
caller must learn to ignore is worse than no warning.

### `NON_MESSAGE_TYPES` <a id="constant-NON_MESSAGE_TYPES"></a> <a id="NON_MESSAGE_TYPES-constant"></a>
Known, and deliberately not messages: the session header, per-turn
configuration, and two state records Codex added in July 2026. Silence here is
a judgement, not an oversight — these are not conversation, and warning about
them would train a caller to ignore warnings.

### `ROLES` <a id="constant-ROLES"></a> <a id="ROLES-constant"></a>
"developer" is what Codex writes where the normalized vocabulary says :system.
It is 101 of 292 role-bearing records in the sample, so this is the common
path, not an edge case.

### `TOOL_CALLS` <a id="constant-TOOL_CALLS"></a> <a id="TOOL_CALLS-constant"></a>
Every entry past the first three in each list came from running this reader
over all 415 files and reading its own warnings: a 25-file sample showed none
of them. Counts in that corpus: web_search_call 288, ghost_snapshot 197,
agent_message 129, tool_search_call and tool_search_output 26 each,
image_generation_call 1.

### `TOOL_OUTPUTS` <a id="constant-TOOL_OUTPUTS"></a> <a id="TOOL_OUTPUTS-constant"></a>
Not documented.

## Public Instance Methods
### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Session totals. Codex writes no usage on its messages; it writes token_count
event records whose info.total_token_usage is a RUNNING TOTAL — verified
against a real rollout on this machine (2026-08-24): consecutive records
report total 33,751 then 69,135 while their last_token_usage differ, so the
last record is the session and summing would multiply-count every earlier
turn.

Two normalizations, both from that same file:

    input_tokens INCLUDES cached_input_tokens (33,431 including 19,200
    in the sample) — the opposite of Claude's disjoint spelling — so the
    cached share is subtracted to make Usage#input mean one thing across
    agents. Clamped at zero: a count that went negative would mean the
    two fields disagree, and a wrong zero beats a negative token count.

    cache_write_input_tokens maps to cache_creation. total_tokens is
    deliberately not mapped anywhere: it restates the other fields, and
    any bucket it landed in would be double-counted by a caller summing
    buckets.
