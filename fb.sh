#!/usr/bin/env bash
# fb.sh v5（考場版：一般題＋ROS 2 題）— 你當手腳、考場 AI 當大腦：每一輪都只做同一個動作。
#   ① 終端機打 ./fb.sh ，貼上「題目」或「AI 的整段回覆」，Enter 後按 Ctrl-D
#   ② 把終端機印出來的內容整段複製，到考場 AI「開新對話」貼上
#   ③ 把 AI 的整段回覆複製，回到 ①；直到出現「🎉 全部通過」
# 其他指令：./fb.sh selfcheck（檢查環境）
#          ./fb.sh submit（交卷：放進 GitLab 作答 repo 並 push）
#          ./fb.sh ci（GitLab CI 沒過：貼 job log 產生修正任務）
#          ./fb.sh reset（換下一題，清空這個資料夾的狀態）
#          ./fb.sh test（不貼東西，直接重跑目前的程式）
#          ./fb.sh pack S06（手動換情境包）
#          TO=1 ./fb.sh（效能題：每筆測資限時 1 秒）
# 需要同資料夾或 fb.sh 旁邊有 packs.txt（30 個情境包）。每一題建議用一個新資料夾。
SELF="$(readlink -f "$0")"; HERE="$(dirname "$SELF")"
PACKS="${PACKS:-$HERE/packs.txt}"; [ -f "$PACKS" ] || PACKS="./packs.txt"
if [ -z "$TO" ] && [ -f problem.txt ]; then   # 考生忘了 TO=1：題目寫「時間限制 1 秒」就自動用 1 秒
  TO=$(grep -oE '(時間限制|[Tt]ime [Ll]imit)[^0-9]{0,12}[0-9]+(\.[0-9]+)? ?(秒|s|sec)' problem.txt | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
fi
best_file_for() {   # AI 沒寫 // FILE: 時，用「區塊裡定義的函式名稱」找專案裡定義最多同名函式的 .c 檔
  local fns f best="" bs=0 s fn
  fns=$(grep -oE '^[A-Za-z_][A-Za-z0-9_ *]*[ *][A-Za-z_][A-Za-z0-9_]*[[:space:]]*[(]' "$1" | grep -oE '[A-Za-z_][A-Za-z0-9_]*[[:space:]]*[(]$' | tr -d '( ' | sort -u)
  for f in $(find . -maxdepth 2 -name '*.c' ! -path './.fb*'); do
    s=0; for fn in $fns; do grep -qE "^[A-Za-z_].*[ *]$fn[[:space:]]*[(]" "$f" && s=$((s+1)); done
    [ $s -gt $bs ] && { bs=$s; best=${f#./}; }
  done
  echo "$best"
}
pick_by_problem() {   # stdin 有好幾個路徑時挑一個：檔名等於 $1 > 資料夾名或檔名出現在題目（不含 fb 附加的檔案清單）> 第一個
  local first="" best="" p d b P
  P=$(sed '/^【專案裡的檔案】/,$d' problem.txt 2>/dev/null)
  while IFS= read -r p; do
    [ -z "$first" ] && first="$p"
    d=$(dirname "$p"); d=${d#./}; [ "$d" = . ] && d=""; b=$(basename "$p")
    if [ -n "$1" ] && [ "$b" = "$1" ]; then best="$p"; break; fi
    if [ -z "$best" ] && { { [ -n "$d" ] && [[ "$P" == *"$d"* ]]; } || { [ -n "$1" ] && [[ "$P" == *"$b"* ]]; }; }; then best="$p"; fi
  done
  echo "${best:-$first}"
}

if [ "$1" = "checkros" ]; then
  LIMIT=1800; VER="${VERIFY:-verify.sh}"; EXPF="${EXPECT:-expected.txt}"
  REP=$(mktemp); say() { printf '%s\n' "$*" >> "$REP"; }
  source /opt/ros/jazzy/setup.bash >/dev/null 2>&1 || { echo "❌ 找不到 ROS 2（/opt/ros/jazzy/setup.bash）"; exit 1; }
  export ROS_DOMAIN_ID=$(( RANDOM % 80 + 20 ))
  LIB=$(mktemp)
  cat > "$LIB" <<'FB_ROSLIB'
_f() { echo "${FBROS:-/tmp}/fbros_$(echo "$1" | tr '/' '_')"; }
grab() { timeout 12 ros2 topic echo "$1" > "$(_f "$1")" 2>&1 & GRAB_PIDS="$GRAB_PIDS $!"; sleep 2; }
send() { timeout 10 ros2 topic pub --once -w 1 "$1" "$2" "$3" > /dev/null 2>&1 || echo "（send $1 失敗：沒有節點訂閱 $1，或型別／YAML 寫錯）"; sleep 0.7; }
show() { sleep 1; for p in $GRAB_PIDS; do kill -INT "$p" 2>/dev/null; done; wait $GRAB_PIDS 2>/dev/null; GRAB_PIDS=""; echo "== $1 收到："; grep -vE '^---$|WARNING|does not appear' "$(_f "$1")" | head -40; }
call() { echo "== call $1："; timeout 12 ros2 service call "$1" "$2" "$3" 2>&1 | tail -3 | _yaml; }
_yaml() { python3 -c 'import re,sys
for l in sys.stdin:
    l = l.rstrip("\n"); print(l)
    m = re.match(r"^\s*[\w.]+\((.*)\)\s*$", l)
    if m:
        for k, v in re.findall(r"(\w+)=(\x27[^\x27]*\x27|\"[^\"]*\"|\[[^\]]*\]|[^,]+)", m.group(1)):
            print(k + ": " + v.strip().strip("\x27\""))
'; }   # 回應 Trigger_Response(success=True, message='x') 另外展開成 success: True／message: x（AI 寫的預期輸出常是這種格式）
FB_ROSLIB
  export FBROS=$(mktemp -d)   # 每次驗收用自己的暫存資料夾：兩個終端機同時跑 ROS 題也不會互相干擾
  say "【執行回報（ROS 2）】檔案：main.py"
  if ! python3 -m py_compile main.py 2> "$REP.err"; then
    say "結果：Python 語法錯誤"; head -n 8 "$REP.err" | cut -c1-160 >> "$REP"; ROSPASS=0
  else
    python3 main.py > node.log 2>&1 & NP=$!
    sleep 4
    if kill -0 "$NP" 2>/dev/null; then ALIVE=1; else ALIVE=0; fi
    say "--- 節點啟動 4 秒後的 ROS 圖 ---"
    say "節點：$(ros2 node list 2>/dev/null | tr '\n' ' ')"
    for t in $(ros2 topic list 2>/dev/null | grep -vE '^/(rosout|parameter_events)$'); do
      I=$(ros2 topic info "$t" 2>/dev/null)
      say "topic $t  型別=$(echo "$I" | sed -n 's/^Type: //p')  發佈者=$(echo "$I" | sed -n 's/^Publisher count: //p')  訂閱者=$(echo "$I" | sed -n 's/^Subscription count: //p')"
    done
    S2=$(ros2 service list 2>/dev/null | grep -vE '/(describe|get|list|set)_parameters|parameter_types|type_description' | tr '\n' ' ')
    [ -n "$S2" ] && say "service：$S2"
    if [ $ALIVE -eq 1 ] && [ -s "$VER" ]; then
      timeout 60 bash -c "source '$LIB'; source '$VER'" > verify.out 2>&1
      say "--- 驗收腳本輸出（前 25 行）---"; head -n 25 verify.out | cut -c1-160 >> "$REP"
      [ -s verify.out ] || say "⚠️ 驗收腳本什麼都沒印（沒有 show／call，或 show 的 topic 名稱打錯）→ 問題在【驗收腳本】，不一定在節點；請一起附上修正後的【驗收腳本】。"
    elif [ $ALIVE -eq 1 ]; then say "（沒有驗收腳本，只檢查節點有沒有正常啟動）"; : > verify.out; fi
    kill -INT "$NP" 2>/dev/null; sleep 2; kill -9 "$NP" 2>/dev/null
    ROSPASS=1
    [ $ALIVE -eq 0 ] && { say "❌ 節點啟動後就結束了（可能程式出錯或沒有 spin）"; ROSPASS=0; }
    if grep -q "Traceback" node.log; then
      say "❌ 節點有錯誤（Traceback；若是在 Ctrl-C 之後才出現，代表沒有處理 ExternalShutdownException）"; ROSPASS=0
    fi
    if [ -s "$EXPF" ] && [ $ALIVE -eq 1 ]; then
      # 每一行預期輸出要在驗收輸出裡「完整出現」：忽略引號與頭尾空白；開頭結尾是英數字時不能接著別的數字（data: 3.0 不會被 data: 3.05、13.0 當成有）
      MISS=$(python3 - "$EXPF" verify.out <<'FB_PYMATCH'
import re, sys
rd = lambda f: open(f, encoding="utf-8", errors="replace").read().splitlines()
q = lambda s: s.strip().replace("'", "").replace('"', "")
out = [q(l) for l in rd(sys.argv[2])]
for L in rd(sys.argv[1]):
    L2 = q(L)
    if not L2: continue
    pre = r"(?<![\w.\-])" if re.match(r"\w", L2[0]) else ""
    post = r"(?![\w.])" if re.match(r"\w", L2[-1]) else ""
    if not any(re.search(pre + re.escape(L2) + post, o) for o in out): print(L.strip())
FB_PYMATCH
)
      [ -n "$MISS" ] && MISS="$MISS"$'\n'
      say "--- 預期要看到的行 ---"; head -n 12 "$EXPF" | cut -c1-160 >> "$REP"
      if [ -n "$MISS" ]; then say "--- 驗收輸出裡缺少的行 ---"; printf '%s' "$MISS" | head -n 8 >> "$REP"; ROSPASS=0; fi
    fi
    if [ $ROSPASS -eq 0 ]; then say "--- 節點自己的輸出／錯誤（最後 15 行）---"; tail -n 15 node.log | cut -c1-160 >> "$REP"; fi
  fi
  if [ $ROSPASS -eq 1 ]; then say "測資：1 / 1 通過"; say "全部通過。"
  else say "測資：0 / 1 通過"; say "請找出原因並修正，給完整程式。如果你判斷是驗收腳本寫錯，可以另外附一個以「【驗收腳本】」開頭的 ${FENCE:-\`\`\`}bash 區塊。"; fi
  N=0
  if [ $ROSPASS -eq 0 ]; then
    SIG=$(grep -m3 -E '缺少|❌|Traceback|錯誤' "$REP" | md5sum | cut -c1-12)
    if [ "$SIG" = "$(cat .fb_sig 2>/dev/null)" ]; then N=$(( $(cat .fb_n 2>/dev/null || echo 0) + 1 )); fi
    echo "$SIG" > .fb_sig; echo "$N" > .fb_n
    if [ "$N" -ge 2 ]; then
      echo "【重寫任務】你是上機考解題助手。前一版 ROS 2 程式已經連續 $((N+1)) 次犯同一個錯，修補沒有用。不要沿用舊程式，依照題目從頭重新寫一個完整的 rclpy 程式（只給一個 ${FENCE:-\`\`\`}python 區塊，不要寫註解）。寫之前先用 3 行列出：要建立哪些 publisher／subscriber／service（名稱、型別），每個 callback 做什麼。"
    else
      echo "【修正任務】你是上機考解題助手（ROS 2 Jazzy，rclpy）。下面是題目、驗收腳本、預期輸出、目前的程式和執行回報。先用一句話說錯在哪、為什麼，再給修正後的完整程式（只給一個 ${FENCE:-\`\`\`}python 區塊，不要寫註解）。常見原因：topic 名稱或型別和題目不同、忘了 publish、callback 沒被呼叫、沒處理 ExternalShutdownException。"
    fi
    echo "【題目】"; cat problem.txt; echo
    [ -f pack.txt ] && { echo "【參考零件】（只是參考，和題目不同時以題目為準）"; cat pack.txt; echo; }
    [ -s "$VER" ] && { echo "【驗收腳本】（用 grab／send／show／call 指令）"; cat "$VER"; echo; }
    [ "$N" -lt 2 ] && { echo "【目前程式】"; echo '```python'; cat main.py; echo '```'; }
    [ "$N" -ge 2 ] && echo "【前一版的錯誤（不要再犯）】"
  else rm -f .fb_sig .fb_n; fi
  head -c $LIMIT "$REP"; echo
  rm -rf "$REP" "$REP.err" "$LIB" "$FBROS"; exit 0
fi

if [ "$1" != "check" ]; then
FENCE='```'
print_select() {
cat <<'FB_PSEL'
你是上機考解題助手。讀完下面的題目，照順序回答完就停，不要寫程式：
【需要情境】從索引挑 1 個最相關的編號（例：反組譯挑 S06、位元流挑 S03、多執行緒挑 S15、效能挑 S21）；完全無關寫「無」
接著把題目的每一組範例「一字不改」照抄成測資，每一組依序寫：
【範例輸入】
```
（照抄範例輸入）
```
【範例輸出】
```
（照抄範例輸出）
```
情境索引：
S01 位元欄位取出／填入／符號延伸
S02 位元重排／反轉／byte 交換
S03 位元流讀取（MSB／LSB-first 讀 n 位元）
S04 位元流寫入（打包欄位成 bytes）
S05 CRC-32／CRC-16／加總／同位元
S06 RISC-V 反組譯（hex→組語）
S07 RISC-V 組譯（組語→hex）
S08 RISC-V 迷你模擬器
S09 PIO 指令組譯／反組譯
S10 PIO 狀態機 PC 模擬器
S11 Pico SDK PIO C 端樣板
S12 Pico SDK DMA 樣板（複製／填值／CRC）
S13 演練 transfer engine API（claim／第五個請求）
S14 PIO＋DMA 位元流題解法
S15 多執行緒正確加總（mutex／atomic／區域累加）
S16 平行化迴圈＋加速比＋false sharing
S17 有限資源池（semaphore）
S18 生產者／消費者佇列
S19 計時與版本比較
S20 快速輸入輸出
S21 常見優化手法（迴圈順序、查表、-O2）
S22 Git 交卷與衝突
S23 Makefile＋測資比對
S24 ROS 2 publisher／subscriber 骨架
S25 ROS 2 service
S26 ROS 2 參數＋namespace 多機器人
S27 ROS 2 一鍵排查腳本
S28 ROS 2 多機器人派單
S29 ROS 2 統計＋QoS
S30 ROS 2 action 骨架
【題目】
FB_PSEL
cat problem.txt
}
print_select_ros() {
cat <<'FB_PSELR'
你是上機考解題助手（ROS 2 Jazzy，Python rclpy）。讀完下面的題目，照順序回答完就停，不要寫節點程式：
【需要情境】從這些挑 1 個最相關的：S24 publisher／subscriber、S25 service、S26 參數＋namespace、S28 多機器人派單、S29 統計＋QoS、S30 action
【驗收腳本】寫一個 bash 腳本，驗證「已經在背景執行中的節點」有沒有照題目運作，放在一個 ```bash 區塊。只能用下面四個現成指令，不要自己啟動或關閉節點，不要寫 sleep：
  grab /主題                     開始在背景收這個 topic 的訊息（一定要先 grab 再 send）
  send /主題 型別 '{欄位: 值}'      送一筆訊息，例：send /number std_msgs/msg/Int32 '{data: 5}'
  show /主題                     印出收到的每一筆訊息（例：data: 10）
  call /服務 型別 '{欄位: 值}'      呼叫 service，印出回應
【預期輸出】驗收腳本正確時，show／call 應該印出的關鍵行，每行一個（例：data: 15.0），放在一個 ``` 區塊。
【題目】
FB_PSELR
cat problem.txt
}
print_write_ros() {
cat <<'FB_PCODER'
你是上機考解題助手。根據下面的【題目】寫一個完整的 ROS 2 Jazzy Python（rclpy）程式，用 python3 main.py 直接執行（不打包）。
規則：1. topic／service 名稱、型別、欄位照題目；題目沒寫開頭斜線就用相對名稱。2. 需要多個節點時，在同一支程式用 MultiThreadedExecutor 一起 spin。3. 結尾一定要：try: rclpy.spin(node)（或 executor.spin()） except (KeyboardInterrupt, ExternalShutdownException): pass finally: rclpy.try_shutdown()，並 from rclpy.executors import ExternalShutdownException。4. 【參考零件】只是參考，和題目不同時以題目為準。5. 只輸出一個 ```python 程式碼區塊，程式裡不要寫註解，前面最多 2 行說明。
FB_PCODER
echo "【題目】"; cat problem.txt
[ -f pack.txt ] && { echo "【參考零件】"; cat pack.txt; }
}
print_write() {
if [ "$(cat .mode 2>/dev/null)" = proj ]; then
cat <<'FB_PCODEP'
你是上機考解題助手。這是一個多檔案 C 專案（用 make 編譯）。根據下面的【題目】與【專案檔案】，只修改題目要求的那一個檔案。
規則：1. 輸出「那一個檔案修改後的完整內容」，放在一個 ```c 程式碼區塊，區塊第一行寫 // FILE: 檔名（例：// FILE: ringbuf.c）。2. 不要改沒被要求的檔案；不要自己另寫 main（除非要改的就是 main.c）；#include、函式名稱與參數照原本的。3. 輸出格式逐字照題目範例。4. 程式裡不要寫註解，前面最多 2 行說明。
FB_PCODEP
echo "【題目】"; cat problem.txt
[ -f pack.txt ] && { echo "【參考零件】"; head -n 12 pack.txt; }
return
fi
cat <<'FB_PCODE'
你是上機考解題助手。根據下面的【題目】寫出完整、單一檔案、可直接編譯的 C 程式（gcc -O2 -Wall -pthread，#include 要齊全），從 stdin 讀、寫到 stdout。
規則：1. 輸出格式（空白、逗號、大小寫、換行）逐字照題目範例，不要多印任何文字。2. 【參考零件】只是參考，和題目不同時以題目為準。3. 數字、位元欄位、指令編碼不要心算，寫進程式。4. 有時間限制先估複雜度：N 到 10^5 以上要 O(N log N) 以下。題目附原始程式的，保留原本的輸入輸出與要求（例如必須用多執行緒）。5. 只輸出一個 ```c 程式碼區塊，程式裡不要寫註解（省長度），前面最多 2 行說明。
FB_PCODE
grep -qiE '(用|使用|以)[[:space:]]*python|python[[:space:]]*3?[[:space:]]*(撰寫|實作|作答|寫)|in python' problem.txt && echo "（這題指定用 Python 3：忽略上面「C 程式／gcc」的要求，改成只輸出一個完整的 ${FENCE}python 程式碼區塊，用 python3 main.py 執行，從 stdin 讀、寫到 stdout。）"
echo "【題目】"; cat problem.txt
[ -f .fb_io ] && echo "（注意：這題不是 stdin/stdout，照題目從命令列參數或檔案讀寫：$(paste -sd' ' .fb_io)）"
[ -f pack.txt ] && { echo "【參考零件】"; cat pack.txt; }
}
print_brute() {
cat <<'FB_PBRUTE'
你是上機考解題助手。另一位同學已經寫好這題的程式，題目範例都過了，但可能還有隱藏測資的錯誤。請寫兩個 Python 3 程式幫忙「對拍」（不要寫註解，不要解釋）：
【暴力解】用最直接、最慢但一定正確的方法解這題（完全不用管效率，例如逐位元、逐一枚舉），從 stdin 讀、照題目格式印到 stdout。放在第一個 ```python 區塊。
【產生器】用 random 隨機產生「一組小的」合法輸入印到 stdout（符合題目的輸入格式與限制，但規模很小，例如 N ≤ 6；數值一律只用很小的範圍，例如 -3～3 或 0～5（題目的邊界值例外），讓重複值、相等、剛好落在邊界的情況常常出現，也要常常出現題目提到的特殊情況）；執行時如果帶參數 big（sys.argv[1] == "big"），改印一組題目允許的「最大規模」輸入。放在第二個 ```python 區塊。
FB_PBRUTE
echo "【題目】"; cat problem.txt
}
tidy_s() { sed 's/[[:space:]]*$//' | awk '{a[NR]=$0} END{e=NR; while (e>0 && a[e]=="") e--; for (i=1;i<=e;i++) print a[i]}'; }
stress_run() {   # 回傳 0=沒找到反例  1=找到反例（寫進 tests/s<k>）  2=暴力解不可信  3=最大規模逾時
  local X="python3 main.py" i=0 k S f RC
  if [ -f main.c ]; then gcc -O2 -pthread -o .fb_main main.c -lm 2>/dev/null || return 0; X=./.fb_main; fi
  for f in tests/*.in; do [ -f "${f%.in}.out" ] || continue
    timeout 5 python3 brute.py < "$f" 2>/dev/null | tidy_s > .fb_b; tidy_s < "${f%.in}.out" > .fb_e
    cmp -s .fb_b .fb_e || { echo "⚠️ 暴力解連範例 $(basename "$f") 都不對，不採用對拍（照樣算通過）" >&2; return 2; }
  done
  S=$(date +%s)
  for i in $(seq 1 300); do
    [ $(( $(date +%s) - S )) -ge "${STRESS_SEC:-20}" ] && break
    timeout 5 python3 gen.py > .fb_r.in 2>/dev/null || continue; [ -s .fb_r.in ] || continue
    timeout 5 python3 brute.py < .fb_r.in > .fb_r.exp 2>/dev/null || continue
    timeout "${TO:-5}" $X < .fb_r.in > .fb_r.got 2>/dev/null; RC=$?
    if [ $RC -ne 0 ] || ! cmp -s <(tidy_s < .fb_r.got) <(tidy_s < .fb_r.exp); then
      k=$(( $(ls tests/s*.in 2>/dev/null | wc -l) + 1 )); cp .fb_r.in "tests/s$k.in"; cp .fb_r.exp "tests/s$k.out"
      echo "🔎 對拍第 $i 組隨機測資找到反例，已存成 tests/s$k.in／.out" >&2; return 1
    fi
  done
  echo "✅ 對拍 $i 組隨機小測資都和暴力解一致" >&2
  if timeout 20 python3 gen.py big > .fb_big.in 2>/dev/null && [ "$(wc -c < .fb_big.in)" -gt 20000 ]; then
    timeout "${TO:-5}" $X < .fb_big.in > /dev/null 2>&1; RC=$?
    [ $RC -eq 124 ] && { echo "⏱️ 最大規模輸入（$(wc -c < .fb_big.in) bytes）超過 ${TO:-5} 秒" >&2; return 3; }
    echo "✅ 最大規模輸入（$(wc -c < .fb_big.in) bytes）在 ${TO:-5} 秒內跑完" >&2
  fi
  return 0
}
stress_after() {   # $1=stress_run 的結果；$2=程式檔
  case "$1" in
    1) echo fix > .stage; echo "❌ 對拍找到範例沒抓到的錯誤。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
       echo "（注意：名稱是 s 開頭的測資是隨機產生的，預期輸出來自另一個確定正確的暴力解，請相信它，照它修正。）"
       bash "$SELF" check "$2" ;;
    3) echo fix > .stage; echo "❌ 範例都對，但最大規模輸入逾時。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
       echo "【修正任務】你是上機考解題助手。下面的程式答案正確，但題目允許的最大規模輸入執行超過 ${TO:-5} 秒被中止（太慢）。請先用一句話說目前的時間複雜度，再改用更快的演算法（N 到 10^5 以上要 O(N log N) 以下；輸入輸出用 scanf／printf，大量輸出不要每行 fflush），輸入輸出格式不變，給完整程式（只給一個程式碼區塊，不要註解）。"
       echo "【題目】"; cat problem.txt; echo; echo "【目前程式】"; echo '```'; cat "$2"; echo '```' ;;
    *) touch .fb_stress_ok; echo done > .stage
       echo "🎉 全部通過（含對拍）！交卷：直接打 fb submit（第一次會問作答專案的網址和檔名）。下一題：fb reset" >&2 ;;
  esac
}
get_pack() {   # 從 packs.txt 取出某個情境包
  [ -f "$PACKS" ] || { echo "⚠️ 找不到 packs.txt，這次不附情境包" >&2; return 1; }
  awk -v id="$1" '/^@@@ /{p=($2==id); next} p' "$PACKS" > pack.tmp
  if [ -s pack.tmp ]; then mv pack.tmp pack.txt; return 0; else rm -f pack.tmp; return 1; fi
}
split_blocks() {   # 把貼上的回覆拆成程式碼區塊：$1/b<n>.lang .info .prev .tag .body；沒收尾的區塊記在 $1/unclosed
  awk -v D="$1" '
    BEGIN { n=0; inb=0; tag=""; prev="" }
    { line=$0; sub(/\r$/, "", line) }
    !inb && line !~ /^[ \t]*```/ && line ~ /```[A-Za-z+]*[ \t]*$/ { p=index(line, "```"); prev=substr(line, 1, p-1); line=substr(line, p) }   # 「錯在哪一行：```c」：行中間開的區塊
    inb && line ~ /^[ \t]*```[A-Za-z]/ { inb=0; close(D "/b" n ".body") }   # 區塊裡又遇到 ```c：前一個區塊是誤開的，直接改開新區塊
    !inb && line ~ /^[ \t]*```/ { inb=1; n++; info=line; sub(/^[ \t]*```[ \t]*/, "", info)
        ind=match(line, /```/)-1                      # 區塊在清單裡縮排時，內文也一起去掉同樣的縮排（Python 才不會 IndentationError）
        lang=info; sub(/[ \t{].*$/, "", lang)         # 只取資訊字串的第一個字：```c title="main.c" → c
        print lang > (D "/b" n ".lang"); close(D "/b" n ".lang")
        print info > (D "/b" n ".info"); close(D "/b" n ".info")
        print prev > (D "/b" n ".prev"); close(D "/b" n ".prev")
        print tag  > (D "/b" n ".tag");  close(D "/b" n ".tag")
        printf "" > (D "/b" n ".body"); tag=""; next }
    inb && line ~ /^[ \t]*```[ \t]*$/ { inb=0; close(D "/b" n ".body"); next }
    inb { if (ind > 0 && substr(line, 1, ind) ~ /^[ \t]*$/) line=substr(line, ind+1); print line >> (D "/b" n ".body"); next }
    line ~ /[^ \t]/ { prev=line }
    line ~ /範例輸入|輸入範例/ { tag="in" }
    line ~ /範例輸出|輸出範例|預期輸出/ { tag="out" }
    line ~ /驗收/ { tag="verify" }
    END { print n > (D "/count"); if (inb) print n > (D "/unclosed") }' "$1/in.txt"
}
fix_verify() {   # 驗收腳本有 grab 卻沒有 show（小模型常忘）→ 自動補在最後，否則永遠「缺少的行」
  [ -s verify.sh ] || return 0
  # 把 service 當 topic 用（send /x pkg/srv/T …）→ 改成 call，並刪掉對同名稱的 grab／show
  for s in $(awk '$1=="send" && $3 ~ /\/srv\// {print $2}' verify.sh | sort -u); do
    awk -v s="$s" '($1=="grab" || $1=="show") && $2==s {next} $1=="send" && $2==s {sub(/send/, "call")} {print}' verify.sh > verify.sh.t && mv verify.sh.t verify.sh
    echo "（驗收腳本把 service $s 當成 topic 用 send，已改成 call）" >&2
  done
  for t in $(grep -oE '^[[:space:]]*grab[[:space:]]+[^[:space:]]+' verify.sh | awk '{print $2}'); do
    grep -qE "^[[:space:]]*show[[:space:]]+$t([[:space:]]|\$)" verify.sh || { echo "show $t" >> verify.sh; echo "（驗收腳本 grab 了 $t 卻沒有 show，已自動補上 show $t）" >&2; }
  done
}
trim_blank() { awk '{a[NR]=$0} END{s=1; while (s<=NR && a[s] ~ /^[ \t\r]*$/) s++; e=NR; while (e>=s && a[e] ~ /^[ \t\r]*$/) e--; for (i=s; i<=e; i++) print a[i]}'; }
extract_samples() {   # 不靠 AI：直接從 problem.txt 抓「範例輸入／範例輸出」→ $1/<k>.in .out，印出組數
  rm -rf "$1"; mkdir -p "$1"
  awk -v D="$1" '
    function rest(s,  p) { p = index(s, "："); if (p) return substr(s, p + length("：")); p = index(s, ":"); return p ? substr(s, p + 1) : "" }
    { line=$0; sub(/\r$/, "", line) }
    line ~ /^[ \t]*```/ { infence=!infence; next }
    !infence && line ~ /(範例|樣例|[Ss]ample)[ \t]*(輸入|[Ii]nput)|輸入範例/ { md="in"; ki++; f=D "/" ki ".in"; printf "" > f
        r=rest(line); sub(/^[ \t]+/, "", r); if (r != "") print r >> f; next }
    !infence && line ~ /(範例|樣例|[Ss]ample)[ \t]*(輸出|[Oo]utput)|輸出範例/ { md="out"; ko++; f=D "/" ko ".out"; printf "" > f
        r=rest(line); sub(/^[ \t]+/, "", r); got=0; if (r != "") { print r >> f; got=1 }; next }
    !infence && line ~ /^[ \t]*(說明|解釋|提示|限制|注意|備註|輸入格式|輸出格式|Explanation|Note|【)/ { md=""; next }
    md == "out" && !infence && line ~ /^[ \t]*$/ && got { md=""; next }   # 輸出後面的空白行＝範例結束
    md != "" { print line >> f; if (line ~ /[^ \t]/) got=1 }
    END { k = ki < ko ? ki : ko; print k > (D "/count") }' problem.txt
  for f in "$1"/*.in "$1"/*.out; do [ -f "$f" ] && { trim_blank < "$f" > "$f.t"; mv "$f.t" "$f"; }; done
  cat "$1/count"
}
norm() { tr -d ' \t\r\n' ; }

case "$1" in
  selfcheck)
         ok=1
         for t in gcc python3 awk timeout base64; do command -v "$t" >/dev/null 2>&1 || { echo "❌ 缺少 $t"; ok=0; }; done
         n=$(grep -c '^@@@ S' "$PACKS" 2>/dev/null || echo 0)
         [ "$n" -ge 30 ] && echo "✅ 情境包：$n 個（$PACKS）" || { echo "❌ 情境包只有 $n 個（應為 30）"; ok=0; }
         T=$(mktemp -d); printf '#include <stdio.h>\nint main(void){int a,b;if(scanf("%%d %%d",&a,&b)!=2)return 0;printf("%%d\\n",a+b);return 0;}\n' > "$T/main.c"
         mkdir -p "$T/tests"; echo "1 2" > "$T/tests/1.in"; echo "3" > "$T/tests/1.out"
         (cd "$T" && bash "$SELF" check main.c) | grep -q '全部通過' && echo "✅ 編譯＋測資比對正常" || { echo "❌ 編譯／測資比對失敗"; ok=0; }
         rm -rf "$T"
         if [ -f /opt/ros/jazzy/setup.bash ]; then echo "✅ ROS 2 Jazzy 可用（ROS 題可自動驗收）"; else echo "ℹ️ 這個環境沒有 ROS 2 Jazzy（遇到 ROS 題時，要在有 ROS 的終端機裡用 fb）"; fi
         [ $ok -eq 1 ] && echo "🎉 環境全部正常" || echo "⚠️ 有項目失敗，請看上面的 ❌"
         exit 0 ;;
  submit)  # 交卷：把通過的程式放進 GitLab 作答 repo → commit → push（fb submit [repo資料夾] [檔名]）
         SRC=""; for f in main.c main.cpp main.py; do [ -f "$f" ] && { SRC=$f; break; }; done
         [ "$(cat .mode 2>/dev/null)" = proj ] && [ -s .fb_target ] && SRC=$(cat .fb_target)
         [ -n "$SRC" ] || { echo "❌ 這個資料夾還沒有程式。先 cd 到那一題的資料夾（例如 cd ~/work/p1）再打 fb submit"; exit 1; }
         [ "$(cat .stage 2>/dev/null)" = done ] || echo "⚠️ 這題在本機還沒出現 🎉；照樣交出去，但 CI 可能不會過。"
         if ! command -v git >/dev/null 2>&1; then
           echo "❌ 這個終端機沒有 git（可能是在容器裡）。兩個辦法擇一："
           echo "   1) 到有 git 的終端機（考場電腦本身的終端機），照 Notion 步驟 5-3 手動交；要交的檔案是：$(pwd)/$SRC"
           echo "   2) 不用 git：GitLab 網頁打開那一題的專案 → 點題目規定的檔案 → Edit（或 Web IDE）→ 全選刪掉 → 貼上下面的程式 → Commit changes"
           echo "----- 下面是程式內容（從下一行複製到「-----」之前）-----"; cat "$SRC"; echo "-----"
           exit 1
         fi
         [ -n "$(git config --global user.name)" ] || git config --global user.name "student"
         [ -n "$(git config --global user.email)" ] || git config --global user.email "student@example.com"
         [ -n "$(git config --global credential.helper)" ] || git config --global credential.helper 'cache --timeout=36000'
         TOP=$(git rev-parse --show-toplevel 2>/dev/null)
         if [ -n "$TOP" ]; then R="$TOP"; D=$(realpath --relative-to="$TOP" "$SRC")   # fb 就在作答 repo 裡用：直接交這個檔
         else
           R="${2:-$(cat .fb_repo 2>/dev/null)}"
           if [ -z "$R" ] || [ ! -d "$R/.git" ]; then
             mapfile -t RS < <(find "$HOME" -maxdepth 3 -name .git -type d ! -path "$HOME/work/*" 2>/dev/null | sed 's#/\.git$##' | sort)
             echo "要交到哪一個 GitLab 作答資料夾？"
             i=0; for r in "${RS[@]}"; do i=$((i+1)); echo "  $i) $r"; done
             echo "  0) 還沒有／都不是 → 貼 GitLab 的 Clone with HTTP 網址，幫你 clone 一份"
             if [ ${#RS[@]} -gt 0 ]; then read -r -p "輸入編號後按 Enter（直接 Enter = 1）：" k </dev/tty; k=${k:-1}; else k=0; fi
             if [ "$k" = 0 ]; then
               read -r -p "貼上 Clone with HTTP 網址後按 Enter：" U </dev/tty; U=$(echo "$U" | tr -d ' \r')
               [ -n "$U" ] || { echo "❌ 沒有網址"; exit 1; }
               R="$HOME/$(basename "$U" .git)"
               [ -d "$R/.git" ] || git clone "$U" "$R" || { echo "❌ clone 失敗：網址或帳號密碼錯了？再打一次 fb submit"; exit 1; }
             else R="${RS[$((k-1))]}"; [ -n "$R" ] || { echo "❌ 沒有這個編號"; exit 1; }; fi
           fi
           echo "$R" > .fb_repo
           D="${3:-$(cat .fb_dest 2>/dev/null)}"
           if [ -z "$D" ]; then
             EXT="${SRC##*.}"; mapfile -t FS < <(cd "$R" && git ls-files | grep -E "\.$EXT\$")
             if [ ${#FS[@]} -gt 0 ]; then
               echo "repo 裡的 .$EXT 檔："; i=0; for f in "${FS[@]}"; do i=$((i+1)); echo "  $i) $f"; done
               echo "  0) 都不是 → 自己輸入檔名"
               read -r -p "程式要放到哪一個？（輸入編號，直接 Enter = 1）：" k </dev/tty; k=${k:-1}
               if [ "$k" = 0 ]; then read -r -p "輸入檔名（可含資料夾，例如 q1/main.c）：" D </dev/tty; else D="${FS[$((k-1))]}"; fi
             else
               read -r -p "存成什麼檔名？（照題目規定；題目沒規定就直接 Enter = $(basename "$SRC")）：" D </dev/tty; D=${D:-$(basename "$SRC")}
             fi
           fi
           [ -n "$D" ] || { echo "❌ 沒有檔名"; exit 1; }
           echo "$D" > .fb_dest
           mkdir -p "$R/$(dirname "$D")" && cp "$SRC" "$R/$D" || { echo "❌ 複製失敗"; exit 1; }
         fi
         cd "$R" || exit 1
         git add -u; git add -- "$D"
         if git diff --cached --quiet; then echo "ℹ️ 內容和上次交的一樣（沒有新的變更），直接再推一次"
         else git commit -q -m "submit $(date +%H:%M)" || { echo "❌ commit 失敗"; exit 1; }; fi
         git push || { echo "（被拒絕，先把 GitLab 上的新變更拉下來再推）"; git pull --no-rebase --no-edit && git push; } || { echo "❌ push 失敗：帳號密碼錯，或網路不通。再打一次 fb submit"; exit 1; }
         echo "✅ 已交出：$R/$D"
         echo "👉 回 GitLab 網頁，專案首頁按 F5，看最新 commit 右邊的小圓圈："
         echo "   🔵 轉圈＝還在評分（等幾秒再 F5）　✅ 綠勾＝通過　❌ 紅叉＝沒過"
         echo "   ❌ 時：點 commit 標題 → 「Pipeline #編號」→ 紅色的 job → log 右上角的「Show complete raw」(📄) → Ctrl+A、Ctrl+C → 回終端機打 fb ci 貼上"
         exit 0 ;;
  ci)    # CI（GitLab 自動評分）沒過：貼 job log → 產生修正任務
         [ -f problem.txt ] || { echo "❌ 這個資料夾沒有題目。先 cd 到那一題的資料夾（例如 cd ~/work/p1）再打 fb ci"; exit 1; }
         SRC=""; for f in main.c main.cpp main.py; do [ -f "$f" ] && { SRC=$f; break; }; done
         [ "$(cat .mode 2>/dev/null)" = proj ] && [ -s .fb_target ] && SRC=$(cat .fb_target)
         [ -n "$SRC" ] || { echo "❌ 還沒有程式"; exit 1; }
         echo "👉 請貼上【GitLab job 的 log】，貼完按 Enter，再按 Ctrl-D" >&2
         if [ -t 0 ] && trap "stty icanon 2>/dev/null" EXIT INT && stty -icanon 2>/dev/null; then
           IFS= read -r -d "$(printf '\004')" IN; stty icanon 2>/dev/null; echo >&2
         else IN=$(cat); fi
         [ -n "$IN" ] || { echo "沒有貼到任何東西" >&2; exit 1; }
         LOG=$(printf '%s\n' "$IN" | sed -E 's/section_(start|end):[0-9]+:[A-Za-z0-9_]+(\[[^]]*\])?\r//g' | tr -d '\r' | sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g; s/section_(start|end):[0-9]+:[A-Za-z0-9_]+(\[[^]]*\])?//g; s/^[0-9]{4}-[0-9-]+T[0-9:.]+Z [0-9]+[OE]\+? ?//; s/^[[:space:]]*[0-9]+[[:space:]]+[0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]]*//' \
           | grep -vE 'gitlab-runner|[Dd]ocker executor|pull policy|[Pp]ulling docker|Using docker image|^Preparing|Running on runner|Getting source|Gitaly|Fetching changes|Reinitialized|Created fresh|Checking out|Skipping Git|Cleaning up|Log timestamps|Search visible|^[[:space:]]*$' | tail -n 40 | cut -c1-200)
         CMDS=$(printf '%s\n' "$LOG" | grep -E '^\$ ' | head -8)
         [ -n "$CMDS" ] && { echo "ℹ️ CI 執行的指令（檔名要對得上）：" >&2; printf '%s\n' "$CMDS" | sed 's/^/   /' >&2; }
         echo fix > .stage; rm -f .fb_sig .fb_n
         LT=c; case "$SRC" in *.py) LT=python ;; *.cpp) LT=cpp ;; esac
         echo "✅ 已讀 CI 的 log（留最後 $(printf '%s\n' "$LOG" | grep -c .) 行重點）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
         echo "【修正任務】你是上機考解題助手。這個程式在本機的範例測資都通過了，但交到 GitLab 後自動評分（CI）沒有過。下面是題目、目前的程式和 CI 的 log。先用兩句話說 CI 為什麼沒過（常見：隱藏測資的邊界情況、輸出多印或少印、太慢超時、編譯警告被當成錯誤、檔名或讀檔方式和題目不同、Python 版本），再給修正後的完整程式（只給一個程式碼區塊，程式裡不要寫註解）。輸出格式逐字照題目範例；不要心算。"
         echo "【題目】"; cat problem.txt; echo
         [ -f pack.txt ] && { echo "【參考零件】（只是參考；只附前 12 行）"; head -n 12 pack.txt; echo; }
         echo "【目前程式】"; echo "${FENCE}$LT"; cat "$SRC"; echo "$FENCE"
         echo "【CI 的 log（重點，最後 40 行）】"; echo "${FENCE}text"; printf '%s\n' "$LOG"; echo "$FENCE"
         exit 0 ;;
  reset) B=".fb_old/$(date +%m%d_%H%M%S)"; mkdir -p "$B"   # 不直接刪：搬到 .fb_old/，考場原本的檔案從 .fb_bak/ 還原
         for f in .stage .sid .mode .pack_manual .fb_io .fb_target .fb_prog .fb_stamp .fb_stress_ok .fb_main brute.py gen.py problem.txt pack.txt main.c main.cpp main.py .fb_sig .fb_n tests verify.sh expected.txt node.log verify.out; do
           [ -e "$f" ] && mv "$f" "$B/"; done
         if [ -d .fb_bak ]; then cp -r .fb_bak/. . && echo "（已還原考場原本的檔案：$(ls -A .fb_bak | tr '\n' ' ')）"; rm -rf .fb_bak; fi
         echo "已清空（舊檔在 $B）。開始新的一題：fb 然後貼上題目"; exit 0 ;;
  test)  [ "$(cat .mode 2>/dev/null)" = ros ] && exec bash "$SELF" checkros
         [ "$(cat .mode 2>/dev/null)" = proj ] && [ -s .fb_target ] && PROJ=1 exec bash "$SELF" check "$(cat .fb_target)"
         for f in main.c main.cpp main.py; do [ -f "$f" ] && exec bash "$SELF" check "$f"; done
         echo "還沒有程式"; exit 1 ;;
  pack)  get_pack "$2" && { echo "$2" > .pack_manual; echo "已換成情境 $2（之後每一輪都會附這個包，不會被 AI 選的蓋掉）"; } || echo "packs.txt 裡沒有 $2"; exit 0 ;;
  skip)  [ "$(cat .stage 2>/dev/null)" = brute ] && { echo done > .stage; echo "已略過對拍，這題算完成。下一題：fb reset"; } || echo "現在不在對拍階段"; exit 0 ;;
  io)    case "$2" in   # 題目不是 stdin/stdout：fb io argv（檔名當命令列參數）／fb io in input.txt（從檔案讀）／fb io out output.txt（寫到檔案）／fb io std（還原）
           argv) grep -v '^IO_ARGV=' .fb_io 2>/dev/null > .fb_io.t; echo "IO_ARGV=1" >> .fb_io.t; mv .fb_io.t .fb_io ;;
           in)   grep -v '^IO_IN=' .fb_io 2>/dev/null > .fb_io.t; echo "IO_IN=${3:-input.txt}" >> .fb_io.t; mv .fb_io.t .fb_io ;;
           out)  grep -v '^IO_OUT=' .fb_io 2>/dev/null > .fb_io.t; echo "IO_OUT=${3:-output.txt}" >> .fb_io.t; mv .fb_io.t .fb_io ;;
           *)    rm -f .fb_io ;;
         esac
         echo "測資的輸入輸出方式：$(tr '\n' ' ' < .fb_io 2>/dev/null)$( [ -f .fb_io ] || echo 'stdin → stdout')"; exit 0 ;;
  mode)  case "$2" in std|ros|proj) echo "$2" > .mode; echo "已改成題型：$2" >&2 ;; *) echo "用法：fb mode std（一般）｜ros（ROS 2）｜proj（多檔案專案＋Makefile）"; exit 1 ;; esac
         if [ "$(cat .stage 2>/dev/null)" = select ]; then
           echo "把下面整段複製，到 AI 開新對話貼上（取代剛才那段）：" >&2; echo "--------" >&2
           if [ "$2" = ros ]; then print_select_ros; else print_select; fi
         fi; exit 0 ;;
