# Class Agent::Sessions::Loop <a id="class-Agent-Sessions-Loop"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/loop.rb |

One session read as an agent loop: round trips, the tool calls paired across
them, who spoke at each step, and how the loop ended.

`recorded` is false for an empty session — nothing was recorded, and "absence
must never read as presence" is this gem's standing rule (RoundTrip carries
the same rule for one group).

`warnings` is the reader's warnings first, then this object's own, so the
order is deterministic regardless of what the reader happened to find.

## Constants
### `ENDINGS` <a id="constant-ENDINGS"></a> <a id="ENDINGS-constant"></a>
The exact sentence for each ending, so the Loop and whatever renders it say
the same words.

## Attributes
### `ending` [R] <a id="attribute-i-ending"></a> <a id="ending-instance_method"></a>
Returns the value of attribute ending
- **@return** [Object] the current value of ending

### `recorded` [R] <a id="attribute-i-recorded"></a> <a id="recorded-instance_method"></a>
Returns the value of attribute recorded
- **@return** [Object] the current value of recorded

### `round_trips` [R] <a id="attribute-i-round_trips"></a> <a id="round_trips-instance_method"></a>
Returns the value of attribute round_trips
- **@return** [Object] the current value of round_trips

### `session` [R] <a id="attribute-i-session"></a> <a id="session-instance_method"></a>
Returns the value of attribute session
- **@return** [Object] the current value of session

### `speakers` [R] <a id="attribute-i-speakers"></a> <a id="speakers-instance_method"></a>
Returns the value of attribute speakers
- **@return** [Object] the current value of speakers

### `tool_calls` [R] <a id="attribute-i-tool_calls"></a> <a id="tool_calls-instance_method"></a>
Returns the value of attribute tool_calls
- **@return** [Object] the current value of tool_calls

### `warnings` [R] <a id="attribute-i-warnings"></a> <a id="warnings-instance_method"></a>
Returns the value of attribute warnings
- **@return** [Object] the current value of warnings

## Public Class Methods
### `for(reader)` <a id="method-c-for"></a> <a id="for-class_method"></a>
Reads the WHOLE session and says so by returning one built object rather than
streaming — it cannot stream, because a tool result can arrive many records
after the call it answers, and a streaming pass cannot look forward to find
it. Readers::Base#tree carries the same shape of honesty for the same reason.

## Public Instance Methods
### `ending_detail()` <a id="method-i-ending_detail"></a> <a id="ending_detail-instance_method"></a>
Not documented.

### `ending_inferred?()` <a id="method-i-ending_inferred-3F"></a> <a id="ending_inferred?-instance_method"></a>
Always true: no store on disk records WHY a session stopped — the on-disk
transcript holds no stop reason and no turn count, because those live in the
streamed output of a non-interactive run, not in the session file. So the
ending is always deduced, and must always be labelled as such rather than
presented as a recorded fact.
- **@return** [Boolean]
