# Class Agent::Sessions::LoopView <a id="class-Agent-Sessions-LoopView"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/agent/sessions/loop_view.rb |

Renders one Loop for a human (#ascii, #markdown) or a machine (#to_h).

Every rendering prints SIZES, never BODIES. A transcript can hold a credential
or a customer's data anywhere — even a shell command line can carry a token —
and this gem has no redaction before milestone 0.5, so a truncated preview is
not a safer middle ground; it is the same leak with extra steps. A byte count
and a tool name carry enough signal to see what a loop did without carrying
what it said.

Every timestamp goes through #utc: two renderings of the same file must be
byte-identical no matter which machine or time zone reads it, and a local time
would make that false for a fact (the recorded instant) that has not actually
changed.

The ending is always printed as inferred, because Loop#ending is always a
deduction — no on-disk transcript records WHY a session stopped, since that
fact lives in a non-interactive run's streamed output, never in the file
itself. Printing it as a plain fact would claim information the file does not
hold.

## Constants
### `HARNESS_LANE` <a id="constant-HARNESS_LANE"></a> <a id="HARNESS_LANE-constant"></a>
Not documented.

### `LABEL_SHAPE` <a id="constant-LABEL_SHAPE"></a> <a id="LABEL_SHAPE-constant"></a>
A label is a record TYPE name (hook_success, turn_duration), never prose — but
the field carrying it is a free String, so this shape check is what actually
keeps R9 (no bodies) true the day a format starts putting a sentence there
instead of a type name.

### `MODEL_LANE` <a id="constant-MODEL_LANE"></a> <a id="MODEL_LANE-constant"></a>
Not documented.

### `YOU_LANE` <a id="constant-YOU_LANE"></a> <a id="YOU_LANE-constant"></a>
Not documented.

## Public Instance Methods
### `ascii()` <a id="method-i-ascii"></a> <a id="ascii-instance_method"></a>
Not documented.

### `initialize(loop_model)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [LoopView] a new instance of LoopView

### `markdown()` <a id="method-i-markdown"></a> <a id="markdown-instance_method"></a>
Not documented.

### `to_h()` <a id="method-i-to_h"></a> <a id="to_h-instance_method"></a>
Not documented.
