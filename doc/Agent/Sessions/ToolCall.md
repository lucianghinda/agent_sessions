# Class Agent::Sessions::ToolCall <a id="class-Agent-Sessions-ToolCall"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/tool_call.rb |

One tool call, paired with whatever answered it. The pairing is by CALL ID,
never by position — a model can have two calls in flight at once, and pairing
by position would match the wrong call to the wrong result.

result_bytes is nil, not 0, when nothing answered the call: an unanswered call
and a call answered with an empty body are different facts, and defaulting the
body to "" would report a 0-byte answer for a call that was never answered.

Only sizes are carried, never bodies — transcripts hold credentials and
customer data, and this gem has no redaction before milestone 0.5.

## Attributes
### `answered_in` [R] <a id="attribute-i-answered_in"></a> <a id="answered_in-instance_method"></a>
Returns the value of attribute answered_in
- **@return** [Object] the current value of answered_in

### `asked_in` [R] <a id="attribute-i-asked_in"></a> <a id="asked_in-instance_method"></a>
Returns the value of attribute asked_in
- **@return** [Object] the current value of asked_in

### `call_id` [R] <a id="attribute-i-call_id"></a> <a id="call_id-instance_method"></a>
Returns the value of attribute call_id
- **@return** [Object] the current value of call_id

### `input_bytes` [R] <a id="attribute-i-input_bytes"></a> <a id="input_bytes-instance_method"></a>
Returns the value of attribute input_bytes
- **@return** [Object] the current value of input_bytes

### `name` [R] <a id="attribute-i-name"></a> <a id="name-instance_method"></a>
Returns the value of attribute name
- **@return** [Object] the current value of name

### `result_bytes` [R] <a id="attribute-i-result_bytes"></a> <a id="result_bytes-instance_method"></a>
Returns the value of attribute result_bytes
- **@return** [Object] the current value of result_bytes

## Public Instance Methods
### `answered?()` <a id="method-i-answered-3F"></a> <a id="answered?-instance_method"></a>
- **@return** [Boolean]
