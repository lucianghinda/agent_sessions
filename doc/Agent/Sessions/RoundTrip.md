# Class Agent::Sessions::RoundTrip <a id="class-Agent-Sessions-RoundTrip"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/round_trip.rb |

One model response, grouped from however many records a format split it
across. Claude Code writes one record PER CONTENT BLOCK of an API response: in
one real transcript on this machine, 260 assistant records share only 124
message.id values, so a caller counting records over- counts what the session
actually did by roughly two to one. A round trip is the unit that actually
happened.

`recorded` is the load-bearing field. False means this group was ASSUMED — the
format names no round-trip id, so grouping fell back to one message per round
trip — never "this session has none". Same rule tree()/branching? already
enforce for parent links: "not recorded" must never read as "recorded and
empty".

A round trip deliberately carries NO tool results: a result can arrive long
after its call, and grouping streams one record at a time, so pairing a call
with its eventual result is a separate, eager layer (Agent::Sessions::Loop,
landing next) rather than this one's job.

## Attributes
### `index` [R] <a id="attribute-i-index"></a> <a id="index-instance_method"></a>
Returns the value of attribute index
- **@return** [Object] the current value of index

### `messages` [R] <a id="attribute-i-messages"></a> <a id="messages-instance_method"></a>
Returns the value of attribute messages
- **@return** [Object] the current value of messages

### `recorded` [R] <a id="attribute-i-recorded"></a> <a id="recorded-instance_method"></a>
Returns the value of attribute recorded
- **@return** [Object] the current value of recorded

### `usage` [R] <a id="attribute-i-usage"></a> <a id="usage-instance_method"></a>
Returns the value of attribute usage
- **@return** [Object] the current value of usage

## Public Instance Methods
### `at()` <a id="method-i-at"></a> <a id="at-instance_method"></a>
The first recorded Time among the messages, or nil when none carried one.

### `calls()` <a id="method-i-calls"></a> <a id="calls-instance_method"></a>
The :tool_use parts only, [] when this round trip asked for no tool.

### `model()` <a id="method-i-model"></a> <a id="model-instance_method"></a>
The first recorded model String, or nil.

### `parts()` <a id="method-i-parts"></a> <a id="parts-instance_method"></a>
Every part of every message, in file order.

### `roles()` <a id="method-i-roles"></a> <a id="roles-instance_method"></a>
The distinct roles in this group, in first-seen order.
