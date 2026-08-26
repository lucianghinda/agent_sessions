# Class Agent::Sessions::Part <a id="class-Agent-Sessions-Part"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/part.rb |

One piece of a message. `type` is the normalized vocabulary (design doc §5);
everything an agent said that this gem could not classify arrives as :unknown
rather than as an exception, and the message's `raw` still holds it.

text carries the readable content for :text, :thinking and :tool_result. name
and call_id are tool plumbing, nil elsewhere. An :image part has neither — its
URL or payload stays in raw, because normalizing an image would mean deciding
whether to load it, and reading is stat-cheap by design.

## Constants
### `TYPES` <a id="constant-TYPES"></a> <a id="TYPES-constant"></a>
Not documented.

## Attributes
### `call_id` [R] <a id="attribute-i-call_id"></a> <a id="call_id-instance_method"></a>
Returns the value of attribute call_id
- **@return** [Object] the current value of call_id

### `name` [R] <a id="attribute-i-name"></a> <a id="name-instance_method"></a>
Returns the value of attribute name
- **@return** [Object] the current value of name

### `text` [R] <a id="attribute-i-text"></a> <a id="text-instance_method"></a>
Returns the value of attribute text
- **@return** [Object] the current value of text

### `type` [R] <a id="attribute-i-type"></a> <a id="type-instance_method"></a>
Returns the value of attribute type
- **@return** [Object] the current value of type

## Public Instance Methods
### `initialize(type:, text: nil, name: nil, call_id: nil)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@raise** [ArgumentError]
- **@return** [Part] a new instance of Part
