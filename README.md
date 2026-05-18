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
│   ├── claude.txt          # Claude 用軽量プロンプト
│   └── codex.txt           # Codex 用軽量プロンプト
└── README.md
```

## セットアップ

### 1. config.sh を作成

```bash
cp config.sh.example config.sh
```

`CODEX_CMD` の Node バージョン部分を実際の環境に合わせて編集する（`which codex` で確認）。

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

## リセット手順

pane が壊れた・状態が乱れた場合：

```bash
tmux kill-session -t ai-work
rm -f ~/.cache/ai-session-refresher/*.pane
```

## 検証手順

1. `tmux kill-session -t ai-work` で初期化
2. `bash scripts/refresh.sh` を手動実行 → ログ確認
3. `tmux attach -t ai-work` で両 pane に各ツールが起動しプロンプトが入力されているか確認
4. `tmux capture-pane -t <pane_id> -p` で起動画面をキャプチャし、ready パターンが実物にマッチするか確認
5. 同じスクリプトをもう1度実行し、busy 判定で skip されることを確認
6. crontab 登録後、次の発火タイミングでログを再確認
