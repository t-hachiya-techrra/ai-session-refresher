#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/lib.sh"

echo "=== session ==="
tmux has-session -t "$TMUX_SESSION" 2>/dev/null && echo "alive: $TMUX_SESSION" || echo "dead: $TMUX_SESSION"
echo "=== panes ==="
tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id} #{pane_current_command}' 2>/dev/null || true
echo "=== saved pane ids ==="
if [ -f "$CLAUDE_PANE_FILE" ]; then echo "claude: $(cat "$CLAUDE_PANE_FILE")"; else echo "claude: pane file missing"; fi
if [ -f "$CODEX_PANE_FILE" ];  then echo "codex:  $(cat "$CODEX_PANE_FILE")";  else echo "codex:  pane file missing"; fi
echo "=== idle check ==="
if [ -f "$CLAUDE_PANE_FILE" ]; then
    is_pane_idle "$(cat "$CLAUDE_PANE_FILE")" && echo "claude: idle" || echo "claude: busy"
else
    echo "claude: pane file missing"
fi
if [ -f "$CODEX_PANE_FILE" ]; then
    is_pane_idle "$(cat "$CODEX_PANE_FILE")" && echo "codex:  idle" || echo "codex:  busy"
else
    echo "codex:  pane file missing"
fi