esac

STAGE=$(cat .stage 2>/dev/null || echo start)
case "$STAGE" in
  start)  HINT="題目（整段）" ;;
  select) HINT="AI 的回覆（情境編號＋範例）" ;;
  done)   echo "🎉 這一題已經全部通過。要做下一題：./fb.sh reset"; exit 0 ;;
  brute)  HINT="AI 的回覆（暴力解＋產生器）" ;;
  *)      HINT="AI 的整段回覆（含程式碼）" ;;
esac
echo "👉 請貼上【$HINT】，貼完按 Enter，再按 Ctrl-D" >&2
if [ -t 0 ] && trap "stty icanon 2>/dev/null" EXIT INT && stty -icanon 2>/dev/null; then   # 終端機的一般模式每行最多 4095 bytes，長行會被砍：改成非 canonical 模式，讀到 Ctrl-D（0x04）為止
  IFS= read -r -d "$(printf '\004')" IN; stty icanon 2>/dev/null; echo >&2
else IN=$(cat); fi
[ -n "$IN" ] || { echo "沒有貼到任何東西" >&2; exit 1; }
T=$(mktemp -d); printf '%s\n' "$IN" > "$T/in.txt"; split_blocks "$T"; NB=$(cat "$T/count")

case "$STAGE" in
  start)
    printf '%s\n' "$IN" > problem.txt; echo select > .stage
    for f in main.c main.py tests; do   # 考場資料夾原本就有的檔案先備份（fb 之後會覆寫 main.c、重建 tests/）
      [ -e "$f" ] && [ ! -e ".fb_bak/$f" ] && { mkdir -p .fb_bak; cp -r "$f" .fb_bak/; echo "⚠️ 資料夾裡原本就有 $f，已備份到 .fb_bak/（fb reset 會還原）" >&2; }
    done
    # 題型判斷：只看 ROS 專屬字；「節點／topic」單獨出現不算（鏈結串列、樹、圖、MQTT 題都會有）
    if grep -qiE 'rclpy|rclcpp|ros ?2|ros2 |std_msgs|geometry_msgs|sensor_msgs|std_srvs|example_interfaces|/opt/ros|colcon|jazzy|humble' problem.txt \
       || { grep -qiE '訂閱|subscri' problem.txt && grep -qiE '發佈|發布|publish' problem.txt && grep -qiE 'topic|主題|節點|node' problem.txt; }; then echo ros > .mode
    elif [ -f Makefile ] || [ -f makefile ]; then echo proj > .mode
    else echo std > .mode; fi
    if [ "$(cat .mode)" = proj ]; then   # 題目提到、但題目裡沒有內容的 .c/.h，附在題目後面（每檔最多 150 行，省 context）
      echo; echo "【專案裡的檔案】$(find . -maxdepth 2 -type f \( -name '*.[ch]' -o -name 'Makefile' -o -name '*.py' \) ! -path './.fb*' | sed 's#^\./##' | tr '\n' ' ')" >> problem.txt
      for f in $(find . -maxdepth 2 -type f -name '*.[ch]' ! -path './.fb*' | sed 's#^\./##'); do
        b=$(basename "$f"); grep -qF "$b" problem.txt || [[ "$b" == *.h ]] || continue
        L=$(grep -m1 -vE '^[[:space:]]*(//.*|/\*.*|\*.*|#.*)?$' "$f" | sed 's/^[[:space:]]*//')
        [ -n "$L" ] && grep -qF -- "$L" problem.txt && continue
        { echo "【專案檔案 $f】"; echo '```c'; head -n 150 "$f"; echo '```'; } >> problem.txt
      done
    fi
    rm -f .fb_io   # 題目要求從命令列參數／檔案讀寫時，測資也照這個方式餵（判斷錯就 fb io std）
    if grep -qiE 'argv|命令列參數|命令列引數|command[- ]line arg' problem.txt; then echo "IO_ARGV=1" >> .fb_io; fi
    FI=$(grep -oE '從[^，。]{0,8}[A-Za-z0-9_.-]+[.](txt|in|dat)' problem.txt | grep -oE '[A-Za-z0-9_.-]+[.](txt|in|dat)$' | head -1)
    [ -n "$FI" ] && ! grep -q IO_ARGV .fb_io 2>/dev/null && echo "IO_IN=$FI" >> .fb_io
    FO=$(grep -oE '(寫到|寫入|輸出到|存到)[^，。]{0,8}[A-Za-z0-9_.-]+[.](txt|out|dat)' problem.txt | grep -oE '[A-Za-z0-9_.-]+[.](txt|out|dat)$' | head -1)
    [ -n "$FO" ] && echo "IO_OUT=$FO" >> .fb_io
    [ -f .fb_io ] && echo "ℹ️ 這題的輸入輸出不是 stdin/stdout：$(tr '\n' ' ' < .fb_io)（判斷錯就打 fb io std）" >&2
    case "$(cat .mode)" in ros) MN='ROS 2' ;; proj) MN='多檔案專案（有 Makefile，用 make 編譯）' ;; *) MN='一般輸入輸出' ;; esac
    echo "✅ 已存題目（題型：$MN；判斷錯了就打 fb mode std／fb mode ros／fb mode proj）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
    if [ "$(cat .mode)" = ros ]; then print_select_ros; else print_select; fi ;;
  select)
    if [ "$(cat .mode 2>/dev/null)" = ros ]; then
      rm -f verify.sh expected.txt
      for i in $(seq 1 "$NB"); do
        tg=$(cat "$T/b$i.tag"); lg=$(tr 'A-Z' 'a-z' < "$T/b$i.lang" | tr -d ' \r')
        if [ "$tg" = verify ] || { [ ! -f verify.sh ] && [[ "$lg" =~ ^(bash|sh|shell)$ ]]; }; then cp "$T/b$i.body" verify.sh
        elif [ "$tg" = out ]; then cp "$T/b$i.body" expected.txt; fi
      done
      fix_verify
      SID=$(grep -o 'S[0-9][0-9]' "$T/in.txt" | head -1); [ -f .pack_manual ] && SID=$(cat .pack_manual); [ -n "$SID" ] && echo "$SID" > .sid
      rm -f pack.txt; [ -n "$SID" ] && get_pack "$SID"
      echo write > .stage
      echo "✅ 驗收腳本：$( [ -s verify.sh ] && echo 有 || echo 沒有)；預期輸出：$( [ -s expected.txt ] && echo "$(grep -c . expected.txt) 行" || echo 沒有)；情境：${SID:-無}。把下面整段複製，到 AI 開新對話貼上：" >&2
      [ -s verify.sh ] || echo "⚠️ AI 沒給驗收腳本；之後只能檢查節點有沒有正常啟動。" >&2
      echo "--------" >&2
      print_write_ros; rm -rf "$T"; exit 0
    fi
    rm -rf tests; mkdir -p tests; k=0; kin=0; kout=0
    for i in $(seq 1 "$NB"); do
      tg=$(cat "$T/b$i.tag")
      if [ "$tg" = "in" ]; then kin=$((kin+1)); cp "$T/b$i.body" "tests/$kin.in"
      elif [ "$tg" = "out" ]; then kout=$((kout+1)); cp "$T/b$i.body" "tests/$kout.out"; fi
    done
    k=$(( kin < kout ? kin : kout ))
    for j in $(seq 1 $k); do trim_blank < "tests/$j.out" > "$T/o" && cp "$T/o" "tests/$j.out"; done   # AI 抄範例時多抄的頭尾空行會造成永遠比不過
    P=$(norm < problem.txt); BADC=0
    for j in $(seq 1 $k); do
      x=$(norm < "tests/$j.in"); y=$(norm < "tests/$j.out")
      { [ -n "$x" ] && [[ "$P" != *"$x"* ]]; } && { echo "⚠️ 第 $j 組範例輸入在題目裡找不到，可能被 AI 抄錯，請自己對一下 tests/$j.in" >&2; BADC=1; }
      { [ -n "$y" ] && [[ "$P" != *"$y"* ]]; } && { echo "⚠️ 第 $j 組範例輸出在題目裡找不到，可能被 AI 抄錯，請自己對一下 tests/$j.out" >&2; BADC=1; }
    done
    for j in $(seq $((k+1)) 99); do rm -f "tests/$j.in" "tests/$j.out"; done
    if [ "$k" -eq 0 ] || [ "$BADC" -eq 1 ]; then   # 備案：fb 自己從題目抓範例
      ke=$(extract_samples "$T/ex")
      if [ "${ke:-0}" -gt 0 ]; then rm -rf tests; mkdir -p tests
        for j in $(seq 1 "$ke"); do cp "$T/ex/$j.in" "tests/$j.in"; cp "$T/ex/$j.out" "tests/$j.out"; done
        echo "✅ 改用 fb 直接從題目抓到的 $ke 組範例（AI 抄的不完整或抄錯）" >&2; k=$ke; fi
    fi
    SID=$(grep -o 'S[0-9][0-9]' "$T/in.txt" | head -1)
    [ -f .pack_manual ] && SID=$(cat .pack_manual)   # 考生用 fb pack 指定過就以考生為準
    [ -n "$SID" ] && echo "$SID" > .sid
    rm -f pack.txt; [ -n "$SID" ] && get_pack "$SID"
    echo write > .stage
    echo "✅ 建了 $k 組測資；情境：${SID:-無}。把下面整段複製，到 AI 開新對話貼上：" >&2
    [ "$k" -eq 0 ] && echo "⚠️ AI 沒照格式抄範例，所以沒有測資；之後只能直接執行看輸出。" >&2
    echo "--------" >&2
    print_write ;;
  brute)   # 收暴力解＋產生器 → 對拍
    BR=""; GE=""
    for i in $(seq 1 "$NB"); do
      lg=$(tr 'A-Z' 'a-z' < "$T/b$i.lang" | tr -d ' \r'); [[ "$lg" =~ ^(python|py|python3)$ ]] || [ -z "$lg" ] || continue
      if grep -qE '暴力' "$T/b$i.prev" && [ -z "$BR" ]; then BR=$i
      elif grep -qE '產生|生成|generator' "$T/b$i.prev" && [ -z "$GE" ]; then GE=$i
      elif [ -z "$BR" ]; then BR=$i
      elif [ -z "$GE" ]; then GE=$i; fi
    done
    if [ -n "$BR" ] && [ -z "$GE" ] && grep -qE '^[[:space:]]*#.*(產生|生成|[Gg]enerat)' "$T/b$BR.body"; then   # 兩個程式寫在同一個區塊：從「# 產生器」那行切開
      awk -v B="$T/br.py" -v G="$T/ge.py" '/^[[:space:]]*#.*(產生|生成|[Gg]enerat)/ {g=1} { print > (g ? G : B) }' "$T/b$BR.body"
      { echo "import sys, random"; cat "$T/ge.py"; } > "$T/b$BR.gen"; cp "$T/br.py" "$T/b$BR.body"
      NB=$((NB+1)); cp "$T/b$BR.gen" "$T/b$NB.body"; GE=$NB
      echo "（暴力解和產生器寫在同一個區塊，已從「# 產生器」那行切開）" >&2
    fi
    if [ -z "$BR" ] || [ -z "$GE" ]; then
      echo "⚠️ 沒拿到兩個 Python 區塊（暴力解＋產生器）。把下面整段複製，到 AI 開新對話貼上（或打 fb skip 略過對拍）：" >&2; echo "--------" >&2
      echo "（上一次你沒有給兩個 ${FENCE}python 區塊。第一個是暴力解，第二個是產生器。）"; print_brute; rm -rf "$T"; exit 0
    fi
    cp "$T/b$BR.body" brute.py; cp "$T/b$GE.body" gen.py
    for f in brute.py gen.py; do   # 只定義了函式、沒有任何頂層呼叫（小模型常這樣）→ 在最後補上呼叫第一個函式
      if ! grep -qE '^[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*[(]|^if __name__|^print|^for |^while |^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$f"; then
        fn=$(grep -m1 -oE '^def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$f" | awk '{print $2}'); [ -n "$fn" ] && { echo "$fn()" >> "$f"; echo "（$f 只有定義函式，已補上呼叫 $fn()）" >&2; }
      fi
    done
    SRCF=$(ls main.c main.py 2>/dev/null | head -1)
    stress_run; stress_after $? "$SRCF" ;;
  write|fix)
    MODE=$(cat .mode 2>/dev/null); PREF=c; grep -qiE '(用|使用|以)[[:space:]]*python|python[[:space:]]*3?[[:space:]]*(撰寫|實作|作答|寫)|in python' problem.txt && PREF=py; [ "$MODE" = ros ] && PREF=py
    PICK=""; EXT=""; PS=-1
    for i in $(seq 1 "$NB"); do   # 選「完整程式」的區塊，而不是最後一個區塊
      lg=$(tr 'A-Z' 'a-z' < "$T/b$i.lang" | tr -d ' \r'); B="$T/b$i.body"; e=""
      if   [[ "$lg" =~ ^(c|h|cc|c99|c11|c17|gnuc)$ ]] || { [ -z "$lg" ] && grep -q '#include' "$B"; }; then e=c
      elif [[ "$lg" =~ ^(cpp|c\+\+|cxx|cplusplus)$ ]]; then e=cpp
      elif [[ "$lg" =~ ^(python|py|python3)$ ]] || { [ -z "$lg" ] && grep -qE '^(import|from|def) ' "$B"; }; then e=py; fi
      [ -z "$e" ] && continue
      [ "$e" = c ] && grep -qE '#include[[:space:]]*<(iostream|bits/stdc\+\+\.h|vector|algorithm|string)>|using namespace std|std::' "$B" && e=cpp
      s=0   # 完整程式（有 main／有輸出）+2，語言符合題目 +1；同分取後面的（AI 先給錯的再給對的）
      case $e in c|cpp) grep -qE '(int|void)[[:space:]]+main[[:space:]]*\(' "$B" && s=2 ;; py) grep -qE 'print\(|sys\.stdout|rclpy\.(init|spin)' "$B" && s=2 ;; esac
      [ "$MODE" = proj ] && grep -qE '^[[:space:]]*(//|/\*|#)[[:space:]]*FILE:' "$B" && s=2
      { [ "$e" = "$PREF" ] || { [ "$e" = cpp ] && [ "$PREF" = c ]; }; } && s=$((s+1))
      [ $s -ge $PS ] && { PICK=$i; EXT=$e; PS=$s; }
    done
    if [ -z "$PICK" ]; then
      echo "⚠️ AI 的回覆裡沒有程式碼區塊。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
      if [ "$MODE" = ros ]; then echo "（上一次你沒有給程式碼。請只給一個完整的 ${FENCE}python 程式碼區塊。）"; print_write_ros
      else echo "（上一次你沒有給程式碼。請只給一個完整、可編譯的 ${FENCE}c 程式碼區塊。）"; print_write; fi; exit 0
    fi
    NOTE=""
    if [ "$(cat "$T/unclosed" 2>/dev/null)" = "$PICK" ]; then   # 程式碼區塊沒收尾：回覆可能被截斷，或後面的說明被當成程式
      NOTE="（注意：你上一個回覆的程式碼區塊沒有收尾，可能被截斷了。請給更精簡的完整程式：不要註解、不要說明。）"
      echo "⚠️ AI 的程式碼區塊沒有收尾（回覆可能被截斷）" >&2
      [ "$EXT" != py ] && awk '{a[NR]=$0} /}[ \t]*$/{e=NR} END{for(i=1;i<=(e?e:NR);i++)print a[i]}' "$T/b$PICK.body" > "$T/cut" && cp "$T/cut" "$T/b$PICK.body"
    fi
    if [ "$EXT" = cpp ] && ! command -v g++ >/dev/null 2>&1; then
      echo "⚠️ AI 給的是 C++，但這個環境沒有 g++。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
      echo "（上一次你給的是 C++，但考場環境只有 gcc（C 語言），沒有 g++。請改寫成 C：不能用 iostream、vector、string 類別、std::。）"; print_write; rm -rf "$T"; exit 0
    fi
    if [ "$MODE" = proj ]; then   # 多檔案專案：寫回 AI 指定的那個檔案，用 make 編譯
      TG=$(grep -m1 -oE 'FILE:[[:space:]]*[A-Za-z0-9_./-]+' "$T/b$PICK.body" | sed 's/FILE:[[:space:]]*//')
      [ -z "$TG" ] && TG=$(cat "$T/b$PICK.info" "$T/b$PICK.prev" | grep -oE '[A-Za-z0-9_./-]+\.(c|h|py)' | head -1)
      [ -z "$TG" ] && TG=$(best_file_for "$T/b$PICK.body")
      [ -z "$TG" ] && TG=$(cat .fb_target 2>/dev/null)
      if [ -n "$TG" ] && [ ! -f "$TG" ]; then F2=$(find . -maxdepth 2 -name "$(basename "$TG")" ! -path './.fb*' | pick_by_problem); [ -n "$F2" ] && TG=${F2#./}; fi
      if [ -z "$TG" ] || [ ! -f "$TG" ]; then
        echo "⚠️ 看不出 AI 要改哪個檔案。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
        echo "（上一次你沒有標出要改的檔案，或檔名不存在。程式碼區塊第一行一定要寫 // FILE: 檔名，檔名必須是專案裡已有的檔案：$(find . -maxdepth 2 -name '*.[ch]' ! -path './.fb*' | sed 's#^\./##' | tr '\n' ' ')）"; print_write; rm -rf "$T"; exit 0
      fi
      [ -e ".fb_bak/$TG" ] || { mkdir -p ".fb_bak/$(dirname "$TG")"; cp "$TG" ".fb_bak/$TG"; }
      cp "$T/b$PICK.body" "$TG"; echo "$TG" > .fb_target; echo "（已寫入 $TG，原檔備份在 .fb_bak/）" >&2
      OUT=$(PROJ=1 bash "$SELF" check "$TG")
    else
      rm -f main.c main.cpp main.py; cp "$T/b$PICK.body" "main.$EXT"
      if [ "$MODE" = ros ]; then
        for i in $(seq 1 "$NB"); do [ "$(cat "$T/b$i.tag")" = verify ] && { cp "$T/b$i.body" verify.sh; echo "（AI 更新了驗收腳本）" >&2; }; done
        fix_verify
        OUT=$(bash "$SELF" checkros)
      else
        OUT=$(bash "$SELF" check "main.$EXT")
      fi
    fi
    if printf '%s' "$OUT" | grep -q '全部通過' && [ "$MODE" = std ] && [ "${STRESS:-1}" = 1 ] && [ ! -f .fb_stress_ok ]; then
      if [ -s brute.py ] && [ -s gen.py ]; then   # 之前已經有暴力解＋產生器：直接再對拍，不用再問 AI
        stress_run; stress_after $? "main.$EXT"
      else
        echo brute > .stage
        echo "✅ 範例都過了。接著做「對拍」找隱藏測資的錯：把下面整段複製，到 AI 開新對話貼上（不想做就打 fb skip）：" >&2; echo "--------" >&2
        print_brute
      fi
    elif printf '%s' "$OUT" | grep -q '全部通過'; then
      echo done > .stage; printf '%s\n' "$OUT"
      echo "🎉 全部通過！交卷：直接打 fb submit（第一次會問作答專案的網址和檔名）。下一題：fb reset" >&2
    elif printf '%s' "$OUT" | grep -q '（沒有測資' && printf '%s' "$OUT" | grep -q '結束碼：0'; then
      echo done > .stage; printf '%s\n' "$OUT"
      echo "⚠️ 沒有測資可以自動比對：程式已編譯、執行結束碼 0（輸出在上面）。請自己對照題目看輸出合不合理；要繼續修就把上面整段貼給 AI，再用 fb test 檢查。" >&2
    else
      echo fix > .stage
      echo "❌ 還沒過。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
      [ -n "$NOTE" ] && echo "$NOTE"
      printf '%s\n' "$OUT"
    fi ;;
esac
rm -rf "$T"; exit 0
fi
shift
SRC="$1"; TDIR="${2:-tests}"; LIMIT=1500
TO="${TO:-5}"
[ -f "$SRC" ] || { echo "用法：./fb.sh main.c [測資資料夾]"; exit 1; }
REP=$(mktemp); BIN=$(mktemp)
say() { printf '%s\n' "$*" >> "$REP"; }
cut_lines() { head -n "$1" | cut -c1-160; }

emit() {  # 有 problem.txt 且還沒全部通過 → 輸出「開新對話直接貼」的完整區塊
  N=0
  if ! grep -q '全部通過' "$REP"; then   # 記錄這次的錯誤指紋，算同一個錯誤連續出現幾次
    SIG=$(grep -m1 -A2 -E '第一個不同|error:|結果：' "$REP" | md5sum | cut -c1-12)
    if [ "$SIG" = "$(cat .fb_sig 2>/dev/null)" ]; then N=$(( $(cat .fb_n 2>/dev/null || echo 0) + 1 )); fi
    echo "$SIG" > .fb_sig; echo "$N" > .fb_n
  else rm -f .fb_sig .fb_n; fi
  if [ -f problem.txt ] && ! grep -q '全部通過' "$REP"; then
    if [ "$N" -ge 2 ]; then   # 第 3 次同一個錯誤：不給舊程式，要求從頭重寫
      echo "【重寫任務】你是上機考解題助手。前一版程式已經連續 $((N+1)) 次犯同一個錯，修補沒有用。不要沿用舊程式，依照下面的題目從頭重新寫一個完整程式（只給一個程式碼區塊，程式裡不要寫註解）。寫程式前先用 3 行列出：每個要輸出的值在哪一步算出來、存在哪個變數（不要在輸出時重新讀取或重新計算已經用掉的資料）。輸出格式逐字照題目範例。"
      echo "【題目】"; cat problem.txt; echo
      [ -f pack.txt ] && { echo "【參考零件】（只是參考，和題目不同時以題目為準）"; cat pack.txt; echo; }
      echo "【前一版的錯誤（不要再犯）】"
    else
      echo "【修正任務】你是上機考解題助手。下面是題目、目前的程式和執行回報。先用一句話說錯在哪一行、為什麼，再給修正後的完整程式（只給一個程式碼區塊，程式裡不要寫註解）。輸出格式逐字照題目範例；不要心算。常見原因：輸出時重新讀取或重新計算了已經用掉的資料、欄位順序或位元順序弄反、型別溢位。"
      echo "【題目】"; cat problem.txt; echo
      [ -f pack.txt ] && ! grep -q "👉 這一行只差在" "$REP" && { echo "【參考零件】（只是參考，和題目不同時以題目為準；只附前 12 行省長度）"; head -n 12 pack.txt; echo; }   # 純格式錯誤時不附情境包（包裡的範例格式可能和題目不同，會誤導）
      echo "【目前程式】"; echo '```'"$LTAG"; cat "$SRC"; echo '```'
    fi
  fi
  head -c $LIMIT "$REP"; echo
  [ "$(wc -c < "$REP")" -gt $LIMIT ] && echo "（回報已截斷到 $LIMIT 字元）"
  if [ "$N" -ge 1 ] && grep -q '👉 這一行只差在' "$REP"; then
    echo "⚠️ 這個格式錯誤已經連續 $((N+1)) 次。只看「第 N 個字元：預期「X」，你的「Y」」那一行，找出印這一行的 printf，把格式字串改成跟預期逐字相同；其他程式碼一個字都不要動。"
  elif [ "$N" -eq 1 ]; then
    echo "⚠️ 這個錯誤已經連續 2 次一模一樣，代表上次的修改沒有改到真正原因。這次在算出錯值的地方加 fprintf(stderr, ...) 印出中間值，答案照常印到 stdout；我會把 stderr 一起貼給你。"
  fi
  return 0
}

compile_fail() {   # 印第一個錯誤（含 ld 的 undefined reference，原本只會印到 collect2 那行）與附近原始碼
  say "結果：編譯失敗"
  say "--- 第一個錯誤（編譯器原文）---"
  if grep -qE 'error|undefined reference|multiple definition' "$REP.err"; then grep -m1 -A4 -E 'error|undefined reference|multiple definition' "$REP.err" | cut_lines 8 >> "$REP"
  else tail -n 6 "$REP.err" | cut_lines 6 >> "$REP"; fi   # 例如 make: *** No rule to make target
  EF=$(grep -m1 -oE '^[^: ]+\.(c|h|cpp):[0-9]+:[0-9]+: (fatal )?error' "$REP.err" | cut -d: -f1); [ -f "$EF" ] || EF="$SRC"
  LN=$(grep -m1 -oE ':[0-9]+:[0-9]+: (fatal )?error' "$REP.err" | cut -d: -f2)
  if [ -n "$LN" ]; then
    say "--- $EF 第 $((LN>2?LN-2:1))～$((LN+2)) 行 ---"
    sed -n "$((LN>2?LN-2:1)),$((LN+2))p" "$EF" | nl -ba -v $((LN>2?LN-2:1)) | cut -c1-160 >> "$REP"
  fi
  grep -q 'undefined reference' "$REP.err" && say "（這是連結錯誤：undefined reference 後面的函式只有宣告、沒有實作，或沒有一起編譯到那個 .c 檔）"
  grep -q 'multiple definition' "$REP.err" && say "（這是連結錯誤：同一個函式／變數在兩個檔案都定義了，例如另外又寫了一個 main）"
  say "請只修正這個錯誤，給完整程式。"
  emit; rm -f "$REP" "$REP.err" "$BIN"; exit 1
}
say "【執行回報】檔案：$SRC"
if [ -n "$PROJ" ]; then   # 多檔案專案：用 make 編，執行檔＝這次 make 新產生的可執行檔（或 PROG=路徑 指定）
  LTAG=c; touch .fb_stamp
  if ! make > "$REP.mk" 2> "$REP.err"; then cat "$REP.mk" >> "$REP.err"; compile_fail; fi
  P=${PROG:-$(find . -maxdepth 2 -type f -perm -u+x -newer .fb_stamp ! -name '*.sh' ! -name '*.[ch]' ! -path './.fb*' | pick_by_problem "$(basename "$(dirname "$SRC")")")}
  [ -z "$P" ] && P=$(cat .fb_prog 2>/dev/null)
  if [ -z "$P" ] || [ ! -x "$P" ]; then say "結果：make 成功，但找不到執行檔（考生請用 PROG=執行檔路徑 fb test 指定）"; emit; rm -f "$REP" "$REP.err" "$BIN"; exit 1; fi
  echo "$P" > .fb_prog; RUN="$P"
  W=$(grep -c 'warning' "$REP.err")
  [ "$W" -gt 0 ] && { say "編譯（make）：成功，但有 $W 個 warning（第一個如下）"; grep -m1 'warning' "$REP.err" | cut_lines 1 >> "$REP"; } || say "編譯（make）：成功，執行檔 $P"
else
case "$SRC" in
  *.c)  LTAG=c; RUN="$BIN"
        gcc -O2 -Wall -Wextra -pthread -o "$BIN" "$SRC" -lm 2> "$REP.err" || compile_fail
        W=$(grep -c 'warning' "$REP.err")
        [ "$W" -gt 0 ] && { say "編譯：成功，但有 $W 個 warning（第一個如下）"; grep -m1 'warning' "$REP.err" | cut_lines 1 >> "$REP"; } || say "編譯：成功，0 warning" ;;
  *.cpp) LTAG=cpp; RUN="$BIN"
        g++ -O2 -Wall -pthread -o "$BIN" "$SRC" 2> "$REP.err" || compile_fail
        say "編譯（g++）：成功" ;;
  *.py) LTAG=python; RUN="python3 $SRC"
        python3 -m py_compile "$SRC" 2> "$REP.err" || { say "結果：Python 語法錯誤"; cut_lines 8 < "$REP.err" >> "$REP"; emit; rm -f "$REP" "$REP.err" "$BIN"; exit 1; } ;;
  *) echo "只支援 .c / .cpp / .py"; exit 1 ;;
