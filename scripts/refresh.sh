#!/usr/bin/env bash
set -euo pipefail
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) || { echo "bash 4.3+ required (got $BASH_VERSION)"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/lib.sh"

# TOOLS に列挙した各ツールの必須キーが定義されているか早期チェック
for tool in "${TOOLS[@]}"; do
    for key in TOOL_cmdline TOOL_workdir TOOL_wait_max TOOL_ready_pattern TOOL_prompt_file; do
        declare -n _ref="$key"
        if [[ -z "${_ref[$tool]+set}" ]]; then
            echo "ERROR: $key[$tool] is not defined in config.sh"; exit 1
        fi
    done
done

mkdir -p "$STATE_DIR" "$(dirname "$LOG_FILE")"

# 多重起動防止
exec 9>"$LOCK_FILE"
flock -n 9 || { log "another instance running, exit"; exit 0; }

# プロンプトを一括ロード
declare -A TOOL_prompt
for tool in "${TOOLS[@]}"; do
    prompt_path="$SCRIPT_DIR/../prompts/${TOOL_prompt_file[$tool]}"
    if [ ! -f "$prompt_path" ]; then
        log "ERROR: prompt file not found: $prompt_path"
        exit 1
    fi
    TOOL_prompt[$tool]=$(cat "$prompt_path")
done

# workdir 存在チェック
for tool in "${TOOLS[@]}"; do
    if [ ! -d "${TOOL_workdir[$tool]}" ]; then
        log "ERROR: workdir not found: ${TOOL_workdir[$tool]} (tool: $tool)"
        exit 1
    fi
done

# セッション無ければ作成して pane ID を保存
if ! tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
    log "Creating tmux session: $TMUX_SESSION"
    first_pane=""
    for tool in "${TOOLS[@]}"; do
        local_workdir="${TOOL_workdir[$tool]}"
        if [ -z "$first_pane" ]; then
            pane_id=$(tmux new-session -d -s "$TMUX_SESSION" -c "$local_workdir" -PF '#{pane_id}')
            first_pane="$pane_id"
        else
            pane_id=$(tmux split-window -h -t "$first_pane" -c "$local_workdir" -PF '#{pane_id}')
        fi
        echo "$pane_id" > "$STATE_DIR/$tool.pane"
        log "pane created: $tool=$pane_id ($local_workdir)"
    done
    tmux select-layout -t "$TMUX_SESSION" even-horizontal
    # .bashrc の初期化（compinit/starship 等）が子プロセスを spawn し終えるまで待つ
    sleep 2
fi

# state ファイルとセッションの整合性チェック
for tool in "${TOOLS[@]}"; do
    if [ ! -f "$STATE_DIR/$tool.pane" ]; then
        log "ERROR: state file missing for $tool but session alive."
        log "Run: tmux kill-session -t $TMUX_SESSION  (then re-run this script)"
        exit 1
    fi
done

# pane の存在確認
for tool in "${TOOLS[@]}"; do
    pane_id=$(cat "$STATE_DIR/$tool.pane")
    if ! tmux list-panes -a -F '#{pane_id}' | grep -qx "$pane_id"; then
        log "ERROR: pane $pane_id ($tool) not found. Run 'tmux kill-session -t $TMUX_SESSION' and retry."
        exit 1
    fi
done

# ツール起動 + プロンプト投入ヘルパ
launch_and_send() {
    local name="$1" pane="$2" cmdline="$3" prompt="$4" wait_max="$5" ready_pattern="$6" workdir="$7"

    if is_pane_idle "$pane"; then
        local quoted_workdir
        printf -v quoted_workdir '%q' "$workdir"
        log "Starting $name in pane $pane (workdir: $workdir)"
        tmux send-keys -t "$pane" "cd $quoted_workdir && clear" Enter
        sleep 1
        tmux send-keys -t "$pane" "$cmdline" Enter
        if ! wait_for_tool_ready "$pane" "$ready_pattern" "$wait_max"; then
            log "$name did not become ready within ${wait_max}s, sending prompt anyway (may fail)"
        fi
    else
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

for tool in "${TOOLS[@]}"; do
    pane_id=$(cat "$STATE_DIR/$tool.pane")
    launch_and_send \
        "$tool" \
        "$pane_id" \
        "${TOOL_cmdline[$tool]}" \
        "${TOOL_prompt[$tool]}" \
        "${TOOL_wait_max[$tool]}" \
        "${TOOL_ready_pattern[$tool]}" \
        "${TOOL_workdir[$tool]}"
done

log "Done"
