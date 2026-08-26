# Class Agent::Sessions::Readers::Gemini <a id="class-Agent-Sessions-Readers-Gemini"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/gemini.rb |

Gemini CLI chat files. Written against a real store on this machine
(2026-08-24): 12 sessions, 121 records — user 20, gemini 97, info 4.

A chat is one JSON document, not JSONL, so it is read whole under a cap the
way Amp's thread is. The cap is the reason this does not simply JSON.parse the
file: the largest real chat here is 103 KB, but nothing in the format bounds
it, and an unbounded read is the failure the base reader's chunked streaming
exists to prevent.

## Constants
### `MAX_DOCUMENT_BYTES` <a id="constant-MAX_DOCUMENT_BYTES"></a> <a id="MAX_DOCUMENT_BYTES-constant"></a>
Amp's bound, for the same reason: a whole document must fit in memory to be
parsed at all, so the only protection available is refusing to read one that
is absurdly large.

### `ROLES` <a id="constant-ROLES"></a> <a id="ROLES-constant"></a>
"gemini" is the assistant. "info" is the CLI talking to the user ("Update
successful! The new version will be used on your next run."), which is neither
turn — context the operator saw, the same judgement Claude's system records
get, so it arrives with include_events.

## Public Instance Methods
### `header()` <a id="method-i-header"></a> <a id="header-instance_method"></a>
The document's own header, exposed because Layer 2's session id is the
filename (the trailing hex in it is shared between sessions) while the agent's
own sessionId lives in here.

### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Session totals, summed per message — the counts are per API call, not a
running total (verified: the real series falls as well as rises, 64138 then
8069 then 8265, which no cumulative counter does).
