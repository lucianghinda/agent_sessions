# VHS tape for agent_sessions — render with: vhs demo.tape
# https://github.com/charmbracelet/vhs

Output demo.gif

Set FontSize 16
Set Width 1200
Set Height 620
Set Padding 20
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms

# Off-camera: activate Ruby so `agent-sessions` is on PATH
Hide
Type "source /opt/homebrew/opt/chruby/share/chruby/chruby.sh && chruby ruby-4.0.1 && clear"
Enter
Sleep 1s
Show

Type "# Where do AI coding agents store their session logs? This gem knows."
Sleep 800ms
Enter
Sleep 500ms

Type "agent-sessions where codex"
Sleep 500ms
Enter
Sleep 3.5s

Type "agent-sessions doctor codex"
Sleep 500ms
Enter
Sleep 3.5s

Type "agent-sessions du"
Sleep 500ms
Enter
Sleep 4s

Type "agent-sessions audit"
Sleep 500ms
Enter
Sleep 6s
