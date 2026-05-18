#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/lib.sh"

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# 多重起動防止
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another instance running, exit"; exit 0; }

CLAUDE_PROMPT=$(cat "$SCRIPT_DIR/../prompts/claude.txt")
CODEX_PROMPT=$(cat "$SCRIPT_DIR/../prompts/codex.txt")

# workdir 存在チェック
for dir in "$CLAUDE_WORKDIR" "$CODEX_WORKDIR"; do
    if [ ! -d "$dir" ]; then
        log "ERROR: workdir not found: $dir"
        exit 1
    fi
done

# セッション無ければ作成して pane ID を保存
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "Creating tmux session: $TMUX_SESSION"
    claude_pane=$(tmux new-session -d -s "$TMUX_SESSION" -c "$CLAUDE_WORKDIR" -PF '#{pane_id}')
    codex_pane=$(tmux split-window -h -t "$claude_pane" -c "$CODEX_WORKDIR" -PF '#{pane_id}')
    tmux select-layout -t "$TMUX_SESSION" even-horizontal
    echo "$claude_pane" > "$CLAUDE_PANE_FILE"
    echo "$codex_pane" > "$CODEX_PANE_FILE"
    log "pane ids: claude=$claude_pane ($CLAUDE_WORKDIR) codex=$codex_pane ($CODEX_WORKDIR)"
    # .bashrc の初期化（compinit/starship 等）が子プロセスを spawn し終えるまで待つ
    sleep 2
fi

# state ファイルとセッションの整合性チェック
if [ ! -f "$CLAUDE_PANE_FILE" ] || [ ! -f "$CODEX_PANE_FILE" ]; then
    log "ERROR: state files missing but session alive."
    log "Run: tmux kill-session -t $TMUX_SESSION  (then re-run this script)"
    exit 1
fi

CLAUDE_PANE=$(cat "$CLAUDE_PANE_FILE")
CODEX_PANE=$(cat "$CODEX_PANE_FILE")

# pane の存在確認
for pane in "$CLAUDE_PANE" "$CODEX_PANE"; do
    if ! tmux list-panes -a -F '#{pane_id}' | grep -qx "$pane"; then
        log "ERROR: pane $pane not found. Run 'tmux kill-session -t $TMUX_SESSION' and retry."
        exit 1
    fi
done

# ツール起動 + プロンプト投入ヘルパ
launch_and_send() {
    local name="$1" pane="$2" cmd="$3" prompt="$4" wait_max="$5" ready_pattern="$6" workdir="$7"

    if is_pane_idle "$pane"; then
        # ツール未起動 → 起動してから ready 待ち
        local quoted_workdir quoted_cmd
        printf -v quoted_workdir '%q' "$workdir"
        printf -v quoted_cmd '%q' "$cmd"
        log "Starting $name in pane $pane (workdir: $workdir)"
        tmux send-keys -t "$pane" "cd $quoted_workdir && clear" Enter
        sleep 1
        tmux send-keys -t "$pane" "$quoted_cmd" Enter
        if ! wait_for_tool_ready "$pane" "$ready_pattern" "$wait_max"; then
            log "$name did not become ready within ${wait_max}s, sending prompt anyway (may fail)"
        fi
    else
        # ツール起動済み → ready パターンが既に出ているか確認、なければ待つ
        log "$name is already running, sending prompt directly"
        if ! wait_for_tool_ready "$pane" "$ready_pattern" 5; then
            log "$name ready pattern not found, sending prompt anyway"
        fi
    fi

    log "Sending prompt to $name"
    tmux send-keys -t "$pane" "$prompt"
    sleep 1
    tmux send-keys -t "$pane" Enter
}

# Claude Code: ╭─ 罫線と "for shortcuts" を検出
CLAUDE_READY_PATTERN='╭─|for shortcuts'
# Codex CLI: "◯" や "session id:" を検出
CODEX_READY_PATTERN='◯|session id:'

launch_and_send "codex"  "$CODEX_PANE"  "$CODEX_CMD"  "$CODEX_PROMPT"  "$CODEX_WAIT_MAX"  "$CODEX_READY_PATTERN"  "$CODEX_WORKDIR"
launch_and_send "claude" "$CLAUDE_PANE" "$CLAUDE_CMD" "$CLAUDE_PROMPT" "$CLAUDE_WAIT_MAX" "$CLAUDE_READY_PATTERN" "$CLAUDE_WORKDIR"

log "Done"
