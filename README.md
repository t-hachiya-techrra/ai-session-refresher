# AI Session Refresher

定時に tmux 上で Claude Code / Codex CLI を起動し、軽量プロンプトを投入することで
**制限ウィンドウの開始タイミングを固定する**ツール。

## ファイル構成

```
ai-session-refresher/
├── config.sh               # 設定（gitignore 対象・各自で作成）
├── config.sh.example       # 設定テンプレート（コミット対象）
├── scripts/
│   ├── refresh.sh          # メインスクリプト（cron から呼ぶ）
│   ├── check-session.sh    # tmux セッション・pane 状態確認
│   └── lib.sh              # 共通ヘルパ
├── prompts/
│   ├── claude.txt                  # Claude 用軽量プロンプト
│   ├── codex.txt                   # Codex 用軽量プロンプト
│   └── codex-spark.txt             # codex-spark 用軽量プロンプト
└── README.md
```

## プロンプトのテンプレート変数

`prompts/*.txt` 内で以下のトークンを使える。`refresh.sh` が送信直前に実値へ置換する。

- `{{NONCE}}` — 毎回ランダムな1文字。応答の固定化（キャッシュ的な同一応答）を回避する。
- `{{NOW}}` — 送信時の現在時刻 `YYYY-MM-DD HH:MM:SS`。スクリプト側でローカル時計（`date`）から生成して埋め込む（AI は実時刻を知らないため）。ローカル時計が NTP 同期されていれば ms 精度で、HTTP 由来の時刻より精密。

## 時計ドリフト検知（canary）

`{{NOW}}` はローカル時計を使うが、その時計が NTP 同期から外れて狂っていないかを `refresh.sh` 実行ごとに1回だけ確認する。

- 外部サーバの HTTP `Date` ヘッダ（既定 Google / Cloudflare）とローカル時計を比較。
- 差が `CLOCK_DRIFT_WARN_SEC`（既定 5 秒）を超えたら warning をログに出す。**処理は止めない。** warning が出たら `timedatectl` で NTP 同期状態を確認する。
- 外部時刻を取得できない（ネットワーク不通等）場合はスキップ。
- HTTP `Date` は秒粒度＋片道遅延があるため精度は ±1 秒程度。あくまで「分・時間単位の狂い」を検知する canary であり、精密な時刻同期ではない。
- `config.sh` で `CLOCK_DRIFT_WARN_SEC` と比較元 `TIME_SOURCE_URLS` を上書きできる。

例（`prompts/claude.txt`）:

```
[{{NOW}}] reply with only {{NONCE}}.
```

## セットアップ

### 1. config.sh を作成

```bash
cp config.sh.example config.sh
```

`TOOL_cmdline` の Node バージョン部分を実際の環境に合わせて編集する（`which codex` で確認）。ツールを増減するには `TOOLS` 配列の要素を追加・削除し、対応する `TOOL_*[name]` エントリを追記・削除するだけでよい。

### 2. 実行権限付与

```bash
chmod +x scripts/refresh.sh scripts/check-session.sh scripts/lib.sh
```

### 3. 初回手動テスト

```bash
bash scripts/refresh.sh          # 手動実行
tmux attach -t ai-work           # pane 確認
bash scripts/check-session.sh   # 状態確認
```

Claude Code の初回起動時はテーマ選択ダイアログが出る場合があるため、
事前に一度手動で `claude` を起動して初期設定を完了させておくこと。

### 4. crontab 設定

> `<USER>` は自分のユーザー名（`whoami` で確認）に置換すること。以降の logrotate・linger 設定でも同様。

```bash
crontab -e
```

以下を追記：

```cron
MAILTO=""
LANG=ja_JP.UTF-8
# 毎日 6:00, 11:00, 16:00 に実行
0 6,11,16 * * * /home/<USER>/repos/ai-session-refresher/scripts/refresh.sh
```

`LANG=ja_JP.UTF-8` は UTF-8 罫線 `╭─` のマッチングを安定させるため設定。

### 5. logrotate 設定（オプション）

`/etc/logrotate.d/ai-session-refresher` を作成：

```
/home/<USER>/.local/log/ai-session-refresher.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    copytruncate
}
```

### 6. systemd-linger（オプション）

SSH ログアウト後も tmux セッション内のプロセスを生かし続けたい場合のみ実行：

```bash
loginctl enable-linger <USER>
```

## 手動起動（プロンプトを流さない）

セッションと各ツールだけ起動し、nonce プロンプトの送信はしたくない場合：

```bash
bash scripts/refresh.sh --no-prompt
```

- session / pane 作成、pane ID 保存、ツール（claude/codex/...）起動までは通常どおり行う。
- 各 pane へのプロンプト送信（`{{NOW}}` / `{{NONCE}}` 入り）だけスキップする。
- pane ID は保存されるので、次回 cron の通常実行はこのセッションをそのまま再利用する。
- 時計ドリフト検知（canary）は通常どおり1回走る。

## マウス操作

`ai-work` セッションは作成時に `mouse on` を有効化するため、`tmux attach -t ai-work` 後にマウスで pane の選択・リサイズ・スクロールができる（この session 限定。コピー時は端末によって `Shift`+ドラッグが必要）。

## リセット手順

pane が壊れた・状態が乱れた場合：

```bash
tmux kill-session -t ai-work
rm -f ~/.cache/ai-session-refresher/*.pane
```

## 検証手順

1. `tmux kill-session -t ai-work` で初期化
2. `bash scripts/refresh.sh` を手動実行 → ログ確認
3. `tmux attach -t ai-work` で全 pane に各ツールが起動しプロンプトが入力されているか確認
4. `tmux capture-pane -t <pane_id> -p` で起動画面をキャプチャし、ready パターンが実物にマッチするか確認
5. 同じスクリプトをもう1度実行し、busy 判定で skip されることを確認
6. crontab 登録後、次の発火タイミングでログを再確認
