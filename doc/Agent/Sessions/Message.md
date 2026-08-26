# Class Agent::Sessions::Message <a id="class-Agent-Sessions-Message"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/message.rb |

One turn. `role` is normalized to :user, :assistant, :system or :tool, with
:unknown for a role the adapter did not recognize — the four the spec names
were written before any real corpus was read, and Codex promptly said
"developer".

raw is never dropped (Layer 3 rule 1): when this normalization is wrong or
incomplete, a caller escapes the abstraction instead of forking the gem.

usage and model are nil wherever the format does not put them on the message
itself — Codex records tokens in separate event records and the model in its
session header, so its messages carry neither; the reader's session-level
`usage` is where those formats answer. A nil here means "not recorded on this
message", never "zero tokens".

## Constants
### `ROLES` <a id="constant-ROLES"></a> <a id="ROLES-constant"></a>
Not documented.

## Attributes
### `at` [R] <a id="attribute-i-at"></a> <a id="at-instance_method"></a>
Returns the value of attribute at
- **@return** [Object] the current value of at

### `model` [R] <a id="attribute-i-model"></a> <a id="model-instance_method"></a>
Returns the value of attribute model
- **@return** [Object] the current value of model

### `parts` [R] <a id="attribute-i-parts"></a> <a id="parts-instance_method"></a>
Returns the value of attribute parts
- **@return** [Object] the current value of parts

### `raw` [R] <a id="attribute-i-raw"></a> <a id="raw-instance_method"></a>
Returns the value of attribute raw
- **@return** [Object] the current value of raw

### `role` [R] <a id="attribute-i-role"></a> <a id="role-instance_method"></a>
Returns the value of attribute role
- **@return** [Object] the current value of role

### `usage` [R] <a id="attribute-i-usage"></a> <a id="usage-instance_method"></a>
Returns the value of attribute usage
- **@return** [Object] the current value of usage

## Public Instance Methods
### `initialize(role:, at:, parts:, raw:, usage: nil, model: nil)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@raise** [ArgumentError]
- **@return** [Message] a new instance of Message

### `text()` <a id="method-i-text"></a> <a id="text-instance_method"></a>
Concatenated :text parts, as the design doc specifies — no separator inserted,
because a separator is a formatting decision this layer has no business
making. A caller that needs the boundaries has `parts`.
