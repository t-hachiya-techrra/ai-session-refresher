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
for tool in "${TOOLS[@]}"; do
    pane_file="$STATE_DIR/$tool.pane"
    if [ -f "$pane_file" ]; then
        printf '%-22s %s\n' "$tool:" "$(cat "$pane_file")"
    else
        printf '%-22s %s\n' "$tool:" "pane file missing"
    fi
done
echo "=== idle check ==="
for tool in "${TOOLS[@]}"; do
    pane_file="$STATE_DIR/$tool.pane"
    if [ -f "$pane_file" ]; then
        pane_id=$(cat "$pane_file")
        if is_pane_idle "$pane_id"; then
            printf '%-22s %s\n' "$tool:" "idle"
        else
            printf '%-22s %s\n' "$tool:" "busy"
        fi
    else
        printf '%-22s %s\n' "$tool:" "pane file missing"
    fi
done
