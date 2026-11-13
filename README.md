# exam-kit

上機考用的解題環境：`fb.sh`（編譯、跑測資、產生給 AI 的回報）＋ `packs.txt`（30 個情境包）。

安裝（會建立 `~/work` 並自我檢查）：

```bash
curl -sL https://raw.githubusercontent.com/feihong9487/exam-kit/main/setup.sh | bash
```

每一題：

```bash
mkdir -p ~/work/p1 && cd ~/work/p1 && alias fb=~/work/fb.sh
fb
```

之後每一輪：`fb` → 貼上（題目或 AI 的整段回覆）→ Enter → Ctrl-D → 把輸出整段貼到 AI 新對話。
