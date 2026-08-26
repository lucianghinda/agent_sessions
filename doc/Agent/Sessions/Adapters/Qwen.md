# Class Agent::Sessions::Adapters::Qwen <a id="class-Agent-Sessions-Adapters-Qwen"></a>

|  |  |
| --- | --- |
| **Inherits** | [Agent::Sessions::Adapters::Base](Base.md) |
| **Defined in** | lib/agent/sessions/adapters/qwen.rb |

Qwen Code. PROVISIONAL: ~/.qwen does not exist on the machine this was written
on (2026-08-24), so every claim here comes from tokentelemetry's working
parser of the same store (resources/tokentelemetry, backend/main.py section 4)
rather than from observation — the same standing the pi reader carries, and
declared the same way.

Qwen is a Gemini CLI fork that kept Gemini's directory layout and adopted
Anthropic's message shape, which is why its store looks like ~/.gemini's while
its records read like Claude's.

## Public Class Methods
### `reader_class()` <a id="method-c-reader_class"></a> <a id="reader_class-class_method"></a>
Not documented.

## Public Instance Methods
### `project_path_for(path)` <a id="method-i-project_path_for"></a> <a id="project_path_for-instance_method"></a>
Unlike Gemini's, the project directory is reported as a name this gem cannot
decode into a path, so the recorded cwd inside the file is the only source —
the same position Claude and pi are in. The predicate is mandatory:
scan_jsonl_for_key stops at the first record merely CARRYING the key, so
without it a record holding "cwd": null shadows a later usable one
permanently.

### `warnings()` <a id="method-i-warnings"></a> <a id="warnings-instance_method"></a>
Not documented.
