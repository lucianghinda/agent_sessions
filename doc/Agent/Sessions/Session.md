# Class Agent::Sessions::Session <a id="class-Agent-Sessions-Session"></a>

|  |  |
| --- | --- |
| **Inherits** | Object |
| **Defined in** | lib/agent/sessions/session.rb |

One recorded conversation. Everything here comes from a stat or the store's
own metadata — except project_path, which may need to read inside the session
file (design doc section 7: the on-disk directory encodings are lossy, so the
recorded cwd inside the file is the only reliable source). It is computed on
first access and memoized, which is why this is a plain class rather than a
frozen Data: an instance is immutable except for that one memo.

Equality is identity, not value — unlike every sibling value object here,
which gets value equality for free from Data. A value comparison would have to
force project_path on both operands, turning a `uniq` over thousands of
sessions into the full content sweep the design works to avoid. A caller
keying a mixed-agent collection should use `uid`, which exists for exactly
that. Note `to_h` includes `uid`, so its output does not round-trip back
through `new`.

## Constants
### `UNRESOLVED` <a id="constant-UNRESOLVED"></a> <a id="UNRESOLVED-constant"></a>
Not documented.

## Attributes
### `agent` [R] <a id="attribute-i-agent"></a> <a id="agent-instance_method"></a>
Returns the value of attribute agent.

### `bytes` [R] <a id="attribute-i-bytes"></a> <a id="bytes-instance_method"></a>
Returns the value of attribute bytes.

### `fidelity` [R] <a id="attribute-i-fidelity"></a> <a id="fidelity-instance_method"></a>
Returns the value of attribute fidelity.

### `format` [R] <a id="attribute-i-format"></a> <a id="format-instance_method"></a>
Returns the value of attribute format.

### `id` [R] <a id="attribute-i-id"></a> <a id="id-instance_method"></a>
Returns the value of attribute id.

### `path` [R] <a id="attribute-i-path"></a> <a id="path-instance_method"></a>
Returns the value of attribute path.

### `started_at` [R] <a id="attribute-i-started_at"></a> <a id="started_at-instance_method"></a>
Returns the value of attribute started_at.

### `updated_at` [R] <a id="attribute-i-updated_at"></a> <a id="updated_at-instance_method"></a>
Returns the value of attribute updated_at.

## Public Instance Methods
### `initialize(agent:, id:, path:, started_at:, updated_at:, bytes:, format:, fidelity:, project_path: UNRESOLVED, &project_path_resolver)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Session] a new instance of Session

### `inspect()` <a id="method-i-inspect"></a> <a id="inspect-instance_method"></a>
Never calls project_path: inspecting a session in a debugger must not trigger
the read that enumeration deliberately deferred.

### `project_path()` <a id="method-i-project_path"></a> <a id="project_path-instance_method"></a>
A resolver that raises is deliberately not memoized: a failed read is not an
answer, so the next call retries rather than freezing the failure in place.

Not thread-safe by design: concurrent first access can run the resolver more
than once, but every run yields the same value and the assignment is atomic on
MRI, so there is no torn read to guard against. Do not add a mutex.

### `to_h()` <a id="method-i-to_h"></a> <a id="to_h-instance_method"></a>
The honest full dump — includes project_path, so it forces that read. Callers
listing thousands of sessions should build their own slimmer rows.

### `uid()` <a id="method-i-uid"></a> <a id="uid-instance_method"></a>
Collision-free across a mixed-agent collection, where bare ids may repeat.
