# Class Agent::Sessions::Readers::Base <a id="class-Agent-Sessions-Readers-Base"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/agent/sessions/readers/base.rb |

Layer 3: turning one session file into messages. Subclasses supply the
mapping; everything about *how the file is read* lives here, because the three
rules that make this layer survivable (design doc §5) are properties of the
reading, not of any one agent's format:

    1. raw is never dropped.
    2. Unknown records become :unknown parts and warnings, never exceptions.
    3. Reading streams. No code path may assume a file fits in memory.

Rule 3 is why this does not use File.foreach without a chunk size. A truncated
log can hold no newline at all, and "read one line" would then mean "read 2.6
GB into a String" — the file the article that started this gem found on a real
machine.

## Constants
### `MAX_RECORD_BYTES` <a id="constant-MAX_RECORD_BYTES"></a> <a id="MAX_RECORD_BYTES-constant"></a>
Chunk size, and so the largest record that can be read whole. Measured against
415 real Codex rollout files (128,987 records, 2026-08-12): 14 records exceed
1 MB and the largest is 2.41 MB, so Layer 2's MAX_LINE_BYTES of 1 MB would
silently drop real messages. 8 MB is ~3.3x the observed maximum. A record
beyond it is reported, never dropped in silence, because a missing message is
this gem's worst failure mode.

## Attributes
### `session` [R] <a id="attribute-i-session"></a> <a id="session-instance_method"></a>
Returns the value of attribute session.

## Public Instance Methods
### `branching?()` <a id="method-i-branching-3F"></a> <a id="branching?-instance_method"></a>
Whether this agent records which turn each turn followed. False here: most
stores are an append-only list and a tree would have to be invented.
- **@return** [Boolean]

### `compactions()` <a id="method-i-compactions"></a> <a id="compactions-instance_method"></a>
Boundaries where the agent replaced earlier turns with a summary. Its own
pass: a caller asking only for compactions should not have to materialize
every message to get them.

### `each_message()` <a id="method-i-each_message"></a> <a id="each_message-instance_method"></a>
Streams. Yields each message as it is parsed; a caller that breaks after one
has read one record, not the file.

### `fidelity()` <a id="method-i-fidelity"></a> <a id="fidelity-instance_method"></a>
Not documented.

### `initialize(session, include_events: false)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Base] a new instance of Base

### `messages()` <a id="method-i-messages"></a> <a id="messages-instance_method"></a>
Eager, for sessions small enough to hold. The design doc offers both and names
this the convenience: `messages` is what a script wants, and `each_message` is
what a 2.6 GB file requires.

### `partial?()` <a id="method-i-partial-3F"></a> <a id="partial?-instance_method"></a>
True where the local file is not the whole story — Amp, whose server holds the
canonical copy. Overridden there, false everywhere else.
- **@return** [Boolean]

### `tree()` <a id="method-i-tree"></a> <a id="tree-instance_method"></a>
The conversation as roots and their continuations, for an agent that records
parent links. Unlike every other method here this cannot stream — a tree is
not knowable until the last record is read — so it holds one session's
messages at once and says so rather than pretending otherwise.

Raises rather than returning an empty list or nil for a store with no parent
links, for the reason Agent::Sessions.read raises: "this format does not
record that" must never read as "this session has none".

### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
This session's token totals as a Usage, or nil where the format does not
record them (Amp) or this reader has not learned where they live. nil, not an
empty Usage: "this store does not say" must never read as "this session cost
nothing" — the same rule tree() enforces by raising.

Each reader that overrides this also decides its own summation rule, because
that rule is format knowledge: Claude repeats one API response's usage across
several records (94 of 124 message ids in one real transcript), Codex writes a
running total where only the last record counts. A base-class sum would get
both wrong.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
Populated as records are read, so this answers for whatever has been consumed
so far. uniq because a second pass over the same file would otherwise repeat
every warning it already reported.
