# Class Agent::Sessions::Readers::Amp <a id="class-Agent-Sessions-Readers-Amp"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/amp.rb |

Amp threads. Written against the one real thread available (2026-08-14): 24
messages, content parts tool_use 14, tool_result 14, text 2, thinking 1. One
thread is thin evidence beside Codex's 415 files, and this reader says so
through partial? rather than pretending otherwise.

Two things make Amp unlike the JSONL readers:

A thread is ONE JSON document, so it cannot be streamed a record at a time.
Reading any of it means holding all of it, which is the gem's one unbounded
read (0.2 follow-up 8). each_record below is where that bound finally lives.

And its tool results are spelled its own way — toolUseID rather than
tool_use_id, the payload under run.result rather than content. A mapper copied
from Claude's would produce empty tool results and no warning, which is why
each reader maps its own agent rather than sharing one.

## Constants
### `CONTENT_PARTS` <a id="constant-CONTENT_PARTS"></a> <a id="CONTENT_PARTS-constant"></a>
Not documented.

### `MAX_DOCUMENT_BYTES` <a id="constant-MAX_DOCUMENT_BYTES"></a> <a id="MAX_DOCUMENT_BYTES-constant"></a>
150x the observed thread. A cap has to exist because nothing about a thread
file announces its size before it is opened, and JSON.parse of a 200 MB
document costs several times that in live objects. Refused and reported beats
NoMemoryError, and beats silence either way.

### `ROLES` <a id="constant-ROLES"></a> <a id="ROLES-constant"></a>
Not documented.

## Public Instance Methods
### `partial?()` <a id="method-i-partial-3F"></a> <a id="partial?-instance_method"></a>
The server holds the canonical copy; a local thread may be a mirror of part of
the conversation. The adapter carries the same warning.
- **@return** [Boolean]
