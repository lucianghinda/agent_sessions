# Class Agent::Sessions::Readers::Claude <a id="class-Agent-Sessions-Readers-Claude"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Readers::Base](Base.md) |
| **Defined in** | lib/agent/sessions/readers/claude.rb |

Claude Code transcripts. Written against 142 real transcripts, 29,688 records,
inventoried 2026-08-12.

The content vocabulary is a straight match for this gem's: text, thinking,
tool_use, tool_result and image are exactly the five part types the design doc
names, so nothing here has to invent a mapping. What Claude adds is everything
**around** the conversation — a third of all records are session state, and
two more kinds carry context the model saw without being a turn anyone took.

## Constants
### `CONTENT_PARTS` <a id="constant-CONTENT_PARTS"></a> <a id="CONTENT_PARTS-constant"></a>
Not documented.

### `EVENT_TYPES` <a id="constant-EVENT_TYPES"></a> <a id="EVENT_TYPES-constant"></a>
Context the model saw, but not a turn: `system` is turn_duration,
stop_hook_summary, away_summary, local_command; `attachment` is hook output,
skill listings, task reminders, pasted files. Same judgement Codex's event_msg
gets — available on request, never on by default.

### `MAX_SPILL_BYTES` <a id="constant-MAX_SPILL_BYTES"></a> <a id="MAX_SPILL_BYTES-constant"></a>
A spilled file is read whole. The largest observed is well under this; the cap
exists because the pointer says nothing about the size.

### `NON_MESSAGE_TYPES` <a id="constant-NON_MESSAGE_TYPES"></a> <a id="NON_MESSAGE_TYPES-constant"></a>
State, not conversation, and together 11,000+ of the records written. Skipped
in silence: warning about a record deliberately classified would teach a
caller that warnings are noise.

atis-latch and bridge-session postdate the corpus above — found by running
this reader over a live 2026-08-24 transcript and reading its own warnings (23
and 17 records), the same way Codex's tool list grew. Both are session
plumbing: a latch marker, and the record tying a local transcript to its cloud
session id (bridgeSessionId, owner uuids). Neither is a turn anyone took.

### `SPILL` <a id="constant-SPILL"></a> <a id="SPILL-constant"></a>
How Claude Code points at output too large to inline. It is prose, not a
structured field — 24 real tool_result parts and 149 attachments carry this
sentence — so the path has to be matched out of the text.

## Public Instance Methods
### `branching?()` <a id="method-i-branching-3F"></a> <a id="branching?-instance_method"></a>
Every uuid-bearing record names the record it followed, and 380 branch points
sit across 85 of 151 real transcripts — a turn edited and re-run leaves two
children under one parent. Exactly one root per file and no orphaned parent
link was found in that corpus, so the links are trustworthy enough to build a
tree from.
- **@return** [Boolean]

### `initialize(session, resolve_spills: true, **rest)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Claude] a new instance of Claude

### `subagents()` <a id="method-i-subagents"></a> <a id="subagents-instance_method"></a>
The transcripts of agents this session spawned, as readers of their own.
Exposed rather than inlined, per design doc 8.1: a subagent's turns are not
the parent's turns, and merging them would break every count taken from this
reader. 124 of these sit beside real sessions on this machine.

isSidechain is false on all 22,072 records in the main transcripts, so there
is nothing to filter out there — the separation is already how Claude Code
writes them.

### `usage()` <a id="method-i-usage"></a> <a id="usage-instance_method"></a>
Session totals, summed over assistant records but deduplicated by message.id
first — and the dedup is most of the number. One API response streams into one
record PER CONTENT BLOCK, each carrying the same message.id and the same
usage: in one real transcript on this machine (2026-08-24), 260 assistant
records share 124 message ids, 94 of which repeat with byte-identical usage. A
naive sum reports roughly double what Anthropic billed. An id-less record (not
observed, but rule 2 says formats drift) is counted rather than dropped:
overcounting a novelty beats silently ignoring it.
