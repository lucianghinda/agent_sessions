# Class Agent::Sessions::Usage <a id="class-Agent-Sessions-Usage"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/usage.rb |

Token counts an agent reported, for one message or one whole session,
normalized to five DISJOINT buckets: `input` never includes what was read from
or written to cache, and `output` never includes `reasoning`. Agents disagree
here — Codex's input_tokens includes its cached_input_tokens, Claude's does
not (both verified against real stores on this machine, 2026-08-24) — and a
caller summing across agents needs one rule, not one per agent. Readers do the
subtraction; this object only holds the result.

nil means "this format does not record that dimension", and it is load-
bearing: absence must never read as zero, for the same reason
Agent::Sessions.read raises on a format with no reader. `cost` is reported by
the agent or absent — never derived from a pricing table, which would go stale
in a gem and is a consumer's decision anyway.

## Attributes
### `cache_creation` [R] <a id="attribute-i-cache_creation"></a> <a id="cache_creation-instance_method"></a>
Returns the value of attribute cache_creation
- **@return** [Object] the current value of cache_creation

### `cache_read` [R] <a id="attribute-i-cache_read"></a> <a id="cache_read-instance_method"></a>
Returns the value of attribute cache_read
- **@return** [Object] the current value of cache_read

### `cost` [R] <a id="attribute-i-cost"></a> <a id="cost-instance_method"></a>
Returns the value of attribute cost
- **@return** [Object] the current value of cost

### `input` [R] <a id="attribute-i-input"></a> <a id="input-instance_method"></a>
Returns the value of attribute input
- **@return** [Object] the current value of input

### `output` [R] <a id="attribute-i-output"></a> <a id="output-instance_method"></a>
Returns the value of attribute output
- **@return** [Object] the current value of output

### `reasoning` [R] <a id="attribute-i-reasoning"></a> <a id="reasoning-instance_method"></a>
Returns the value of attribute reasoning
- **@return** [Object] the current value of reasoning

## Public Instance Methods
### `+(other)` <a id="method-i--2B"></a> <a id="+-instance_method"></a>
Sums dimension-wise, keeping the nil/zero distinction: nil + nil stays nil
("neither side records this"), nil + n is n — one recorded value is a real
value, not a value plus an unknown, because per-message absence under a format
that does record the dimension means "none reported for this message", the one
place absence and zero do coincide.

### `initialize(input: nil, output: nil, cache_read: nil, cache_creation: nil, reasoning: nil, cost: nil)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Usage] a new instance of Usage
