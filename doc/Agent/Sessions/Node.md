# Class Agent::Sessions::Node <a id="class-Agent-Sessions-Node"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/node.rb |

One message in a branching conversation, with the messages that follow it.
Agents that let a turn be edited and re-run record two children under one
parent: 380 such branch points sit across 85 of 151 real Claude transcripts,
so a caller reading `messages` in file order is reading two alternative
histories interleaved without being told.

children is a plain Array and the Node is frozen, so the shape is settled
before anyone sees it.

## Attributes
### `children` [R] <a id="attribute-i-children"></a> <a id="children-instance_method"></a>
Returns the value of attribute children
- **@return** [Object] the current value of children

### `message` [R] <a id="attribute-i-message"></a> <a id="message-instance_method"></a>
Returns the value of attribute message
- **@return** [Object] the current value of message
