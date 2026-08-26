# Class Agent::Sessions::Readers::Pi <a id="class-Agent-Sessions-Readers-Pi"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/pi.rb |

pi session files. PROVISIONAL in a way no other reader is: this machine holds
nine real pi project directories and zero session files inside them
(2026-08-24), so every mapping below is written against tokentelemetry's
working parser of the same format (resources/tokentelemetry, backend/main.py,
_scan_pi_sessions) rather than a corpus of pi's own output. That is
observation of running code, not of data — one step better than the design
doc's prose, one step short of every other reader's evidence. Where the two
could disagree, rule 2 already decides the outcome: a shape this reader has
not seen becomes an :unknown part and a warning, never an exception, and raw
carries what really happened.

The format per that parser: a header record {"type":"session", id, cwd,
timestamp}, then typed records — "model_change" (provider, modelId) and
"message" ({role, model, content[], usage}). usage spells its keys camelCase
(cacheRead, cacheWrite) and carries agent-computed cost.

## Constants
### `NON_MESSAGE_TYPES` <a id="constant-NON_MESSAGE_TYPES"></a> <a id="NON_MESSAGE_TYPES-constant"></a>
The header and settings records are session state, not conversation —the same
judgement Codex's session_meta gets. model_change is state too: the model a
LATER message used is on that message.

### `ROLES` <a id="constant-ROLES"></a> <a id="ROLES-constant"></a>
Not documented.

## Public Instance Methods
### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Session totals, summed per message record. No dedup: nothing observed or
reported suggests pi repeats one response across records the way Claude does —
but nothing proves it either, so if pi totals ever read roughly double a
provider's bill, this is where to look.
