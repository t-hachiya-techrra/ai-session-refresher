#!/usr/bin/env bash
set -euo pipefail
((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) || { echo "bash 4.3+ required (got $BASH_VERSION)"; exit 1; }
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../config.sh"
source "$SCRIPT_DIR/lib.sh"

# 引数解析: --no-prompt はツール起動だけ行いプロンプト送信をスキップする
NO_PROMPT=0
for arg in "$@"; do
    case "$arg" in
        --no-prompt) NO_PROMPT=1 ;;
        -h|--help) echo "Usage: $(basename "$0") [--no-prompt]"; exit 0 ;;
        *) echo "ERROR: unknown argument: $arg (see --help)" >&2; exit 1 ;;
    esac
done

send_prompt_via_paste_buffer() {
    local pane="$1"
    local random_bytes="${RANDOM_BYTES:-2048}"
    local random_token prompt_text
    local tmp_file buffer_name

    if ! [[ "$random_bytes" =~ ^[0-9]+$ ]] || [ "$random_bytes" -le 0 ]; then
        random_bytes=2048
    fi

    random_token=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$random_bytes")
    prompt_text="${random_token}  Reply with exactly: OK. Do not analyze, explain, or use markdown."
    tmp_file=$(mktemp)
    printf '%s' "$prompt_text" > "$tmp_file"
    buffer_name="codex-spark-anchor-$$-$RANDOM"

    trap "tmux delete-buffer -b '$buffer_name' 2>/dev/null || true; rm -f '$tmp_file'" RETURN

    tmux load-buffer -b "$buffer_name" "$tmp_file" || return 1
    tmux paste-buffer -b "$buffer_name" -t "$pane" || return 1
    sleep 1
    tmux send-keys -t "$pane" Enter || return 1
}

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
            log "$name did not become ready within ${wait_max}s"
        fi
    else
        log "$name is already running"
        wait_for_tool_ready "$pane" "$ready_pattern" 5 || true
    fi

    if [ "$NO_PROMPT" -eq 1 ]; then
        log "Skipping prompt for $name (--no-prompt)"
        return 0
    fi

    if [ "$name" = "codex-spark" ]; then
        log "Sending prompt via paste-buffer to $name (pane=$pane)"
        if send_prompt_via_paste_buffer "$pane"; then
            return 0
        fi
        log "ERROR: paste-buffer send failed for $name (pane=$pane)"
        return 1
    fi

    local nonce now rendered_prompt
    # 固定化回避用の1文字ノンスを毎回生成
    local charset="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    nonce=${charset:$((RANDOM % ${#charset})):1}
    # 送信プロンプトに現在時刻を埋める（ローカル時計。同期健全性は check_clock_drift で別途確認）
    now=$(date '+%Y-%m-%d %H:%M:%S')
    rendered_prompt="${prompt//\{\{NONCE\}\}/$nonce}"
    rendered_prompt="${rendered_prompt//\{\{NOW\}\}/$now}"

    log "Sending prompt to $name (nonce=$nonce, now=$now)"
    tmux send-keys -t "$pane" "$rendered_prompt"
    sleep 1
    tmux send-keys -t "$pane" Enter
}

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

# ローカル時計のズレを1回だけ確認（warning のみ、処理は止めない）
check_clock_drift

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
    # マウスで pane 選択・リサイズ・スクロールできるようにする（この session 限定）
    tmux set-option -t "$TMUX_SESSION" mouse on
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

overall_rc=0
for tool in "${TOOLS[@]}"; do
    pane_id=$(cat "$STATE_DIR/$tool.pane")
    launch_and_send \
        "$tool" \
        "$pane_id" \
        "${TOOL_cmdline[$tool]}" \
        "${TOOL_prompt[$tool]}" \
        "${TOOL_wait_max[$tool]}" \
        "${TOOL_ready_pattern[$tool]}" \
        "${TOOL_workdir[$tool]}" || overall_rc=1
done

log "Done"
exit "$overall_rc"