esac
fi

[ -f .fb_io ] && . ./.fb_io   # fb io 設定：IO_ARGV=1（輸入檔路徑當 argv[1]）／IO_IN=檔名（先把輸入複製成這個檔）／IO_OUT=檔名（比對這個檔的內容）
runone() {
  local rc
  [ -n "$IO_IN" ] && cp "$1" "$IO_IN"
  [ -n "$IO_OUT" ] && rm -f "$IO_OUT"
  if [ -n "$IO_ARGV" ]; then timeout "$TO" $RUN "$1" < /dev/null; rc=$?
  elif [ -n "$IO_IN" ]; then timeout "$TO" $RUN < /dev/null; rc=$?
  else timeout "$TO" $RUN < "$1"; rc=$?; fi
  [ -n "$IO_OUT" ] && cat "$IO_OUT" 2>/dev/null
  return $rc
}
shopt -s nullglob; INS=("$TDIR"/*.in)
[ ${#INS[@]} -gt 0 ] && mapfile -t INS < <(printf '%s\n' "${INS[@]}" | sort -V)   # 10.in 排在 9.in 後面
trim_tail() { awk '{a[NR]=$0} END{e=NR; while (e>0 && a[e]=="") e--; for (i=1;i<=e;i++) print a[i]}'; }
tidy() { sed 's/[[:space:]]*$//' | trim_tail; }   # 行尾空白、結尾空行都不算錯
if [ ${#INS[@]} -eq 0 ]; then
  say "（沒有測資，直接執行一次，最多 ${TO} 秒）"
  S=$(date +%s%N); OUTP=$(timeout "$TO" $RUN < /dev/null 2>&1); RC=$?; E=$(( ($(date +%s%N)-S)/1000000 ))
  say "結束碼：$RC（124=逾時，134=assert/abort，139=記憶體錯誤）；時間 ${E} ms"
  say "--- 輸出（前 15 行）---"; printf '%s\n' "$OUTP" | cut_lines 15 >> "$REP"
else
  PASS=0; MAXE=0; FAILED=""; TOTAL=${#INS[@]}
  for IN in "${INS[@]}"; do
    EXP="${IN%.in}.out"; S=$(date +%s%N)
    GOT=$(runone "$IN" 2>"$REP.se"); RC=$?; E=$(( ($(date +%s%N)-S)/1000000 )); [ $E -gt $MAXE ] && MAXE=$E
    if [ $RC -eq 0 ] && [ -f "$EXP" ] && diff -q <(printf '%s\n' "$GOT" | tidy) <(tidy < "$EXP") >/dev/null; then
      PASS=$((PASS+1))
    elif [ -z "$FAILED" ]; then
      FAILED="$IN"; FRC=$RC; FE=$E; FGOT="$GOT"; FSE=$(head -n 15 "$REP.se" | cut -c1-160)
    fi
  done
  say "測資：$PASS / $TOTAL 通過"
  if [ -n "$FAILED" ]; then
    say "--- 第一筆失敗：$(basename "$FAILED")（結束碼 $FRC，${FE} ms；124=逾時）---"
    say "輸入（前 5 行）："; cut_lines 5 < "$FAILED" >> "$REP"
    say "預期輸出（前 8 行）："; cut_lines 8 < "${FAILED%.in}.out" >> "$REP"
    say "你的輸出（前 8 行）："; printf '%s\n' "$FGOT" | cut_lines 8 >> "$REP"
    [ -n "$FSE" ] && { say "你的 stderr（除錯輸出，前 15 行）："; printf '%s\n' "$FSE" >> "$REP"; }
    # 改進：逐字指出第一個不同的行與字元位置，空白顯示成 ␣（小模型看不出「x1,x0」和「x1, x0」的差別）
    printf '%s\n' "$FGOT" > "$REP.got"
    awk -v gf="$REP.got" '
      { e[++ne]=$0 }
      END {
        while ((getline l < gf) > 0) g[++ng]=l
        n = ne > ng ? ne : ng
        for (i = 1; i <= n; i++) {
          a = (i <= ne) ? e[i] : "<沒有這行>"; b = (i <= ng) ? g[i] : "<沒有這行>"
          sub(/[ \t\r]+$/, "", a); sub(/[ \t\r]+$/, "", b)
          if (a != b) {
            for (c = 1; c <= length(a) && c <= length(b) && substr(a,c,1) == substr(b,c,1); c++) ;
            x = a; y = b; gsub(/ /, "␣", x); gsub(/ /, "␣", y)
            printf "第一個不同：第 %d 行、第 %d 個字元起（預期共 %d 行，你的共 %d 行）\n  預期：%s\n  你的：%s\n", i, c, ne, ng, x, y
            p = a; q = b; gsub(/[ \t]/, "", p); gsub(/[ \t]/, "", q)
            ca = (c <= length(a)) ? substr(a, c, 1) : "（行尾）"; cb = (c <= length(b)) ? substr(b, c, 1) : "（行尾）"
            if (ca == " ") ca = "␣"; if (cb == " ") cb = "␣"
            if (i <= ne && i <= ng) printf "  第 %d 個字元：預期「%s」，你的「%s」\n", c, ca, cb
            pp = p; qq = q; gsub(/[,;:.]/, "", pp); gsub(/[,;:.]/, "", qq)
            if (p == q) printf "👉 這一行只差在「空白」：內容都對，請只改 printf 的格式字串，讓空白位置和預期一模一樣（␣ 是空白；例如逗號後面要不要空格）。不要改其他邏輯。\n"
            else if (pp == qq) printf "👉 這一行只差在「標點符號」（例如少了或多了逗號）：內容都對，請只改 printf 的格式字串，讓標點和空白跟預期逐字相同。不要改其他邏輯。\n"
            else if (tolower(a) == tolower(b)) printf "👉 這一行只差在「大小寫」：請只改 printf 的格式字串或字串表的大小寫。不要改其他邏輯。\n"
            exit
          }
        }
      }' "${FAILED%.in}.out" >> "$REP"
    say "（␣ 代表一個空白。請逐字對照題目的輸出格式，格式以題目為準，不是情境包。）"
    rm -f "$REP.got"
    say "請找出原因並修正，給完整程式。不要心算，必要時加 printf 除錯。"
  else
    say "全部通過。（最慢一筆 ${MAXE} ms）"
  fi
fi
emit
rm -f "$REP" "$REP.err" "$BIN"
