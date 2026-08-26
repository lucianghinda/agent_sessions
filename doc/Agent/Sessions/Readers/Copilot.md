# Class Agent::Sessions::Readers::Copilot <a id="class-Agent-Sessions-Readers-Copilot"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/copilot.rb |

GitHub Copilot CLI turns, from the SQLite store the adapter enumerates.

The SCHEMA is verified (schema_version 3 on this machine, 2026-08-24): turns
holds id, session_id, turn_index, user_message, assistant_response, timestamp.
The CONTENT is not — the one real session here has zero turn rows, so no turn
has ever been read. The column names are unambiguous enough to map without
guessing at structure, which is why this reader exists at all rather than
waiting; what it cannot promise is that a real turn holds plain text in those
columns rather than, say, JSON.

fidelity is :messages, not :full — one row is a whole exchange, so the tool
calls and reasoning that happened inside it are not recoverable from this
table. What a caller gets is what was said, not how.

## Public Instance Methods
### `each_message()` <a id="method-i-each_message"></a> <a id="each_message-instance_method"></a>
One row is a user turn AND the assistant's reply, so each row yields two
messages. They share a raw record: rule 1 keeps the row intact, and splitting
it into two half-rows would misreport what was stored.

### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
No token or cost column exists anywhere in this schema — not on sessions, not
on turns. nil is the format speaking, and must not be mistaken for a session
that cost nothing.
