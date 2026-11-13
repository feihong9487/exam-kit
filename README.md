# exam-kit

上機考用的解題環境：`fb.sh`（編譯、跑測資、產生給 AI 的回報）＋ `packs.txt`（30 個情境包）。

安裝（會建立 `~/work` 並自我檢查）：

```bash
curl -sL https://raw.githubusercontent.com/feihong9487/exam-kit/main/setup.sh | bash
```

每一題：

```bash
mkdir -p ~/work/p1 && cd ~/work/p1 && alias fb=~/work/fb.sh && set -o ignoreeof
fb
```

之後每一輪：`fb` → 貼上（題目或 AI 的整段回覆）→ Enter → Ctrl-D → 把輸出整段貼到 AI 新對話。

其他指令：

| 指令 | 用途 |
| --- | --- |
| `fb task` | 任務模式：不是寫程式的題目（ros2 觀察、Makefile、git 衝突、在專案裡找要改哪裡）；AI 給檔案與指令，確認後照做 |
| `fb submit` | 交卷：把通過的程式放進 GitLab 作答專案，commit＋push（第一次會問網址與檔名） |
| `fb ci` | GitLab CI 沒過：貼上 job log，產生給 AI 的修正任務 |
| `fb test` | 不貼東西，直接重跑目前的程式 |
| `fb reset` | 這一題重來（舊檔搬到 `.fb_old/`，考場原檔從 `.fb_bak/` 還原） |
| `fb pack S06` | 指定情境包 |
| `fb mode std｜ros｜proj` | 題型判斷錯時手動切換 |
| `fb io argv｜in 檔名｜out 檔名｜std` | 題目不是 stdin／stdout 時 |
| `fb skip` | 略過對拍 |
| `fb selfcheck` | 檢查環境 |
