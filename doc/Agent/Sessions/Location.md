# Class Agent::Sessions::Location <a id="class-Agent-Sessions-Location"></a>

|  |  |
| --- | --- |
| **Inherits** | Data |
| **Defined in** | lib/agent/sessions/location.rb |

One resolved layer of an agent's store.

A location is one of three shapes, and `files` answers each differently:

    glob         a directory plus a pattern       -> the pattern's matches
    single_file  one file (a `path:` store)       -> itself, if it is there
    directory    a directory with no known shape  -> nothing, and enumerable? is false

The third shape is a store whose internal layout this gem has not learned yet
(opencode's pre-1.2.0 storage/ tree, Cursor's acp-sessions/). It returns [] so
a caller sweeping every layer does not blow up, and answers enumerable? false
so that caller can tell "nothing here to enumerate" apart from "enumerated,
found none".

single_file comes from the adapter's store DSL: <code>path:</code> means one
file, <code>dir:</code> means a directory. Resolution used to discard that
distinction, which made a Layer 2 enumerator written as
layers.flat_map(&:files) silently skip history.jsonl, session_index.jsonl and
secrets.json — a missing-session bug, not a visible error.

## Attributes
### `format` [R] <a id="attribute-i-format"></a> <a id="format-instance_method"></a>
Returns the value of attribute format
- **@return** [Object] the current value of format

### `glob` [R] <a id="attribute-i-glob"></a> <a id="glob-instance_method"></a>
Returns the value of attribute glob
- **@return** [Object] the current value of glob

### `kind` [R] <a id="attribute-i-kind"></a> <a id="kind-instance_method"></a>
Returns the value of attribute kind
- **@return** [Object] the current value of kind

### `path` [R] <a id="attribute-i-path"></a> <a id="path-instance_method"></a>
Returns the value of attribute path
- **@return** [Object] the current value of path

### `single_file` [R] <a id="attribute-i-single_file"></a> <a id="single_file-instance_method"></a>
Returns the value of attribute single_file
- **@return** [Object] the current value of single_file

## Public Instance Methods
### `enumerable?()` <a id="method-i-enumerable-3F"></a> <a id="enumerable?-instance_method"></a>
- **@return** [Boolean]

### `exists?()` <a id="method-i-exists-3F"></a> <a id="exists?-instance_method"></a>
- **@return** [Boolean]

### `files()` <a id="method-i-files"></a> <a id="files-instance_method"></a>
Not documented.

### `initialize(kind:, path:, format:, glob: nil, single_file: false)` <a id="method-i-initialize"></a> <a id="initialize-instance_method"></a>
- **@return** [Location] a new instance of Location
