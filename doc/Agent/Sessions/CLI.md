# Class Agent::Sessions::CLI <a id="class-Agent-Sessions-CLI"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/agent/sessions/cli.rb |

## Constants
### `GROUP_COLUMN_MAX` <a id="constant-GROUP_COLUMN_MAX"></a> <a id="GROUP_COLUMN_MAX-constant"></a>
Group names in `du --by project` are the same shape of problem one cap wider:
a real project path on this machine ran 169 characters, wrapping every row
across three lines on an 80-column terminal (list's own id column tops out at
72 total). Wider than ID_COLUMN_MAX because a path's head (which user, which
drive) and tail (the actual project directory) are both worth keeping, and
both need more room than a bare uuid does.

### `ID_COLUMN_MAX` <a id="constant-ID_COLUMN_MAX"></a> <a id="ID_COLUMN_MAX-constant"></a>
Cap the id column. Cursor's ids are two nested uuids joined by "/" (36 + 1 +
36 = 73 chars) where every other agent needs a bare uuid (36) or less, so one
Cursor row makes the global id_width 73 — padding every other row with ~35
spaces and pushing the line past 100 chars, which wraps on an 80-column
terminal. Elide the middle and keep both ends, since the ends are what a human
matches against a directory name.

### `SINCE_UNITS` <a id="constant-SINCE_UNITS"></a> <a id="SINCE_UNITS-constant"></a>
Not documented.

### `STATUS_MARKS` <a id="constant-STATUS_MARKS"></a> <a id="STATUS_MARKS-constant"></a>
Not documented.

## Public Instance Methods
### `initialize(argv, env: ENV, stdout: $stdout, stderr: $stderr, now: Time.now)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [CLI] a new instance of CLI

### `run()` <a id="method-i-run"></a> <a id="run-instance_method"></a>
Not documented.
