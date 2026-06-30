#!/usr/bin/env bash
# 共通ヘルパ

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }

# 現在時刻を外部サーバ（HTTP Date ヘッダ）から取得し、ローカルTZの表示形式で stdout に出す。
# ローカル時計を信用せず、NTP 同期された外部サーバの時刻を使うのが目的。
# 取得に失敗した場合はローカル時計へフォールバックし、戻り値 1 を返す（呼び出し側で warning 可能）。
fetch_network_now() {
    local fmt="${1:-%Y-%m-%d %H:%M:%S}"
    local url http_date
    local urls
    # config.sh で TIME_SOURCE_URLS 配列を定義すれば上書き可能。未定義なら既定値。
    if [ -n "${TIME_SOURCE_URLS+set}" ]; then
        urls=("${TIME_SOURCE_URLS[@]}")
    else
        urls=(https://www.google.com https://www.cloudflare.com)
    fi
    # 1段目で取れなければ次の候補へ。--max-time でハングを防ぐ。
    for url in "${urls[@]}"; do
        # curl 失敗や grep 不一致でパイプラインが非ゼロ終了しても set -e で止めない
        http_date=$(curl -sI --max-time 5 "$url" 2>/dev/null \
            | grep -i '^date:' | head -n1 | tr -d '\r' | sed 's/^[Dd]ate:[[:space:]]*//' || true)
        if [ -n "$http_date" ] && date -d "$http_date" "+$fmt" 2>/dev/null; then
            return 0
        fi
    done
    # フォールバック: ローカル時計
    date "+$fmt"
    return 1
}

# ローカル時計が外部サーバ時刻からどれだけズレているか1回だけ確認する canary。
# 表示や送信にはローカル時計を使う前提で、NTP 同期が壊れていないかを検知するのが目的。
# 閾値 (CLOCK_DRIFT_WARN_SEC, 既定5秒) を超えたら warning を出すだけで、処理は止めない。
# HTTP Date は秒粒度＋片道遅延があるため、閾値は誤検知しない程度に余裕を持たせる。
check_clock_drift() {
    local threshold="${CLOCK_DRIFT_WARN_SEC:-5}"
    local net_epoch local_epoch diff
    # 先に外部を取り、直後にローカルを取って計測窓を最小化する
    if ! net_epoch=$(fetch_network_now '%s'); then
        log "clock drift check: 外部時刻を取得できずスキップ (ローカル時計を使用)"
        return 0
    fi
    local_epoch=$(date '+%s')
    diff=$(( net_epoch - local_epoch ))
    diff=${diff#-}   # 絶対値
    if [ "$diff" -gt "$threshold" ]; then
        log "WARNING: ローカル時計が外部時刻と ${diff}s ズレている (local=$(date -d "@$local_epoch" '+%F %T'), network=$(date -d "@$net_epoch" '+%F %T'))。NTP 同期を確認: timedatectl"
    else
        log "clock drift check OK (diff=${diff}s, threshold=${threshold}s)"
    fi
}

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
