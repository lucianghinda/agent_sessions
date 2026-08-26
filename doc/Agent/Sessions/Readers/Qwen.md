# Class Agent::Sessions::Readers::Qwen <a id="class-Agent-Sessions-Readers-Qwen"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/qwen.rb |

Qwen Code chat files. PROVISIONAL, like the adapter: written against
tokentelemetry's parser of this format, not against real Qwen output.

The record shape is Anthropic's — type user/assistant, message.content as an
array of typed parts, message.usage with the same five spellings Claude uses.
This is deliberately NOT a subclass of Readers::Claude despite that overlap:
Claude's reader also carries Claude Code's sidecar machinery (spilled tool
output, subagent transcripts, uuid/parentUuid branching), none of which is
known to exist here, and inheriting would mean disabling each one and then
re-checking every future Claude change against an agent nobody can test. Two
readers with two evidence bases will drift honestly; one reader pretending to
serve both will drift silently.

## Constants
### `CONTENT_PARTS` <a id="constant-CONTENT_PARTS"></a> <a id="CONTENT_PARTS-constant"></a>
Not documented.

## Public Instance Methods
### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Session totals, deduplicated by message.id the way Claude's are: the same API
response can stream into one record per content block, and both agents speak
the same wire format. Unverified for Qwen — if its writer does not repeat ids,
this dedup is simply a no-op.
