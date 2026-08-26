# Module Agent::Sessions::HomeExpansion <a id="module-Agent-Sessions-HomeExpansion"></a>

|  |  |
| --- | --- |
| **Defined in** | lib/agent/sessions/home_expansion.rb |

Shared path expansion for Adapters::Base and Audit. Expands "~" against the
injected env so callers can resolve paths for a machine that is not their own;
joins relative paths (including "~user"-looking strings that are not a real
shell lookup here) under that same home; and treats an explicitly empty HOME
the same as an absent one.
