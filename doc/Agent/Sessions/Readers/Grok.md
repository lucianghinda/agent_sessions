# Class Agent::Sessions::Readers::Grok <a id="class-Agent-Sessions-Readers-Grok"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/grok.rb |

Grok Build sessions. PROVISIONAL, like the adapter: written against
tokentelemetry's parser of this format, not against real Grok output.

Two things make this reader unlike every other one here. The session it is
handed points at summary.json, while the conversation is in chat_history.jsonl
beside it — so the streaming base reads a SIBLING file. And billed usage is
not in the session directory at all: it lives in ~/.grok/logs/unified.jsonl,
one row per request across every session, keyed by session id. A rotated log
means no usage, which is why `usage` answers nil rather than zero when the log
is gone.

## Constants
### `INFERENCE` <a id="constant-INFERENCE"></a> <a id="INFERENCE-constant"></a>
The row that records one completed request, per the reference parser.

### `ROLES` <a id="constant-ROLES"></a> <a id="ROLES-constant"></a>
Not documented.

### `TRANSCRIPT` <a id="constant-TRANSCRIPT"></a> <a id="TRANSCRIPT-constant"></a>
Not documented.

### `UNIFIED_LOG` <a id="constant-UNIFIED_LOG"></a> <a id="UNIFIED_LOG-constant"></a>
Not documented.

## Public Instance Methods
### `summary()` <a id="method-i-summary"></a> <a id="summary-instance_method"></a>
The session's summary.json, exposed because it holds what Layer 2 does not
surface: generated_title, session_summary, current_model_id, the git branch
and commit the work happened on.

### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Summed across this session's rows in the shared inference log.

prompt_tokens INCLUDES cached_prompt_tokens (the reference parser subtracts
one from the other, as this gem does for Codex and Gemini), so `input` is the
difference and `cache_read` the cached share. The cached count is clamped to
the prompt first: a log row claiming more cached than prompt would otherwise
produce a negative input.
