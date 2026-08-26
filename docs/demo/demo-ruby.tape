# VHS tape for the agent_sessions Ruby API — render with: vhs demo-ruby.tape
# https://github.com/charmbracelet/vhs

Output demo-ruby.gif

Set FontSize 16
Set Width 1200
Set Height 620
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

# Off-camera: activate Ruby so irb sees the installed gem
Hide
Type "source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-4.0.1 && clear"
Enter
Sleep 1s
Show

Type "irb --simple-prompt --noautocomplete"
Sleep 500ms
Enter
Sleep 1.5s

Type `require "agent_sessions"`
Sleep 500ms
Enter
Sleep 1.5s

Type "store = Agent::Sessions.locate(:codex);"
Sleep 500ms
Enter
Sleep 1s

Type "store.effective.path"
Sleep 300ms
Enter
Sleep 1.5s

Type "store.format"
Sleep 300ms
Enter
Sleep 1.5s

Type "store.documented?"
Sleep 300ms
Enter
Sleep 1.5s

Type "store.retention"
Sleep 300ms
Enter
Sleep 1.5s

Type "Agent::Sessions.installed.map(&:label)"
Sleep 500ms
Enter
Sleep 3s

Type "session = Agent::Sessions.sessions(:claude).max_by(&:bytes);"
Sleep 500ms
Enter
Sleep 1s

Type "session.bytes"
Sleep 300ms
Enter
Sleep 1.5s

Type "reader = Agent::Sessions.read(session);"
Sleep 500ms
Enter
Sleep 1s

Type "reader.usage"
Sleep 500ms
Enter
Sleep 6s
