# Class Agent::Sessions::Compaction <a id="class-Agent-Sessions-Compaction"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/compaction.rb |

A point where the agent replaced earlier turns with a summary. Not a message:
its own payload restates turns already yielded, so anyone counting would count
them twice. replaced_count is how many turns it stood in for.

## Attributes
### `at` [R] <a id="attribute-i-at"></a> <a id="at-instance_method"></a>
Returns the value of attribute at
- **@return** [Object] the current value of at

### `raw` [R] <a id="attribute-i-raw"></a> <a id="raw-instance_method"></a>
Returns the value of attribute raw
- **@return** [Object] the current value of raw

### `replaced_count` [R] <a id="attribute-i-replaced_count"></a> <a id="replaced_count-instance_method"></a>
Returns the value of attribute replaced_count
- **@return** [Object] the current value of replaced_count
