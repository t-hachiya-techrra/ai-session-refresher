#!/usr/bin/env bash
# 共通ヘルパ

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# pane がアイドル（シェル直下に子プロセスがいない）か判定
is_pane_idle() {
    local pane="$1"
    local pid
    pid=$(tmux display-message -t "$pane" -p '#{pane_pid}' 2>/dev/null) || return 1
    local children
    # pgrep は該当なしで exit 1 を返すため、明示的に握り潰す
    children=$(pgrep -P "$pid" 2>/dev/null | wc -l || true)
    [ "$children" -eq 0 ]
}

# 起動完了を検出：ツール固有 UI パターンの出現を待つ
wait_for_tool_ready() {
    local pane="$1" pattern="$2" max_wait="$3"
    local elapsed=0
    while [ "$elapsed" -lt "$max_wait" ]; do
        if tmux capture-pane -t "$pane" -p | grep -qE "$pattern"; then
            return 0
        fi
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))
    done
    return 1
}
