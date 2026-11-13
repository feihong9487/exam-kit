#!/usr/bin/env bash
# fb.sh v5（考場版：一般題＋ROS 2 題）— 你當手腳、考場 AI 當大腦：每一輪都只做同一個動作。
#   ① 終端機打 ./fb.sh ，貼上「題目」或「AI 的整段回覆」，Enter 後按 Ctrl-D
#   ② 把終端機印出來的內容整段複製，到考場 AI「開新對話」貼上
#   ③ 把 AI 的整段回覆複製，回到 ①；直到出現「🎉 全部通過」
# 其他指令：./fb.sh selfcheck（檢查環境）
#          ./fb.sh submit（交卷：放進 GitLab 作答 repo 並 push）
#          ./fb.sh ci（GitLab CI 沒過：貼 job log 產生修正任務）
#          ./fb.sh task（任務模式：要下指令觀察、改設定、解 git 衝突等不是寫程式的題目）
#          ./fb.sh reset（換下一題，清空這個資料夾的狀態）
#          ./fb.sh test（不貼東西，直接重跑目前的程式）
#          ./fb.sh pack S06（手動換情境包）
#          TO=1 ./fb.sh（效能題：每筆測資限時 1 秒）
# 需要同資料夾或 fb.sh 旁邊有 packs.txt（30 個情境包）。每一題建議用一個新資料夾。
SELF="$(readlink -f "$0")"; HERE="$(dirname "$SELF")"
PACKS="${PACKS:-$HERE/packs.txt}"; [ -f "$PACKS" ] || PACKS="./packs.txt"
# 「要貼給 AI 的內容」同時存成 .fb_prompt.txt，並試著直接放進剪貼簿（終端機支援 OSC 52 才有效，不支援也沒有副作用）。FB_COPY=0 可關
if [ -z "$FB_WRAPPED" ] && [ -t 1 ] && [ "${FB_COPY:-1}" = 1 ] && command -v tee >/dev/null 2>&1; then
  case "${1:-}" in ""|test|task|ci|mode)
    export FB_WRAPPED=1; rm -f .fb_prompt.txt
    bash "$SELF" "$@" | tee .fb_prompt.txt; FBRC=${PIPESTATUS[0]}
    if [ -s .fb_prompt.txt ] && [ "$(wc -c < .fb_prompt.txt)" -gt 200 ]; then
      if [ "$(wc -c < .fb_prompt.txt)" -lt 60000 ] && command -v base64 >/dev/null 2>&1; then
        printf '\033]52;c;%s\a' "$(base64 < .fb_prompt.txt | tr -d '\n')" > /dev/tty 2>/dev/null
      fi
      echo "📋 上面「--------」以下那一段（共 $(wc -l < .fb_prompt.txt) 行）已經存成 $(pwd)/.fb_prompt.txt，也試著直接放進剪貼簿了：先到 AI 網頁按 Ctrl+V 試試；貼出來的不是這一段，才回來用滑鼠選取複製（或用文字編輯器開那個檔，全選複製）。" >&2
    else rm -f .fb_prompt.txt; fi
    exit "$FBRC" ;;
  esac
fi
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
prob_wo() {   # 印 problem.txt，但拿掉附檔裡「目前程式」那個檔案的原始版本（下面會附目前版本，不用重複佔 context）
  awk -v t="【專案檔案 $1】" '$0==t {s=1; f=0; next} s && /^```/ {f++; if (f==2) s=0; next} !s' problem.txt 2>/dev/null
}

if [ "$1" = "checkros" ]; then
  LIMIT=1800; VER="${VERIFY:-verify.sh}"; EXPF="${EXPECT:-expected.txt}"
  REP=$(mktemp); say() { printf '%s\n' "$*" >> "$REP"; }
  source /opt/ros/jazzy/setup.bash >/dev/null 2>&1 || { echo "❌ 找不到 ROS 2（/opt/ros/jazzy/setup.bash）"; exit 1; }
  export ROS_DOMAIN_ID=$(( RANDOM % 80 + 20 ))
  LIB=$(mktemp)
  cat > "$LIB" <<'FB_ROSLIB'
_f() { echo "${FBROS:-/tmp}/fbros_$(echo "$1" | tr '/' '_')"; }
_hs() { [ -n "$FB_HELPERS" ] && [ ! -f "$FBROS/hs" ] || return 0; touch "$FBROS/hs"; for h in $FB_HELPERS; do if [ "$h" = main.py ]; then python3 main.py >> node.log 2>&1 & else python3 "$h" >> "$FBROS/helper.log" 2>&1 & fi; echo $! >> "$FBROS/hs"; disown; done; sleep 4; }   # 節點（main.py 和題目給的 publisher.py 等）等 grab 都準備好才（重新）啟動：timer 一開始發的 data: 10、11、12 才收得到
grab() { local t="/${1#/}" ty; ty=$(awk -v t="$t" '$1==t {gsub(/[][]/, "", $2); print $2}' "$FBROS/types" 2>/dev/null | head -1)   # 型別用第一次啟動時記下的（節點還沒重新啟動時 topic 不存在，echo 要給型別）
  timeout 45 ros2 topic echo "$1" $ty > "$(_f "$1")" 2>&1 & GRAB_PIDS="$GRAB_PIDS $!"; sleep 2; }
send() { _hs; timeout 10 ros2 topic pub --once -w 1 "$1" "$2" "$3" > /dev/null 2>&1 || echo "（send $1 失敗：沒有節點訂閱 $1，或型別／YAML 寫錯）"; sleep 0.7; }
show() { _hs; sleep 1; for p in $GRAB_PIDS; do kill -INT "$p" 2>/dev/null; done; [ -n "$GRAB_PIDS" ] && wait $GRAB_PIDS 2>/dev/null; GRAB_PIDS=""; echo "== $1 收到："; grep -vE '^---$|WARNING|does not appear' "$(_f "$1")" | head -40; }
call() { _hs; echo "== call $1："; timeout 12 ros2 service call "$1" "$2" "$3" 2>&1 | tail -3 | _yaml; }
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
    FB_HELPERS=""; P0=$(sed '/^【專案裡的檔案】/,$d' problem.txt 2>/dev/null)
    for h in $(find . -maxdepth 2 -name '*.py' ! -name main.py ! -name brute.py ! -name gen.py ! -path './.fb*' 2>/dev/null | sed 's#^\./##'); do   # 題目附的其他節點（例如 publisher.py）也一起跑，像考場說的「開兩個終端機」
      [ "$h" = "$(cat .fb_target 2>/dev/null)" ] && continue; grep -q rclpy "$h" && [[ "$P0" == *"$(basename "$h")"* ]] || continue
      FB_HELPERS="$FB_HELPERS $h"; say "（驗收時會同時啟動題目給的節點 $h：驗收腳本第一個 send／show／call 之前才啟動，所以 grab 收得到它最前面的訊息）"
    done; export FB_HELPERS
    python3 main.py > node.log 2>&1 & NP=$!
    sleep 4
    if kill -0 "$NP" 2>/dev/null; then ALIVE=1; else ALIVE=0; fi
    say "--- 節點啟動 4 秒後的 ROS 圖 ---"; ros2 topic list -t > "$FBROS/types" 2>/dev/null
    say "節點：$(ros2 node list 2>/dev/null | tr '\n' ' ')"
    for t in $(ros2 topic list 2>/dev/null | grep -vE '^/(rosout|parameter_events)$'); do
      I=$(ros2 topic info "$t" 2>/dev/null)
      say "topic $t  型別=$(echo "$I" | sed -n 's/^Type: //p')  發佈者=$(echo "$I" | sed -n 's/^Publisher count: //p')  訂閱者=$(echo "$I" | sed -n 's/^Subscription count: //p')"
    done
    S2=$(ros2 service list 2>/dev/null | grep -vE '/(describe|get|list|set)_parameters|parameter_types|type_description' | tr '\n' ' ')
    [ -n "$S2" ] && say "service：$S2"
    if [ $ALIVE -eq 1 ] && [ -s "$VER" ]; then
      kill -INT "$NP" 2>/dev/null; sleep 1.5; kill -9 "$NP" 2>/dev/null; wait "$NP" 2>/dev/null   # 看完 ROS 圖先停掉；驗收腳本 grab 好之後再重新啟動
      mv node.log node1.log; : > node.log; export FB_HELPERS="main.py$FB_HELPERS"
      timeout 90 bash -c "source '$LIB'; source '$VER'" > verify.out 2>&1
      HP=$(cat "$FBROS/hs" 2>/dev/null | grep -E '^[0-9]+$' | paste -sd' ')
      say "--- 驗收腳本輸出（前 25 行）---"; head -n 25 verify.out | cut -c1-160 >> "$REP"
      [ -s verify.out ] || say "⚠️ 驗收腳本什麼都沒印（沒有 show／call，或 show 的 topic 名稱打錯）→ 問題在【驗收腳本】，不一定在節點；請一起附上修正後的【驗收腳本】。"
    elif [ $ALIVE -eq 1 ]; then say "（沒有驗收腳本，只檢查節點有沒有正常啟動）"; : > verify.out; fi
    LB=$(wc -l < node.log)   # Ctrl-C 之前的行數：之前就有 Traceback＝執行中出錯
    kill -INT "$NP" $HP 2>/dev/null; sleep 2; kill -9 "$NP" $HP 2>/dev/null
    ROSPASS=1
    [ $ALIVE -eq 0 ] && { say "❌ 節點啟動後就結束了（可能程式出錯或沒有 spin）"; ROSPASS=0; }
    if head -n "$LB" node.log | grep -q "Traceback"; then
      say "❌ 節點執行中出錯（Traceback）"; ROSPASS=0
    elif tail -n +"$((LB+1))" node.log | grep -q "Traceback" && ! tail -n +"$((LB+1))" node.log | grep -qE 'context is not valid|rcl_shutdown'; then   # rclpy 收到 Ctrl-C 時偶發的 RCLError（context is not valid）不算程式的錯
      say "❌ 節點在 Ctrl-C 之後出現 Traceback（代表沒有處理 ExternalShutdownException）"; ROSPASS=0
    fi
    if [ -s "$EXPF" ] && [ $ALIVE -eq 1 ]; then
      # 每一行預期輸出要在驗收輸出裡「完整出現」：忽略引號與頭尾空白；開頭結尾是英數字時不能接著別的數字（data: 3.0 不會被 data: 3.05、13.0 當成有）
      MISS=$(python3 - "$EXPF" verify.out <<'FB_PYMATCH'
import re, sys
rd = lambda f: open(f, encoding="utf-8", errors="replace").read().splitlines()
q = lambda s: re.sub(r"\b(True|False)\b", lambda m: m.group(1).lower(), s.strip().replace("'", "").replace('"', ""))   # Python 的 True／False 和 ros2 echo 的 true／false 視為相同
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
    echo "【題目】"; if [ "$N" -lt 2 ] && [ -s .fb_target ]; then prob_wo "$(cat .fb_target)"; else cat problem.txt; fi; echo
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
你是上機考解題助手。這是考場資料夾裡已有起始檔的題目（有 Makefile 就用 make 編譯）。根據下面的【題目】與【專案檔案】，只修改題目要求的那一個檔案（通常是有 TODO 或要修 bug 的那個）。
規則：1. 輸出「那一個檔案修改後的完整內容」，放在一個 ```c 程式碼區塊，區塊第一行寫 // FILE: 檔名（例：// FILE: ringbuf.c；子資料夾要寫路徑，例：// FILE: rle/rle.c；要改的是 Python 檔就用 ```python 和 # FILE: 檔名）。2. 不要改沒被要求的檔案；不要自己另寫 main（除非要改的檔案本來就有 main）；#include、函式名稱與參數照原本的。3. 輸出格式逐字照題目範例。4. 程式裡不要寫註解，前面最多 2 行說明。
FB_PCODEP
echo "【題目】"; cat problem.txt
[ -f pack.txt ] && { echo "【參考零件】"; head -n 12 pack.txt; }
return
fi
cat <<'FB_PCODE'
你是上機考解題助手。根據下面的【題目】寫出完整、單一檔案、可直接編譯的 C 程式（gcc -O2 -Wall -pthread，#include 要齊全），從 stdin 讀、寫到 stdout。
規則：1. 輸出格式（空白、逗號、大小寫、換行）逐字照題目範例，不要多印任何文字。一筆一筆處理的題目：每一筆先把要印的值全部算好存起來、整筆檢查完，確定沒有錯誤才印這一行；任何一步出錯就只印題目規定的錯誤輸出（例如 ERR），不可以先印一半。2. 【參考零件】只是參考，和題目不同時以題目為準。3. 數字、位元欄位、指令編碼不要心算，寫進程式。4. 有時間限制先估複雜度：N 到 10^5 以上要 O(N log N) 以下。題目附原始程式的，保留原本的輸入輸出與要求（例如必須用多執行緒）。5. 只輸出一個 ```c 程式碼區塊，程式裡不要寫註解（省長度），前面最多 2 行說明。
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
  if [ "$(cat .mode 2>/dev/null)" = proj ]; then   # 專案模式：用剛才 make／gcc 編好的執行檔
    case "$(cat .fb_target 2>/dev/null)" in *.py) X="python3 $(cat .fb_target)" ;; *) X=$(cat .fb_prog 2>/dev/null); [ -n "$X" ] && [ -x "$X" ] || return 0 ;; esac
  elif [ -f main.c ]; then gcc -O2 -pthread -o .fb_main main.c -lm 2>/dev/null || return 0; X=./.fb_main; fi
  for f in tests/*.in; do [ -f "${f%.in}.out" ] || continue
    timeout 5 python3 brute.py < "$f" 2>/dev/null | tidy_s > .fb_b; tidy_s < "${f%.in}.out" > .fb_e
    cmp -s .fb_b .fb_e || { echo "⚠️ 暴力解連範例 $(basename "$f") 都不對，不採用對拍" >&2; echo "$f" > .fb_bf; return 2; }
  done
  S=$(date +%s); local cmpd=0; rm -f .fb_genbad
  for i in $(seq 1 300); do
    [ $(( $(date +%s) - S )) -ge "${STRESS_SEC:-20}" ] && break
    timeout 5 python3 gen.py > .fb_r.in 2>/dev/null || continue; [ -s .fb_r.in ] || continue
    timeout 5 python3 brute.py < .fb_r.in > .fb_r.exp 2>/dev/null || continue
    [ -n "$(tr -d '[:space:]' < .fb_r.exp)" ] || continue   # 暴力解什麼都沒印：多半是暴力解自己沒處理這種輸入，不拿來當反例
    timeout "${TO:-5}" $X < .fb_r.in > .fb_r.got 2>/dev/null; RC=$?; cmpd=$((cmpd+1))
    if [ $RC -ne 0 ] || ! cmp -s <(tidy_s < .fb_r.got) <(tidy_s < .fb_r.exp); then
      k=$(( $(ls tests/s*.in 2>/dev/null | wc -l) + 1 )); cp .fb_r.in "tests/s$k.in"; cp .fb_r.exp "tests/s$k.out"
      echo "🔎 對拍第 $i 組隨機測資找到反例，已存成 tests/s$k.in／.out" >&2; return 1
    fi
  done
  if [ "$cmpd" -eq 0 ]; then   # 產生器的輸入暴力解全都印不出東西：產生器格式多半不對，這次對拍不算數
    cp .fb_r.in .fb_genbad 2>/dev/null; echo "⚠️ 產生器產生的輸入，暴力解一組都印不出結果（產生器的輸入格式可能不對），不採用對拍" >&2; return 2; fi
  echo "✅ 對拍 $cmpd 組隨機小測資都和暴力解一致" >&2
  if timeout 20 python3 gen.py big > .fb_big.in 2>/dev/null && [ "$(wc -c < .fb_big.in)" -gt 20000 ]; then
    timeout "${TO:-5}" $X < .fb_big.in > /dev/null 2>&1; RC=$?
    [ $RC -eq 124 ] && { echo "⏱️ 最大規模輸入（$(wc -c < .fb_big.in) bytes）超過 ${TO:-5} 秒" >&2; return 3; }
    echo "✅ 最大規模輸入（$(wc -c < .fb_big.in) bytes）在 ${TO:-5} 秒內跑完" >&2
  fi
  return 0
}
stress_after() {   # $1=stress_run 的結果；$2=程式檔
  case "$1" in
    1) echo fix > .stage; echo "❌ 對拍找到範例沒抓到的錯誤。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
       echo "（注意：名稱是 s 開頭的測資是隨機產生的，預期輸出來自另一個確定正確的暴力解，請相信它，照它修正。）"
       if [ "$(cat .mode 2>/dev/null)" = proj ]; then PROJ=1 bash "$SELF" check "$2"; else bash "$SELF" check "$2"; fi ;;
    3) echo fix > .stage; echo "❌ 範例都對，但最大規模輸入逾時。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
       echo "【修正任務】你是上機考解題助手。下面的程式答案正確，但題目允許的最大規模輸入執行超過 ${TO:-5} 秒被中止（太慢）。請先用一句話說目前的時間複雜度，再改用更快的演算法（N 到 10^5 以上要 O(N log N) 以下；輸入輸出用 scanf／printf，大量輸出不要每行 fflush），輸入輸出格式不變，給完整程式（只給一個程式碼區塊，不要註解）。"
       echo "【題目】"; prob_wo "$2"; echo; echo "【目前程式】"; echo '```'; cat "$2"; echo '```' ;;
    2) if [ ! -f .fb_brute_retry ]; then   # 暴力解不可信：再請 AI 重寫一次暴力解（只重試一次）
         touch .fb_brute_retry; rm -f brute.py gen.py; echo brute > .stage; F0=$(cat .fb_bf 2>/dev/null)
         echo "⚠️ 暴力解或產生器不可信，不能拿來對拍。把下面整段複製，到 AI 開新對話貼上（不想做就打 fb skip）：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
         if [ -f .fb_genbad ]; then
           echo "（上一次的產生器產生的輸入格式不對，暴力解跑出來全是空的。產生器印出的例子（前 4 行）："; head -n 4 .fb_genbad | cut -c1-120
           echo "題目範例輸入（前 4 行）："; head -n 4 tests/1.in 2>/dev/null | cut -c1-120
         else
           echo "（上一次你寫的暴力解連題目範例都算錯。範例輸入（前 6 行）："; head -n 6 "$F0" | cut -c1-120
           echo "應該印出（前 6 行）："; head -n 6 "${F0%.in}.out" | cut -c1-120
           echo "你的暴力解印出（前 6 行）："; head -n 6 .fb_b | cut -c1-120
         fi
         echo "這次暴力解要逐字照題目的輸入輸出格式（例如數字是 0x 開頭的 16 進位就用 int(s, 0) 讀、照題目格式印）。產生器印出的輸入也要和題目範例的格式一樣。）"; print_brute
       else touch .fb_stress_ok; echo done > .stage
         echo "🎉 範例全部通過（暴力解兩次都不可信，所以沒有對拍；有空就自己想想邊界情況）。交卷：直接打 fb submit（第一次會問作答專案的網址和檔名）。下一題：fb reset" >&2; fi ;;
    *) touch .fb_stress_ok; echo done > .stage
       echo "🎉 全部通過（含對拍）！交卷：直接打 fb submit（第一次會問作答專案的網址和檔名）。下一題：fb reset" >&2 ;;
  esac
}
est_tok() { python3 -c 'import sys; t=sys.stdin.read(); c=sum(1 for ch in t if ord(ch)>0x2e7f); print(c+(len(t)-c)//3)' 2>/dev/null || echo 0; }   # 粗估 token 數（中日韓字 1 個算 1，其他 3 個字元算 1）
dg_split() {   # 題目太長（考場 AI 一次只能看約 4096 token）：把 $1 切成每段約 1300 token 的 .fb_chunk/1..K（盡量在空行切、不切斷程式碼區塊），印出 K
  rm -rf .fb_chunk; mkdir -p .fb_chunk
  python3 - "$1" <<'FB_PYSPLIT'
import sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r", "")
def tok(s):
    c = sum(1 for ch in s if ord(ch) > 0x2e7f)
    return c + (len(s) - c) // 3
paras, cur, fence = [], [], False
for line in t.split("\n"):
    if line.strip().startswith("```"): fence = not fence
    cur.append(line)
    if not fence and line.strip() == "":
        paras.append("\n".join(cur)); cur = []
if cur: paras.append("\n".join(cur))
pieces = []
for p in paras:
    if tok(p) <= 1300:
        pieces.append(p); continue
    buf = []
    for line in p.split("\n"):
        if buf and tok("\n".join(buf + [line])) > 1300:
            pieces.append("\n".join(buf)); buf = []
        buf.append(line)
    if buf: pieces.append("\n".join(buf))
chunks, cur = [], ""
for p in pieces:
    if cur and tok(cur + "\n" + p) > 1300:
        chunks.append(cur); cur = p
    else:
        cur = (cur + "\n" + p) if cur else p
if cur.strip(): chunks.append(cur)
for i, c in enumerate(chunks, 1):
    open(".fb_chunk/%d" % i, "w", encoding="utf-8").write(c.strip("\n") + "\n")
print(len(chunks))
FB_PYSPLIT
}
print_digest() {   # $1=第幾段 $2=共幾段
  echo "你是上機考助手。下面是一份很長的題目／說明文件的第 $1／$2 段，我之後要照它作答，但文件太長，需要你先濃縮。請把這一段濃縮成條列重點（15～25 行），一定要保留：每一個檔名、函式名、指令（整行照抄）、topic／node／參數名稱、要我執行的步驟、要我觀察或回答的事、要我寫或修改的程式與它該有的行為、輸入輸出格式、所有數字與範例。可以刪掉的只有：寒暄、重複的解釋、原理背景。名稱、數字、指令、格式字串一律照原文抄，不要改寫，不要回答「無」，不要寫程式、不要解題。"
  echo "【第 $1 段】"; cat ".fb_chunk/$1"
}
dg_samples() {   # 從原文把「範例輸入／輸出」那一段逐字留下來（AI 濃縮時常把範例抄錯）
  python3 - "$1" <<'FB_PYSAMP'
import sys, re
L = open(sys.argv[1], encoding="utf-8", errors="replace").read().replace("\r", "").split("\n")
s = next((i for i, l in enumerate(L) if re.search(r"範例輸入|輸入範例|[Ss]ample [Ii]nput|[Ee]xample [Ii]nput", l)), None)
if s is not None:
    print("【範例（原文）】"); print("\n".join(L[s:])[:1500])
FB_PYSAMP
}
dg_finish() {   # 濃縮完成：重點＋原文範例
  local D; D=$(grep -vE '^[[:space:]]*(```.*|（無）|\(無\)|無)[[:space:]]*$' .fb_digest.txt | cat -s | head -c 4200)
  if [ "$(printf '%s' "$D" | wc -c)" -lt 300 ]; then   # AI 幾乎沒濃縮出東西：改用原文的開頭（寧可長一點，也不要把題目弄丟）
    echo "⚠️ AI 濃縮出來的內容太少，改用題目原文的前半段（完整原文在 .fb_full.txt；可以自己編輯 problem.txt 只留重點）。" >&2
    echo "【題目（原文太長，只取開頭；完整原文在 .fb_full.txt）】"; python3 -c 'import sys; t=open(".fb_full.txt",encoding="utf-8",errors="replace").read(); print(t[:2600])'
  else echo "【題目重點（由很長的題目說明濃縮；原文在 .fb_full.txt）】"; printf '%s\n' "$D"; fi
  dg_samples .fb_full.txt
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
unfenced_code() {   # 回覆裡沒有 ``` 時自己找程式碼 → $1/b1.*：C 取 #include（或 main）到最後一個 }；Python 取第一行程式起、從尾端刪到能編譯
  python3 - "$1" <<'FB_PYUNF'
import re, sys
D = sys.argv[1]
L = open(D + "/in.txt", encoding="utf-8", errors="replace").read().replace("\r", "").split("\n")
def save(lang, body):
    for k, v in (("lang", lang), ("info", lang), ("prev", ""), ("tag", "")):
        open(D + "/b1." + k, "w", encoding="utf-8").write(v + "\n")
    open(D + "/b1.body", "w", encoding="utf-8").write("\n".join(body).rstrip("\n") + "\n")
    open(D + "/count", "w").write("1\n"); sys.exit(0)
cjk = re.compile(r"[　-〿一-鿿＀-￯]")
s = next((i for i, l in enumerate(L) if re.match(r"\s*#\s*include\b", l)), None)
if s is None: s = next((i for i, l in enumerate(L) if re.match(r"\s*(int|void)\s+main\s*\(", l)), None)
if s is not None:
    e = max((i for i in range(s, len(L)) if re.match(r"\s*}\s*;?\s*$", L[i])), default=None)
    if e is not None: save("c", L[s:e + 1])
s = next((i for i, l in enumerate(L) if re.match(r"(import\s+\w|from\s+[\w.]+\s+import\s|def\s+\w+\s*\(|class\s+\w+|#!\s*/)", l)), None)
if s is None:
    def codey(l):
        if cjk.search(l) or not re.search(r"[(=]|:\s*$", l): return False
        try: compile(l.strip() if not l.rstrip().endswith(":") else l.strip() + "\n pass", "x", "exec"); return True
        except SyntaxError: return False
    s = next((i for i, l in enumerate(L) if codey(l)), None)
if s is not None:
    body = L[s:]
    for _ in range(30):
        while body and not body[-1].strip(): body.pop()
        if not body: break
        try: compile("\n".join(body) + "\n", "main.py", "exec"); save("python", body)
        except SyntaxError: body.pop()
sys.exit(1)
FB_PYUNF
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
    line ~ /^[ \t]*```/ { if (!infence && pend) { md="out"; ko++; f=D "/" ko ".out"; printf "" > f; got=0; pm=1 }; pend=0
        infence=!infence; if (!infence && md == "in") fdone=1; if (!infence && pm) { md=""; pm=0 }; next }
    !infence && md == "" && line ~ /(輸出|[Oo]utput).*(：|:)[ \t]*$/ && line !~ /格式/ && length(line) <= 150 { pend=1; next }   # 「輸出大概像這樣：」後面緊接 ``` 區塊＝範例輸出（官方 README 的寫法）
    pend && line ~ /[^ \t]/ { pend=0 }
    !infence && line ~ /(範例|樣例|[Ss]ample)[ \t]*(輸入|[Ii]nput)|輸入範例/ { md="in"; fdone=0; ki++; f=D "/" ki ".in"; printf "" > f
        r=rest(line); sub(/^[ \t]+/, "", r); if (r != "") print r >> f; next }
    !infence && line !~ /輸出|[Oo]utput/ && (line ~ /(範例|樣例|[Ss]ample|[Ee]xample)[ \t]*[0-9]*.*(輸入|[Ii]nput|內容)/ && length(line) <= 80 || line ~ /(範例|樣例)[ \t]*[0-9]*[ \t]*(：|:)[ \t]*[A-Za-z0-9_.-]+[.](txt|in|dat)[ \t]*$/) {
        md="in"; fdone=0; ki++; f=D "/" ki ".in"; printf "" > f; next }   # 檔案輸入題：「範例 1：input.txt 內容」「範例：data.txt」
    !infence && line ~ /(範例|樣例|[Ss]ample)[ \t]*[0-9]*[ \t]*(輸出|[Oo]utput)|輸出範例/ { md="out"; ko++; f=D "/" ko ".out"; printf "" > f
        r=rest(line); sub(/^[ \t]+/, "", r); got=0; if (r != "") { print r >> f; got=1 }; next }
    !infence && md == "in" && fdone && line ~ /輸出|[Oo]utput|執行後|結果|[Rr]esult/ && line !~ /輸出格式/ && length(line) <= 90 {
        md="out"; ko++; f=D "/" ko ".out"; printf "" > f; got=0; next }   # 輸入的 ``` 區塊後面的「執行 ./x input.txt 的輸出」「輸出」「執行後 result.txt」
    !infence && line ~ /^[ \t]*(說明|解釋|提示|限制|注意|備註|輸入格式|輸出格式|Explanation|Note|【)/ { md=""; next }
    md == "out" && !infence && line ~ /^[ \t]*$/ && got { md=""; next }   # 輸出後面的空白行＝範例結束
    !infence && line ~ /輸入|[Ii]nput|stdin|讀入|argv|scanf|命令列/ { hasin=1 }
    md != "" { print line >> f; if (line ~ /[^ \t]/) got=1 }
    END { k = ki < ko ? ki : ko
          if (ki == 0 && ko > 0 && !hasin) { for (j = 1; j <= ko; j++) printf "" > (D "/" j ".in"); k = ko }   # 程式不讀輸入（例如 make run 直接印結果）：只有範例輸出 → 輸入當空的
          print k > (D "/count") }' problem.txt
  for f in "$1"/*.in "$1"/*.out; do [ -f "$f" ] && { trim_blank < "$f" > "$f.t"; mv "$f.t" "$f"; }; done
  cat "$1/count"
}
norm() { tr -d ' \t\r\n' ; }
has_starter_c() {   # 考場資料夾裡有「題目提到（寫出路徑或檔名）」或「有 TODO」的 .c 起始檔
  local f; for f in $(find . -maxdepth 2 -type f -name '*.c' ! -path './.fb*' ! -path './tests/*' | sed 's#^\./##'); do
    { grep -qF "$f" problem.txt || grep -q 'TODO' "$f"; } && return 0; done; return 1
}
attach_files() {   # 題目提到的起始檔附在 problem.txt 後面：有 TODO 的（要改的）整份，其他只留程式行；有 .h 的 .c 實作只附 .h；總共約 150 行內（context 只有 4096）
  local P0 ALL f b d body n tot=0 lg L
  P0=$(cat problem.txt)
  ALL=$(find . -maxdepth 2 -type f \( -name '*.[ch]' -o -name '*.py' -o -name '*.pio' -o -name 'Makefile' -o -name 'makefile' \) ! -path './.fb*' ! -path './tests/*' ! -name 'brute.py' ! -name 'gen.py' | sed 's#^\./##' | sort)
  [ -n "$ALL" ] || return 0
  { echo; echo "【專案裡的檔案】$(echo $ALL)"; } >> problem.txt
  for f in $( { grep -l 'TODO' $ALL 2>/dev/null; printf '%s\n' $ALL | grep '\.h$'; printf '%s\n' $ALL; } | awk '!s[$0]++'); do
    b=$(basename "$f"); d=$(dirname "$f"); [[ "$b" == [Mm]akefile ]] && continue
    if ! grep -q 'TODO' "$f"; then
      { [[ "$P0" == *"$f"* ]] || { [ "$d" = . ] && [[ "$P0" == *"$b"* ]]; }; } || continue   # 子資料夾的檔案要寫出路徑才算有提到
      [[ "$f" == *.c ]] && [ -f "${f%.c}.h" ] && printf '%s\n' $ALL | grep -qx "${f%.c}.h" && continue   # 有 .h 就只看介面
    fi
    L=$(grep -m1 -vE '^[[:space:]]*(//.*|/\*.*|\*.*|#.*|;.*)?$' "$f" | sed 's/^[[:space:]]*//')
    [ -n "$L" ] && [[ "$P0" == *"$L"* ]] && continue   # 題目裡已經貼了這個檔案
    case "$f" in *.py) lg=python; body=$(grep -vE '^[[:space:]]*(#.*)?$' "$f") ;; *.pio) lg=text; body=$(cat "$f") ;; *) lg=c; body=$(grep -vE '^[[:space:]]*(//.*|/\*.*|\*.*)?$' "$f") ;; esac
    grep -q 'TODO' "$f" && body=$(cat "$f")
    n=$(printf '%s\n' "$body" | wc -l)
    if [ $((tot + n)) -gt 150 ]; then echo "【專案檔案 $f】（$n 行，太長沒附上）" >> problem.txt; continue; fi
    tot=$((tot + n)); { echo "【專案檔案 $f】"; echo '```'"$lg"; printf '%s\n' "$body"; echo '```'; } >> problem.txt
  done
}

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
         CPSRC="$SRC"; STG=$(cat .stage 2>/dev/null); PV=".fb_pass/$(basename "$SRC")"
         if [ "$STG" != done ] && [ "$STG" != brute ]; then
           if [ -f "$PV" ] && ! cmp -s "$PV" "$SRC"; then CPSRC="$PV"; echo "ℹ️ 目前的程式還沒通過範例，改交「之前通過範例的那一版」（$PV）。"
           elif [ ! -f "$PV" ] && [ -f ".fb_bestall/$(basename "$SRC")" ] && [ "$(cat .fb_bestall_score 2>/dev/null || echo -1)" -gt "$(cat .fb_best_score 2>/dev/null || echo -1)" ]; then CPSRC=".fb_bestall/$(basename "$SRC")"; echo "ℹ️ 還沒有通過範例的版本，改交「目前為止通過最多測資的那一版」（$CPSRC）。"
           else echo "⚠️ 這題在本機還沒通過範例；照樣交出去，但 CI 可能不會過。"; fi
         fi
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
           [ "$CPSRC" != "$SRC" ] && { cp "$SRC" .fb_wip 2>/dev/null; cp "$CPSRC" "$SRC"; echo "（已把 $SRC 換回通過範例的那一版；剛才還在改的版本存在 .fb_wip）"; }
           AFF="$R/.srecruit/answer-files"   # 考場 repo 的「會被評分的檔案」清單
           if [ -f "$AFF" ] && ! sed 's/\r$//' "$AFF" | grep -qxF -- "$D"; then
             C=$(sed 's/\r$//' "$AFF" | grep -E "\.${SRC##*.}\$"); CR=$(realpath --relative-to="$TOP" "$PWD")
             [ "$(printf '%s\n' "$C" | grep -c .)" -gt 1 ] && C=$(printf '%s\n' "$C" | grep -E "^$CR/" )
             if [ "$(printf '%s\n' "$C" | grep -c .)" = 1 ]; then echo "ℹ️ 依 .srecruit/answer-files，程式交到 $C"; D="$C"; mkdir -p "$R/$(dirname "$D")"; cp "$SRC" "$R/$D"
             else echo "⚠️ $D 不在 .srecruit/answer-files（會被評分的是：$(sed 's/\r$//' "$AFF" | tr '\n' ' ')）。照樣交出，但可能不會被評分。"; fi
           fi
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
             EXT="${SRC##*.}"; AFF="$R/.srecruit/answer-files"
             if [ -f "$AFF" ]; then   # 考場 repo 有「會被評分的檔案」清單：只從清單裡選
               mapfile -t FS < <(sed 's/\r$//' "$AFF" | grep -E "\.$EXT\$"); [ ${#FS[@]} -gt 0 ] || mapfile -t FS < <(sed 's/\r$//' "$AFF" | grep -v '^[[:space:]]*$')
               [ ${#FS[@]} -eq 1 ] && { D="${FS[0]}"; echo "ℹ️ 依 .srecruit/answer-files，程式交到 $D"; }
             else mapfile -t FS < <(cd "$R" && git ls-files | grep -E "\.$EXT\$"); fi
           fi
           if [ -z "$D" ]; then
             if [ ${#FS[@]} -gt 0 ]; then
               echo "要交到哪一個檔案？$( [ -f "$AFF" ] && echo '（.srecruit/answer-files 列的會被評分的檔案）')"; i=0; for f in "${FS[@]}"; do i=$((i+1)); echo "  $i) $f"; done
               echo "  0) 都不是 → 自己輸入檔名"
               read -r -p "程式要放到哪一個？（輸入編號，直接 Enter = 1）：" k </dev/tty; k=${k:-1}
               if [ "$k" = 0 ]; then read -r -p "輸入檔名（可含資料夾，例如 q1/main.c）：" D </dev/tty; else D="${FS[$((k-1))]}"; fi
             else
               read -r -p "存成什麼檔名？（照題目規定；題目沒規定就直接 Enter = $(basename "$SRC")）：" D </dev/tty; D=${D:-$(basename "$SRC")}
             fi
           fi
           [ -n "$D" ] || { echo "❌ 沒有檔名"; exit 1; }
           echo "$D" > .fb_dest
           mkdir -p "$R/$(dirname "$D")" && cp "$CPSRC" "$R/$D" || { echo "❌ 複製失敗"; exit 1; }
         fi
         cd "$R" || exit 1
         if [ -f "$R/.srecruit/answer-files" ]; then   # 考場 repo：只交「會被評分的檔案」，不動其他檔（例如考場給的 tests/、Makefile、.gitlab-ci.yml）
           git add -- "$D"; sed 's/\r$//' "$R/.srecruit/answer-files" | grep -v '^[[:space:]]*$' | while read -r a; do [ -f "$a" ] && git add -- "$a"; done
         else git add -u; git add -- "$D"; fi
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
         echo "✅ 已讀 CI 的 log（留最後 $(printf '%s\n' "$LOG" | grep -c .) 行重點）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
         echo "【修正任務】你是上機考解題助手。這個程式在本機的範例測資都通過了，但交到 GitLab 後自動評分（CI）沒有過。下面是題目、目前的程式和 CI 的 log。先用兩句話說 CI 為什麼沒過（常見：隱藏測資的邊界情況、輸出多印或少印、太慢超時、編譯警告被當成錯誤、檔名或讀檔方式和題目不同、Python 版本），再給修正後的完整程式（只給一個程式碼區塊，程式裡不要寫註解）。輸出格式逐字照題目範例；不要心算。"
         echo "【題目】"; cat problem.txt; echo
         [ -f pack.txt ] && { echo "【參考零件】（只是參考；只附前 12 行）"; head -n 12 pack.txt; echo; }
         echo "【目前程式】"; echo "${FENCE}$LT"; cat "$SRC"; echo "$FENCE"
         echo "【CI 的 log（重點，最後 40 行）】"; echo "${FENCE}text"; printf '%s\n' "$LOG"; echo "$FENCE"
         exit 0 ;;
  task)  # 任務模式：不是「寫一支程式」的題目（要下指令觀察、改設定／Makefile、解 git 衝突、在專案裡找要改哪裡）→ AI 給檔案與指令，fb 確認後照做並回報
         if [ "$2" = done ]; then echo done > .task_stage; echo "✅ 已標記這個任務完成。要交卷就打 fb submit。"; exit 0; fi
         if [ "$2" = reset ]; then rm -rf .task_stage .task.txt .task_log .task_last .task_orig .task_af .fb_full.txt .fb_chunk .fb_digest.txt .fb_dg_i; echo "任務模式已清空。重新開始：fb task"; exit 0; fi
         TS=$(cat .task_stage 2>/dev/null || echo start)
         [ "$TS" = done ] && { echo "✅ 這個任務 AI 已經說完成了。要重來：fb task reset"; exit 0; }
         task_prompt() {
           echo "你是上機考助手，要幫我在 Linux 終端機（bash；可能有 ROS 2 Jazzy、gcc、make、python3，沒有 sudo）完成下面的【任務】。你不能直接操作電腦：每一輪你給我「要寫入的檔案」和「要執行的指令」，我照做後把結果貼給你。"
           echo "規則：1. 建立或修改檔案：程式碼區塊的前一行寫「FILE: 檔名」（用目前資料夾底下的相對路徑），區塊裡放該檔案修改後的『完整內容』；Makefile 的指令行用 Tab 開頭。2. 要執行的指令放在一個 ${FENCE}bash 區塊。不要把輸出導到檔案（不要用 > xxx.txt），直接印出來我才看得到。不要寫 <名稱> 這種佔位字，要用【上一步的結果】裡的實際名稱。3. 題目給的檔案，除非題目要你改，否則不要改寫它，用指令執行或查看就好。不要用 vim、nano、sudo。4. 先 cat 看懂題目給的檔案，一次只做一小步，只做和【任務】有關的事。5. 任務全部完成也驗證過，就只回覆【完成】加一句說明，不要再給指令。"
           ISROS=0; grep -qiE 'ros|topic|節點|service' .task.txt && ISROS=1
           [ $ISROS -eq 1 ] && echo "ROS 提示：要觀察題目給的節點，用 timeout 60 python3 檔名.py & 接著 sleep 3 再用 ros2 指令看；ros2 topic echo 要加 timeout 5。下面【目前在跑的 ROS…】是 fb 自動查到的實際名稱，答案要以它為準。"
           echo "【任務】"; head -c 3000 .task.txt; [ "$(wc -c < .task.txt)" -gt 3000 ] && echo "…（任務太長已截斷；完整內容可用 cat .task.txt 查看）"; echo
           echo "【目前資料夾】$(pwd)；檔案：$(ls -p | grep -v '^\.' | head -25 | tr '\n' ' ')"
           [ -s .task_af ] && echo "【會被評分的檔案（作答只改這些；.gitlab-ci.yml 不要改）】$(tr '\n' ' ' < .task_af)"
           if [ -f /opt/ros/jazzy/setup.bash ] && [ $ISROS -eq 1 ]; then   # 自動附上目前的 ROS 圖，AI 不用自己找
             RG=$( (source /opt/ros/jazzy/setup.bash >/dev/null 2>&1; N=$(timeout 8 ros2 node list 2>/dev/null); [ -n "$N" ] && { echo "節點：$(echo "$N" | tr '\n' ' ')"; timeout 8 ros2 topic list -t 2>/dev/null | grep -vE '^/(rosout|parameter_events) ' | sed 's/^/topic /'; timeout 8 ros2 service list -t 2>/dev/null | grep -vE '_parameters|parameter_types|type_description' | sed 's/^/service /'; }) | head -20 | cut -c1-150)
             [ -n "$RG" ] && { echo "【目前在跑的 ROS 節點、topic（含型別）、service】"; echo "$RG"; }
           fi
           echo "【到目前為止做過的事】"; if [ -s .task_log ]; then tail -c 600 .task_log; else echo "（還沒開始）"; fi
           [ -s .task_last ] && { echo "【上一步的結果】"; head -c 900 .task_last; echo; }
           if [ -s .task_last ]; then echo "先判斷：只有在【上一步的結果】清楚顯示【任務】的每一項要求都已經達成（該改的檔案改了、驗證的輸出正確、該寫的檔案寫了），才只回覆【完成】加一句說明；否則給下一步。"
           else echo "請給第一步。"; fi
         }
         done_ok() {   # AI 說【完成】時檢查：結果還有錯誤訊息、或題目要的輸出檔還沒寫 → 不算完成（印出原因）
           local r="" f
           grep -qiE 'error|錯誤|traceback|missing separator|no such file|not found|failed|（結束碼 [1-9]' .task_last 2>/dev/null && r="（你說完成了，但上一步的結果裡還有錯誤訊息或結束碼不是 0，還不算完成。）"
           for f in $(grep -oE '[A-Za-z0-9_./-]+\.(txt|md|csv|json|yaml|yml|log|out)' .task.txt | sort -u); do
             grep -qiE "(寫進|寫入|寫到|存到|存成|存進|輸出到|產生|建立|記錄|write|save|output|record).{0,40}$f|$f.{0,12}(裡|中|檔)" .task.txt || continue
             [ -s "$f" ] || r="$r（你說完成了，但題目要的 $f 還沒寫出來或是空的：請用「FILE: $f」加程式碼區塊寫入完整內容。）"
           done
           if grep -qiE '修改|修正|修好|修復|補完|補上|實作|改寫|改成|改好|改為|新增|加上|TODO|fix|implement|modify|edit|complete|update|解決|resolve' .task.txt && ! grep -q '寫入' .task_log 2>/dev/null; then
             r="$r（你說完成了，但題目要你修改檔案，你還沒有用「FILE: 檔名」寫入任何檔案。）"
           elif grep -q '寫入' .task_log 2>/dev/null && [ "$(grep -nE '寫入|→ 結束碼' .task_log | tail -1 | grep -c '寫入')" = 1 ]; then
             r="$r（你說完成了，但改完檔案之後還沒有執行指令驗證（例如 make、執行程式），請先驗證。）"
           fi
           printf '%s' "$r"
         }
         if [ "$TS" = start ]; then H="題目／任務（整段）"; else H="AI 的整段回覆"; fi
         echo "👉 請貼上【$H】，貼完按 Enter，再按 Ctrl-D" >&2
         if [ -t 0 ] && trap "stty icanon 2>/dev/null" EXIT INT && stty -icanon 2>/dev/null; then
           IFS= read -r -d "$(printf '\004')" IN; stty icanon 2>/dev/null; echo >&2
         else IN=$(cat); fi
         [ -n "$IN" ] || { echo "沒有貼到任何東西" >&2; exit 1; }
         if [ "$TS" = digest ]; then   # 長題目濃縮中（和 fb 一般流程共用 dg_* 函式）
           DI=$(cat .fb_dg_i 2>/dev/null || echo 1); DK=$(ls .fb_chunk 2>/dev/null | wc -l); printf '%s\n' "$IN" >> .fb_digest.txt
           if [ "$DI" -lt "$DK" ]; then
             echo $((DI+1)) > .fb_dg_i
             echo "✅ 第 $DI／$DK 段的重點收到了。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
             print_digest $((DI+1)) "$DK"; exit 0
           fi
           IN=$(dg_finish); TS=start; DIGESTED=1
           echo "✅ 題目濃縮完成（原文在 .fb_full.txt）。" >&2
         fi
         if [ "$TS" = start ] && [ -z "$DIGESTED" ] && [ "${DIGEST:-1}" = 1 ] && [ "$(printf '%s' "$IN" | est_tok)" -gt 900 ]; then   # 任務說明太長：先分段濃縮
           printf '%s\n' "$IN" > .fb_full.txt; DK=$(dg_split .fb_full.txt); : > .fb_digest.txt; echo 1 > .fb_dg_i; echo digest > .task_stage
           echo "ℹ️ 題目很長（考場 AI 一次看不完）：先分 $DK 段請 AI 濃縮成重點，共要貼 $DK 次。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
           print_digest 1 "$DK"; exit 0
         fi
         if [ "$TS" = start ]; then
           printf '%s\n' "$IN" > .task.txt; : > .task_log; rm -f .task_last; echo run > .task_stage
           find . -maxdepth 3 -type f ! -path './.*' ! -path '*/.git/*' 2>/dev/null | sed 's#^\./##' > .task_orig   # 題目原本就有的檔案（之後 AI 要改寫，題目得有叫它改）
           TOPD=$(git rev-parse --show-toplevel 2>/dev/null); : > .task_af
           [ -n "$TOPD" ] && [ -f "$TOPD/.srecruit/answer-files" ] && sed 's/\r$//' "$TOPD/.srecruit/answer-files" | grep -v '^[[:space:]]*$' | while read -r a; do realpath -m --relative-to="$PWD" "$TOPD/$a"; done > .task_af   # 會被評分的檔案
           GD=$(git rev-parse --git-dir 2>/dev/null) && for x in '.task*' '.fb_*' '.fb_task_bak/' '.stage' '.sid' '.mode' '.pack_manual' 'pack.txt' 'problem.txt' 'node.log' 'verify.out'; do   # fb 的暫存檔不要被 git add -A 交出去（只寫在本機 .git/info/exclude）
             grep -qxF "$x" "$GD/info/exclude" 2>/dev/null || echo "$x" >> "$GD/info/exclude"; done
           echo "✅ 已存任務（任務模式）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
           task_prompt; exit 0
         fi
         T=$(mktemp -d); printf '%s\n' "$IN" > "$T/in.txt"; split_blocks "$T"; NB=$(cat "$T/count")
         FILES=""; : > "$T/cmd.sh"; SKIP=""; WARN=""
         PEND=""
         for i in $(seq 1 "$NB"); do
           lg=$(tr 'A-Z' 'a-z' < "$T/b$i.lang" | tr -d ' \r'); B="$T/b$i.body"; P=""
           if [ "$(grep -c . "$B")" -le 1 ] && grep -qE '^[[:space:]]*(FILE|檔案|檔名)[[:space:]]*(:|：)' "$B"; then   # 「```text」裡只有一行 FILE: x → 是下一個區塊的檔名
             PEND=$(sed -nE 's/^[[:space:]]*(FILE|檔案|檔名)[[:space:]]*(:|：)[[:space:]]*`?([^` ]+)`?.*/\3/p' "$B" | head -1); continue; fi
           [ -n "$PEND" ] && { P="$PEND"; PEND=""; }
           # 區塊前一行的「FILE: 路徑」只算給緊接著的那一個區塊（下一個區塊沿用同一行＝不是它的檔名）
           if [ -n "$P" ] || { [ "$i" -gt 1 ] && cmp -s "$T/b$i.prev" "$T/b$((i-1)).prev"; }; then :
           else P=$(sed -nE 's/.*(FILE|File|file|檔案|檔名)[[:space:]]*(:|：)[[:space:]]*`?([^` ]+)`?.*/\3/p' "$T/b$i.prev" | head -1); fi
           [ -z "$P" ] && P=$(head -1 "$B" | sed -nE 's#^[[:space:]]*(//|\#|--|;)[[:space:]]*(FILE|檔案)[[:space:]]*(:|：)[[:space:]]*([^ ]+).*#\4#p')
           [ -z "$P" ] && P=$(sed -nE 's/^[A-Za-z0-9+#-]*[[:space:]]+(title=)?"?([A-Za-z0-9_./-]+\.[A-Za-z0-9]+|Makefile)"?.*/\2/p' "$T/b$i.info" | head -1)
           P=$(printf '%s' "$P" | sed -E "s/^[*\"'\`]+//; s/[*\"'\`，。：:）)]+\$//")   # FILE: **Makefile**、「`main.c`。」之類的符號去掉
           if [ -n "$P" ]; then
             case "$P" in "$PWD"/*) P="${P#"$PWD"/}" ;; esac   # AI 常寫成絕對路徑：在目前資料夾底下就換成相對路徑
             case "$P" in /etc/*|/usr/*|/bin/*|/sbin/*|/boot/*|/proc/*|/sys/*|/dev/*|/lib*) WARN="$WARN（沒有寫入 $P：系統資料夾不能改，請用目前資料夾底下的相對路徑）"$'\n'; continue ;; esac
             case "$P" in .task*|.fb*|task.txt) WARN="$WARN（沒有寫入 $P：那是 fb 自己的檔案）"$'\n'; continue ;; esac
             if grep -qxF -- "$P" .task_orig 2>/dev/null && ! grep -qxF -- "$P" .task_af 2>/dev/null; then   # 題目原本就有的檔案：題目要「改」它才准寫（.srecruit/answer-files 列的評分檔可以改）
               if ! grep -qiE '修改|修正|修好|修復|補完|補上|實作|改寫|改成|改好|改為|新增|加上|TODO|fix|implement|modify|edit|complete|update' .task.txt; then
                 WARN="$WARN（沒有寫入 $P：這是題目給的檔案，題目沒有要你改它；請用指令執行或 cat 查看它）"$'\n'; continue; fi
               if ! grep -qF -- "$(basename "$P")" .task.txt && grep -qiE '[A-Za-z0-9_]\.(c|h|py|cpp|sh|yaml|yml|json|xml)([^A-Za-z]|$)|Makefile' .task.txt; then
                 WARN="$WARN（沒有寫入 $P：題目要改的不是這個檔案；只改題目提到的檔案）"$'\n'; continue; fi
             fi
             grep -qE '^[[:space:]]*(//|#|--|;)[[:space:]]*(FILE|檔案)[[:space:]]*(:|：)' <(head -1 "$B") && sed -i '1d' "$B"
             FILES="$FILES$P"$'\n'; cp "$B" "$T/f$i"; echo "$P" > "$T/f$i.path"
           elif [[ "$lg" =~ ^(bash|sh|shell|console|zsh|terminal)$ ]] || { [ -z "$lg" ] && grep -qE '^[[:space:]]*(\$ )?(ls|cat|cd|make|gcc|python3?|ros2|git|grep|echo|mkdir|cp|mv|sed|timeout|source|chmod|\./)' "$B"; }; then
             sed -E 's/^[[:space:]]*\$ //' "$B" >> "$T/cmd.sh"; echo >> "$T/cmd.sh"
           else SKIP="$SKIP ${lg:-無標籤}"; fi
         done
         DONE=0; grep -q '【完成】' "$T/in.txt" && DONE=1
         if [ -z "$FILES" ] && [ ! -s "$T/cmd.sh" ]; then
           if [ -n "$WARN" ]; then printf '%s' "$WARN" > .task_last; echo "⚠️ $WARN把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2; task_prompt; rm -rf "$T"; exit 0; fi
           if [ $DONE -eq 1 ] && R=$(done_ok) && [ -n "$R" ]; then
             { echo "$R"; cat .task_last 2>/dev/null; } > "$T/l" && mv "$T/l" .task_last
             echo "⚠️ AI 說完成了，但 fb 檢查還沒完成：$R" >&2; echo "把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2; task_prompt; rm -rf "$T"; exit 0; fi
           if [ $DONE -eq 1 ]; then echo done > .task_stage; echo "✅ AI 說任務完成了：$(grep -m1 '【完成】' "$T/in.txt" | cut -c1-150)" >&2
             echo "👉 自己確認一下結果（例如 fb test、make、看檔案）；要交卷就打 fb submit，或照考場規定 git add／commit／push。" >&2; rm -rf "$T"; exit 0; fi
           echo "⚠️ AI 的回覆裡沒有「FILE: 路徑」的檔案，也沒有 bash 指令。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
           echo "（上一次你沒有照格式回答${SKIP:+：你給的程式碼區塊沒有寫「FILE: 路徑」，我不知道要存到哪個檔案}。請照規則給下一步。）"; task_prompt; rm -rf "$T"; exit 0
         fi
         echo "======== AI 要做的事 ========" >&2
         [ -n "$FILES" ] && { echo "📝 寫入檔案：$(printf '%s' "$FILES" | tr '\n' ' ')" >&2; }
         [ -s "$T/cmd.sh" ] && { echo "▶️ 執行指令："; sed 's/^/   /' "$T/cmd.sh" | head -20; } >&2
         [ -n "$SKIP" ] && echo "（略過沒寫 FILE: 路徑的程式碼區塊：$SKIP）" >&2
         if [ -z "$FB_YES" ] && [ -r /dev/tty ]; then
           read -r -p "要照做嗎？直接按 Enter＝照做；打 n 再按 Enter＝不要：" ok </dev/tty 2>/dev/null
           [ "$ok" = n ] || [ "$ok" = N ] && { echo "已取消，什麼都沒做。要重新問 AI：把上一輪的內容再貼一次給 AI（或 fb task reset 重來）。"; rm -rf "$T"; exit 0; }
         fi
         N=$(( $(grep -c '^第 [0-9]* 步' .task_log 2>/dev/null) + 1 ))
         { echo "第 $N 步："; } >> .task_log
         if [ -n "$FILES" ]; then BK=".fb_task_bak/$(date +%H%M%S)"
           for f in "$T"/f*.path; do [ -f "$f" ] || continue; P=$(cat "$f")
             [ -e "$P" ] && { mkdir -p "$BK/$(dirname "$P")"; cp "$P" "$BK/$P"; }
             mkdir -p "$(dirname "$P")"; cp "${f%.path}" "$P"; [[ "$P" == *.sh ]] && chmod +x "$P"
             case "$(basename "$P")" in [Mm]akefile|GNUmakefile|*.mk) sed -i -E 's/^ +/\t/' "$P" ;; esac   # 網頁複製常把 Tab 變空白：Makefile 開頭的空白一律換回 Tab
           done
           echo "  寫入 $(printf '%s' "$FILES" | tr '\n' ' ')" >> .task_log; echo "📝 已寫入（舊檔備份在 ${BK}/）" >&2
         fi
         if [ -n "$FILES" ]; then   # 寫了檔：fb 先自動建置／檢查（make、cmake、語法檢查、印出答案檔），小模型常忘了建置或驗證
           { echo "# fb 自動建置／檢查"
             printf '%s' "$FILES" | grep -qiE '(^|/)(GNUmakefile|[Mm]akefile)$|\.(c|h|mk|pio|s|S|cpp)$' && { [ -f Makefile ] || [ -f makefile ]; } && echo 'make 2>&1 | tail -n 15'
             printf '%s' "$FILES" | grep -qiE '(^|/)CMakeLists\.txt$|\.(c|h|pio|s|S|cpp|cmake)$' && [ -f CMakeLists.txt ] && ! { [ -f Makefile ] || [ -f makefile ]; } && echo 'cmake -S . -B build > build_cmake.log 2>&1 || tail -n 15 build_cmake.log; cmake --build build 2>&1 | grep -iE "error|warning|undefined|\[100%\]|Built target" | head -n 20'
             printf '%s' "$FILES" | grep -E '\.c$' | while read -r f; do { [ -f Makefile ] || [ -f makefile ] || [ -f CMakeLists.txt ]; } || echo "gcc -fsyntax-only -Wall '$f' 2>&1 | head -n 10"; done
             printf '%s' "$FILES" | grep -E '\.py$' | while read -r f; do echo "python3 -m py_compile '$f' && echo '$f 語法正確'"; done
             printf '%s' "$FILES" | grep -iE '\.(txt|md|csv|json|ya?ml|out|log)$' | while read -r f; do echo "echo '== $f：'; head -n 20 '$f'"; done
           } > "$T/auto.sh"
           if [ "$(wc -l < "$T/auto.sh")" -gt 1 ] && ! grep -qE '(^|[;&|[:space:]])(make|cmake|gcc|cc)([[:space:]]|$)' "$T/cmd.sh"; then
             { cat "$T/auto.sh"; echo "# AI 給的指令"; cat "$T/cmd.sh"; } > "$T/c2" && mv "$T/c2" "$T/cmd.sh"   # AI 自己有 make／gcc 就不重複建置
           fi
         fi
         if [ -s "$T/cmd.sh" ]; then
           { echo '[ -f /opt/ros/jazzy/setup.bash ] && source /opt/ros/jazzy/setup.bash >/dev/null 2>&1'; cat "$T/cmd.sh"; } > "$T/run.sh"
           timeout "${TTO:-60}" bash "$T/run.sh" > "$T/out" 2>&1 < /dev/null; RC=$?
           for rf in $(grep -oE '(^|[^2&])>>?[[:space:]]*[A-Za-z0-9_./-]+' "$T/cmd.sh" | sed -E 's/^.?>>?[[:space:]]*//' | grep -vE '^/dev/|^build_cmake\.log$' | sort -u | head -5); do   # 指令把輸出存進檔案 → 幫 AI 印出來
             [ -f "$rf" ] && { echo "== $rf 的內容（指令把輸出存進檔案，fb 幫你印出來）："; head -n 15 "$rf" | cut -c1-160; } >> "$T/out"; done
           { printf '%s' "$WARN"; tail -n 50 "$T/out" | cut -c1-200; [ $RC -eq 124 ] && echo "（指令超過 ${TTO:-60} 秒被中止）"; echo "（結束碼 $RC）"; } > .task_last
           echo "--- 指令輸出（最後 25 行）---" >&2; tail -n 25 .task_last >&2
           { sed 's/^/  $ /' "$T/cmd.sh" | grep -v '^  \$ $' | head -4 | cut -c1-120; echo "  → 結束碼 $RC；輸出：$(grep -v '^（結束碼' .task_last | head -2 | tr '\n' ' ' | cut -c1-140)"; } >> .task_log
         else { printf '%s' "$WARN"; echo "（這一步只有寫檔，沒有指令）"; } > .task_last; fi
         if [ $DONE -eq 1 ]; then R=$(done_ok)
           if [ -n "$R" ]; then echo "$R" >> .task_last; echo "⚠️ AI 說完成了，但 fb 檢查還沒完成：$R" >&2
           else echo done > .task_stage; echo "✅ AI 說任務完成了。自己確認一下結果；要交卷就打 fb submit。" >&2; rm -rf "$T"; exit 0; fi
         fi
         echo "✅ 照做完了。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb task 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
         task_prompt; rm -rf "$T"; exit 0 ;;
  reset) B=".fb_old/$(date +%m%d_%H%M%S)"; mkdir -p "$B"   # 不直接刪：搬到 .fb_old/，考場原本的檔案從 .fb_bak/ 還原
         for f in .stage .sid .mode .pack_manual .fb_io .fb_target .fb_prog .fb_pass .fb_app .fb_brute_retry .fb_bf .fb_genbad .fb_stamp .fb_stress_ok .fb_main .fb_best .fb_best_score .fb_att_best .fb_att_fix .fb_restarts .fb_bestall .fb_bestall_score .fb_full.txt .fb_chunk .fb_digest.txt .fb_dg_i .fb_prompt.txt brute.py gen.py problem.txt pack.txt main.c main.cpp main.py .fb_sig .fb_n tests verify.sh expected.txt node.log node1.log verify.out; do
           [ -e "$f" ] && mv "$f" "$B/"; done
         if [ -d .fb_bak ]; then cp -r .fb_bak/. . && echo "（已還原考場原本的檔案：$(ls -A .fb_bak | tr '\n' ' ')）"; rm -rf .fb_bak; fi
         echo "已清空（舊檔在 $B）。開始新的一題：fb 然後貼上題目"; exit 0 ;;
  test)  [ "$(cat .mode 2>/dev/null)" = ros ] && exec bash "$SELF" checkros
         [ "$(cat .mode 2>/dev/null)" = proj ] && [ -s .fb_target ] && PROJ=1 exec bash "$SELF" check "$(cat .fb_target)"
         for f in main.c main.cpp main.py; do [ -f "$f" ] && exec bash "$SELF" check "$f"; done
         echo "還沒有程式"; exit 1 ;;
  pack)  get_pack "$2" && { echo "$2" > .pack_manual; echo "已換成情境 $2（之後每一輪都會附這個包，不會被 AI 選的蓋掉）"; } || echo "packs.txt 裡沒有 $2"; exit 0 ;;
  skip)  echo done > .stage; echo "已標記這一題完成（略過剩下的步驟）。下一題：cd 到下一題的資料夾，或 fb reset"; exit 0 ;;
  io)    case "$2" in   # 題目不是 stdin/stdout：fb io argv（檔名當命令列參數）／fb io in input.txt（從檔案讀）／fb io out output.txt（寫到檔案）／fb io std（還原）
           argv) grep -v '^IO_ARGV=' .fb_io 2>/dev/null > .fb_io.t; echo "IO_ARGV=1" >> .fb_io.t; mv .fb_io.t .fb_io ;;
           in)   grep -v '^IO_IN=' .fb_io 2>/dev/null > .fb_io.t; echo "IO_IN=${3:-input.txt}" >> .fb_io.t; mv .fb_io.t .fb_io ;;
           out)  grep -v '^IO_OUT=' .fb_io 2>/dev/null > .fb_io.t; echo "IO_OUT=${3:-output.txt}" >> .fb_io.t; mv .fb_io.t .fb_io ;;
           *)    rm -f .fb_io ;;
         esac
         echo "測資的輸入輸出方式：$(tr '\n' ' ' < .fb_io 2>/dev/null)$( [ -f .fb_io ] || echo 'stdin → stdout')"; exit 0 ;;
  mode)  case "$2" in std|ros|proj) echo "$2" > .mode; echo "已改成題型：$2" >&2 ;; *) echo "用法：fb mode std（一般）｜ros（ROS 2）｜proj（多檔案專案＋Makefile）"; exit 1 ;; esac
         if [ "$(cat .stage 2>/dev/null)" = select ]; then
           echo "把下面整段複製，到 AI 開新對話貼上（取代剛才那段）：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
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
if [ "$NB" -eq 0 ] && [[ "$STAGE" =~ ^(write|fix)$ ]] && unfenced_code "$T"; then   # 從網頁「反白複製」時 ``` 會不見
  NB=1; echo "ℹ️ 回覆裡沒有 \`\`\` 區塊（多半是用滑鼠反白複製時不見了），fb 已自己找出程式碼。下次可改按 AI 回答下方的「複製」按鈕。" >&2
fi

if [ "$STAGE" = digest ]; then   # 長題目濃縮中：收第 i 段的重點；全部收完就把「重點＋原文範例」當成題目，接著走一般流程
  DI=$(cat .fb_dg_i 2>/dev/null || echo 1); DK=$(ls .fb_chunk 2>/dev/null | wc -l)
  printf '%s\n' "$IN" >> .fb_digest.txt
  if [ "$DI" -lt "$DK" ]; then
    echo $((DI+1)) > .fb_dg_i
    echo "✅ 第 $DI／$DK 段的重點收到了。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
    print_digest $((DI+1)) "$DK"; rm -rf "$T"; exit 0
  fi
  IN=$(dg_finish); STAGE=start; DIGESTED=1
  echo "✅ 題目濃縮完成（$DK 段 → 約 $(printf '%s' "$IN" | est_tok) token；原文在 .fb_full.txt，濃縮結果會存成 problem.txt，覺得漏了重點可以自己用編輯器補）。" >&2
fi
case "$STAGE" in
  start)
    if [ -z "$DIGESTED" ] && [ "${DIGEST:-1}" = 1 ] && [ "$(printf '%s' "$IN" | est_tok)" -gt 1500 ]; then   # 題目太長：先分段請 AI 濃縮（DIGEST=0 可關）
      printf '%s\n' "$IN" > .fb_full.txt; K=$(dg_split .fb_full.txt); : > .fb_digest.txt; echo 1 > .fb_dg_i; echo digest > .stage
      echo "ℹ️ 題目很長（約 $(est_tok < .fb_full.txt) token，考場 AI 一次看不完）：先分 $K 段請 AI 濃縮成重點，共要貼 $K 次。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
      print_digest 1 "$K"; rm -rf "$T"; exit 0
    fi
    printf '%s\n' "$IN" > problem.txt; echo select > .stage
    TOPD=$(git rev-parse --show-toplevel 2>/dev/null)
    if [ -n "$TOPD" ] && [ -f "$TOPD/.srecruit/answer-files" ]; then   # 考場 repo：.srecruit/answer-files＝會被評分的檔案 → 寫進題目，fb 與 AI 都只改這些
      AFR=$(sed 's/\r$//' "$TOPD/.srecruit/answer-files" | grep -v '^[[:space:]]*$' | while read -r a; do realpath -m --relative-to="$PWD" "$TOPD/$a"; done | tr '\n' ' ')
      echo "【會被評分的檔案（只改這些）】$AFR" >> problem.txt; echo "ℹ️ 這個作答 repo 會被評分的檔案：$AFR" >&2
      echo "$AFR" | grep -q '[.]py' && ! echo "$AFR" | grep -qE '[.](c|h)( |$)' && echo "（評分檔是 .py：請使用 Python 3 作答）" >> problem.txt
    fi
    for f in main.c main.py tests; do   # 考場資料夾原本就有的檔案先備份（fb 之後會覆寫 main.c、重建 tests/）
      [ -e "$f" ] && [ ! -e ".fb_bak/$f" ] && { mkdir -p .fb_bak; cp -r "$f" .fb_bak/; echo "⚠️ 資料夾裡原本就有 $f，已備份到 .fb_bak/（fb reset 會還原）" >&2; }
    done
    # 題型判斷：只看 ROS 專屬字；「節點／topic」單獨出現不算（鏈結串列、樹、圖、MQTT 題都會有）
    # 題目有「範例輸入／標準輸入」＝從 stdin 讀資料的一般程式題（例如「統計 ROS 2 日誌」），就算提到 ROS 也不是要寫節點
    if ! grep -qiE '範例輸入|輸入範例|sample input|標準輸入|stdin' problem.txt && { grep -qiE 'rclpy|rclcpp|ros ?2|ros2 |std_msgs|geometry_msgs|sensor_msgs|std_srvs|example_interfaces|/opt/ros|colcon|jazzy|humble' problem.txt \
       || { grep -qiE '訂閱|subscri' problem.txt && grep -qiE '發佈|發布|publish' problem.txt && grep -qiE 'topic|主題|節點|node' problem.txt; }; }; then echo ros > .mode
    elif [ -f Makefile ] || [ -f makefile ] || has_starter_c; then echo proj > .mode   # 有 Makefile，或題目提到／有 TODO 的 .c 起始檔（沒有 Makefile 時用 gcc 編）；無關的 .c 不算
    else echo std > .mode; fi
    attach_files   # 考場資料夾裡題目提到的起始檔（.c/.h/.py/.pio）附在題目後面，AI 才看得到 TODO／要修的程式
    if [ "$(cat .mode)" = ros ]; then   # ROS 題有 TODO 的起始 .py（例如 processor.py）：AI 的程式也寫進這個檔（交卷檔名不變）
      T0=$(grep -l 'TODO' $(find . -maxdepth 2 -name '*.py' ! -path './.fb*') 2>/dev/null | head -1); [ -n "$T0" ] && echo "${T0#./}" > .fb_target
    fi
    rm -f .fb_io   # 題目要求從命令列參數／檔案讀寫時，測資也照這個方式餵（判斷錯就 fb io std）
    PT=$(sed '/^【專案裡的檔案】/,$d' problem.txt)   # 只看題目本身（附上的起始程式裡常有 argv，不能拿來判斷）
    if grep -qiE 'argv|命令列參數|命令列引數|command[- ]line arg' <<< "$PT"; then echo "IO_ARGV=1" >> .fb_io; fi
    FI=$(grep -oE '從[^，。]{0,8}[A-Za-z0-9_.-]+[.](txt|in|dat)' <<< "$PT" | grep -oE '[A-Za-z0-9_.-]+[.](txt|in|dat)$' | head -1)
    [ -n "$FI" ] && ! grep -q IO_ARGV .fb_io 2>/dev/null && echo "IO_IN=$FI" >> .fb_io
    FO=$(grep -oE '(寫到|寫入|輸出到|存到)[^，。]{0,8}[A-Za-z0-9_.-]+[.](txt|out|dat)' <<< "$PT" | grep -oE '[A-Za-z0-9_.-]+[.](txt|out|dat)$' | head -1)
    [ -n "$FO" ] && echo "IO_OUT=$FO" >> .fb_io
    [ -f .fb_io ] && echo "ℹ️ 這題的輸入輸出不是 stdin/stdout：$(tr '\n' ' ' < .fb_io)（判斷錯就打 fb io std）" >&2
    case "$(cat .mode)" in ros) MN='ROS 2' ;; proj) MN="考場起始檔專案（$( [ -f Makefile ] || [ -f makefile ] && echo '用 make 編譯' || echo '沒有 Makefile，用 gcc 編譯')；AI 會直接改起始檔）" ;; *) MN='一般輸入輸出' ;; esac
    echo "✅ 已存題目（題型：$MN；判斷錯了就打 fb mode std／fb mode ros／fb mode proj）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
    if [ "$(cat .mode)" = ros ]; then print_select_ros; else print_select; fi
    TK=$(python3 -c 'import sys; t=open("problem.txt",encoding="utf-8",errors="replace").read(); c=sum(1 for ch in t if ord(ch)>0x2e7f); print(c+(len(t)-c)//3)' 2>/dev/null)
    [ "${TK:-0}" -gt 2200 ] && echo "⚠️ 題目（含附檔）約 $TK token，考場 AI 一次只能看約 4096 token，之後加上程式和回報會被截掉。建議 fb reset，重貼時只留「要做什麼＋輸入輸出格式＋範例」，刪掉背景說明、安裝步驟、和這題無關的段落。" >&2 ;;
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
      echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
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
      [ -z "$y" ] && BADC=1   # AI 給了空的範例輸出（常見於「沒有輸入、直接執行」的題目）
    done
    for j in $(seq $((k+1)) 99); do rm -f "tests/$j.in" "tests/$j.out"; done
    for f in .fb_bak/tests/*.in; do   # 考場資料夾原本就附的測資（.in／.out 成對）也一起用，檔名加 x_ 避免和範例撞名
      [ -f "$f" ] && [ -f "${f%.in}.out" ] && { cp "$f" "tests/x_$(basename "$f")"; cp "${f%.in}.out" "tests/x_$(basename "${f%.in}").out"; XT=$((${XT:-0}+1)); }
    done; [ "${XT:-0}" -gt 0 ] && echo "ℹ️ 另外加入考場資料夾原本附的 $XT 組測資" >&2
    if [ "$k" -eq 0 ] || [ "$BADC" -eq 1 ]; then   # 備案：fb 自己從題目抓範例
      ke=$(extract_samples "$T/ex")
      if [ "${ke:-0}" -gt 0 ]; then rm -rf tests; mkdir -p tests
        for j in $(seq 1 "$ke"); do cp "$T/ex/$j.in" "tests/$j.in"; cp "$T/ex/$j.out" "tests/$j.out"; done
        echo "✅ 改用 fb 直接從題目抓到的 $ke 組範例（AI 抄的不完整或抄錯）" >&2; k=$ke; fi
    fi
    for j in $(seq 1 "$k"); do [ -n "$(norm < "tests/$j.out")" ] && continue   # 還是空的預期輸出：這組不能用（不然永遠比不過）
      rm -f tests/$j.in tests/$j.out; echo "⚠️ 第 $j 組範例的預期輸出是空的，已刪掉這組" >&2; done
    k=$(ls tests/*.out 2>/dev/null | wc -l)
    j=0; for f in $(ls tests/*.out 2>/dev/null | sort -V); do j=$((j+1)); [ "$f" = "tests/$j.out" ] || { mv "${f%.out}.in" "tests/$j.in"; mv "$f" "tests/$j.out"; }; done
    SID=$(grep -o 'S[0-9][0-9]' "$T/in.txt" | head -1)
    [ -f .pack_manual ] && SID=$(cat .pack_manual)   # 考生用 fb pack 指定過就以考生為準
    [ -n "$SID" ] && echo "$SID" > .sid
    rm -f pack.txt; [ -n "$SID" ] && get_pack "$SID"
    echo write > .stage
    echo "✅ 建了 $k 組測資；情境：${SID:-無}。把下面整段複製，到 AI 開新對話貼上：" >&2
    [ "$k" -eq 0 ] && echo "⚠️ AI 沒照格式抄範例，所以沒有測資；之後只能直接執行看輸出。" >&2
    echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
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
      echo "⚠️ 沒拿到兩個 Python 區塊（暴力解＋產生器）。把下面整段複製，到 AI 開新對話貼上（或打 fb skip 略過對拍）：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
      echo "（上一次你沒有給兩個 ${FENCE}python 區塊。第一個是暴力解，第二個是產生器。）"; print_brute; rm -rf "$T"; exit 0
    fi
    cp "$T/b$BR.body" brute.py; cp "$T/b$GE.body" gen.py
    for f in brute.py gen.py; do   # 只定義了函式、沒有任何頂層呼叫（小模型常這樣）→ 在最後補上呼叫第一個函式
      if ! grep -qE '^[A-Za-z_][A-Za-z0-9_.]*[[:space:]]*[(]|^if __name__|^print|^for |^while |^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' "$f"; then
        fn=$(grep -m1 -oE '^def[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$f" | awk '{print $2}'); [ -n "$fn" ] && { echo "$fn()" >> "$f"; echo "（$f 只有定義函式，已補上呼叫 $fn()）" >&2; }
      fi
    done
    SRCF=$(ls main.c main.py 2>/dev/null | head -1); [ "$(cat .mode 2>/dev/null)" = proj ] && SRCF=$(cat .fb_target 2>/dev/null)
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
      echo "⚠️ AI 的回覆裡沒有程式碼區塊。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
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
      echo "⚠️ AI 給的是 C++，但這個環境沒有 g++。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
      echo "（上一次你給的是 C++，但考場環境只有 gcc（C 語言），沒有 g++。請改寫成 C：不能用 iostream、vector、string 類別、std::。）"; print_write; rm -rf "$T"; exit 0
    fi
    if [ "$MODE" = proj ]; then   # 多檔案專案：寫回 AI 指定的那個檔案，用 make 編譯
      TG=$(grep -m1 -oE 'FILE:[[:space:]]*[A-Za-z0-9_./-]+' "$T/b$PICK.body" | sed 's/FILE:[[:space:]]*//')
      [ -z "$TG" ] && TG=$(cat "$T/b$PICK.info" "$T/b$PICK.prev" | grep -oE '[A-Za-z0-9_./-]+\.(c|h|py)' | head -1)
      [ -z "$TG" ] && TG=$(best_file_for "$T/b$PICK.body")
      [ -z "$TG" ] && TG=$(cat .fb_target 2>/dev/null)
      if [ -n "$TG" ] && [ ! -f "$TG" ]; then F2=$(find . -maxdepth 2 -name "$(basename "$TG")" ! -path './.fb*' | pick_by_problem); [ -n "$F2" ] && TG=${F2#./}; fi
      if [ -z "$TG" ] || [ ! -f "$TG" ]; then
        echo "⚠️ 看不出 AI 要改哪個檔案。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
        echo "（上一次你沒有標出要改的檔案，或檔名不存在。程式碼區塊第一行一定要寫 // FILE: 檔名，檔名必須是專案裡已有的檔案：$(find . -maxdepth 2 -name '*.[ch]' ! -path './.fb*' | sed 's#^\./##' | tr '\n' ' ')）"; print_write; rm -rf "$T"; exit 0
      fi
      PROT=$(python3 - <<'FB_PYPROT'
import re
t = open("problem.txt", encoding="utf-8", errors="replace").read().split("【專案裡的檔案】")[0]
out = set()
for s in re.split(r"[。\n]", t):   # 題目說「不要修改／不要改／不要動」的檔案
    m = re.search(r"(不要|不可以?|不能|請勿|禁止|勿)\S{0,2}(修改|改|動)", s)
    if not m: continue
    if re.search(r"完成|修正|只修改|只改|請改|請修改", s): s = s[m.start():]
    out.update(re.findall(r"[A-Za-z0-9_./-]+\.(?:c|h|py)\b", s))
print(" ".join(sorted(out)))
FB_PYPROT
)
      isprot() { local p; for p in $PROT; do [ "$1" = "$p" ] || [ "$(basename "$1")" = "$p" ] && return 0; done; return 1; }
      if isprot "$TG"; then   # 選到的區塊是不能改的檔案：改用其他有 FILE: 而且可以改的區塊
        for i in $(seq 1 "$NB"); do
          F3=$(grep -m1 -oE 'FILE:[[:space:]]*[A-Za-z0-9_./-]+' "$T/b$i.body" | sed 's/FILE:[[:space:]]*//'); [ -n "$F3" ] || continue
          [ -f "$F3" ] || { F3=$(find . -maxdepth 2 -name "$(basename "$F3")" ! -path './.fb*' | pick_by_problem); F3=${F3#./}; }
          [ -n "$F3" ] && [ -f "$F3" ] && ! isprot "$F3" && { PICK=$i; TG=$F3; }
        done
      fi
      if isprot "$TG"; then
        echo "⚠️ AI 改的是題目說不能改的 $TG，沒有寫入。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
        echo "（上一次你改了 $TG，但題目說不能改：$PROT。請改題目要求的檔案$( [ -s .fb_target ] && echo "（$(cat .fb_target)）")，區塊第一行寫 // FILE: 那個檔名。）"; print_write; rm -rf "$T"; exit 0
      fi
      for i in $(seq 1 "$NB"); do   # AI 一次改了好幾個檔案（每個區塊都有 FILE:）：其他檔案也寫入（題目說不能改的除外）
        [ "$i" = "$PICK" ] && continue
        F3=$(grep -m1 -oE 'FILE:[[:space:]]*[A-Za-z0-9_./-]+' "$T/b$i.body" | sed 's/FILE:[[:space:]]*//'); [ -n "$F3" ] || continue
        [ -f "$F3" ] || { F3=$(find . -maxdepth 2 -name "$(basename "$F3")" ! -path './.fb*' | pick_by_problem); F3=${F3#./}; }
        [ -n "$F3" ] && [ -f "$F3" ] && [ "$F3" != "$TG" ] || continue
        if isprot "$F3"; then echo "（AI 也改了 $F3，但題目說不能改，沒有寫入）" >&2; continue; fi
        [ -e ".fb_bak/$F3" ] || { mkdir -p ".fb_bak/$(dirname "$F3")"; cp "$F3" ".fb_bak/$F3"; }
        cp "$T/b$i.body" "$F3"; echo "（也寫入 $F3）" >&2
      done
      [ -e ".fb_bak/$TG" ] || { mkdir -p ".fb_bak/$(dirname "$TG")"; cp "$TG" ".fb_bak/$TG"; }
      cp "$T/b$PICK.body" "$TG"; echo "$TG" > .fb_target; echo "（已寫入 $TG，原檔備份在 .fb_bak/）" >&2
      OUT=$(PROJ=1 bash "$SELF" check "$TG")
    else
      DUP=0; [ "$STAGE" = fix ] && [ -f "main.$EXT" ] && cmp -s "$T/b$PICK.body" "main.$EXT" && DUP=1   # 貼到和目前一模一樣的程式（複製到舊回答，或 AI 沒改）
      rm -f main.c main.cpp main.py; cp "$T/b$PICK.body" "main.$EXT"
      if [ "$MODE" = ros ]; then
        RT=$(cat .fb_target 2>/dev/null)
        if [ -n "$RT" ] && [ -f "$RT" ] && [ "$EXT" = py ]; then
          [ -e ".fb_bak/$RT" ] || { mkdir -p ".fb_bak/$(dirname "$RT")"; cp "$RT" ".fb_bak/$RT"; }
          cp main.py "$RT"; echo "（也寫入 $RT，原檔備份在 .fb_bak/；交卷交 $RT）" >&2
        fi
        for i in $(seq 1 "$NB"); do [ "$(cat "$T/b$i.tag")" = verify ] && { cp "$T/b$i.body" verify.sh; echo "（AI 更新了驗收腳本）" >&2; }; done
        fix_verify
        OUT=$(bash "$SELF" checkros)
      else
        OUT=$(bash "$SELF" check "main.$EXT")
      fi
    fi
    SF="main.$EXT"; [ "$MODE" = proj ] && SF="$TG"
    if [ "${DUP:-0}" = 1 ]; then
      echo "⚠️ 這次貼的程式和上一次一模一樣：可能複製到舊的回答（AI 網頁要等新回答出來再按複製），或 AI 沒有改。照樣把下面整段貼給 AI。" >&2
      NOTE="（你上一次給的程式和【目前程式】一模一樣，完全沒有修改。這次一定要針對回報的錯誤實際修改程式。）"
    fi
    if printf '%s' "$OUT" | grep -q '【只能用 CI 驗證】'; then   # 本機編不了／跑不了（Pico 韌體、缺 SDK）：寫入檔案後直接交卷，用 GitLab 評分當測試
      echo fix > .stage; rm -f .fb_att_best .fb_att_fix .fb_sig .fb_n
      printf '%s\n' "$OUT" | grep -E '^⚠️|^✅' >&2
      echo "👉 程式已寫入 $SF。這題沒辦法在這台電腦測試：現在直接打 fb submit 交出去，用 GitLab 的評分當測試。" >&2
      echo "   綠勾＝完成（打 fb skip 收工）；紅叉＝照步驟 5-2 複製 job 的 log，打 fb ci 貼上，再把它印出的內容貼給 AI。" >&2
      rm -rf "$T"; exit 0
    fi
    if [ "$MODE" != ros ] && ! printf '%s' "$OUT" | grep -q '全部通過'; then   # 只前進不後退：新版本通過的測資比之前少，就換回之前最好的版本再請 AI 改
      # 分數＝通過的測資組數 ×10000 ＋ 第一筆失敗測資裡「第一個不同」在第幾行（越後面代表對得越多）；編譯失敗沒有分數（不比較）
      SC=$(printf '%s' "$OUT" | grep -oE '測資：[0-9]+ / [0-9]+' | head -1 | grep -oE '[0-9]+' | head -1)
      # （行級分數在 12 題新題的實測沒有比較好：1/12 對 4/12，所以只用「通過幾組」當分數，行數固定 0）
      if [ -n "$SC" ]; then DL=0; SC=$(( SC * 10000 + DL )); fi
      BS=$(cat .fb_best_score 2>/dev/null); BF=".fb_best/$(basename "$SF")"
      # 重新作答：小模型「修補」能力差，解得出來的題目多半前 2～3 輪就過。同一次作答連續 2 輪修正都沒有讓通過的測資變多 → 不再補，回到「從頭寫」重抽一次（最多重來 3 次；RESTART=0 可關）
      SCN=${SC:--1}; AB=$(cat .fb_att_best 2>/dev/null || echo -2); AF=$(cat .fb_att_fix 2>/dev/null || echo 0); RS=$(cat .fb_restarts 2>/dev/null || echo 0)
      if [ "$STAGE" = write ] || [ "$AB" = -2 ]; then AB=$SCN; AF=0
      elif [ "$SCN" -gt "$AB" ]; then AB=$SCN; AF=0
      else AF=$((AF+1)); fi
      echo "$AB" > .fb_att_best; echo "$AF" > .fb_att_fix
      TH=2; [ "$AB" -ge 10000 ] && TH=4   # 已經有測資通過（接近正確）就多給幾輪修正，不要太早丟掉
      if [ "$AF" -ge "$TH" ] && [ "$RS" -lt 3 ] && [ "${RESTART:-1}" = 1 ]; then
        KB=""; KS=-1   # 這次作答最好的版本留一份（交卷備用）
        if [ -n "$BS" ] && [ -f "$BF" ]; then KB="$BF"; KS=$BS; fi
        if [ -n "$SC" ] && [ "$SC" -gt "$KS" ]; then KB="$SF"; KS=$SC; fi
        if [ -n "$KB" ] && [ "$KS" -gt "$(cat .fb_bestall_score 2>/dev/null || echo -1)" ]; then mkdir -p .fb_bestall; cp "$KB" ".fb_bestall/$(basename "$SF")"; echo "$KS" > .fb_bestall_score; fi
        rm -rf .fb_best .fb_best_score .fb_att_best .fb_att_fix .fb_sig .fb_n; echo $((RS+1)) > .fb_restarts; echo write > .stage
        ERRS=$(printf '%s\n' "$OUT" | grep -E '^  (預期|你的)：|^👉|error:' | head -3 | cut -c1-300)
        echo "🔄 修了 $AF 輪都沒有進步：不再修補，請 AI 整題重新寫一次（第 $((RS+2)) 次作答）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
        echo "（重新作答：前一次的寫法修了幾輪都改不對。這次不要沿用之前的程式，換一個更簡單直接的寫法從頭寫。前一次最後錯在：）"; printf '%s\n' "$ERRS"
        print_write; rm -rf "$T"; exit 0
      fi
      if [ -n "$SC" ] && [ -n "$BS" ] && [ -f "$BF" ] && [ "$SC" -lt "$BS" ]; then
        cp "$BF" "$SF"
        if [ $(( SC / 10000 )) -lt $(( BS / 10000 )) ]; then WHY="通過的測資從 $(( BS / 10000 )) 組掉到 $(( SC / 10000 )) 組"
        elif [ $(( SC % 10000 )) -eq 0 ]; then WHY="原本前 $(( BS % 10000 - 1 )) 行輸出是對的，現在程式沒有正常跑完（當掉、逾時或沒有輸出）"
        else WHY="原本前 $(( BS % 10000 - 1 )) 行輸出是對的，現在第 $(( SC % 10000 )) 行就錯了"; fi
        echo "↩️ 這一版比之前更差（$WHY）：已自動換回之前比較好的版本。" >&2
        NOTE="（你上一次的修改把程式改壞了：$WHY。已經還原成修改前的版本，就是下面的【目前程式】。這次換一個改法，只針對下面回報的那一個錯誤改，其他地方不要動。）"
        if [ "$MODE" = proj ]; then OUT=$(PROJ=1 bash "$SELF" check "$SF"); else OUT=$(bash "$SELF" check "$SF"); fi
      elif [ -n "$SC" ] && { [ -z "$BS" ] || [ "$SC" -ge "$BS" ]; }; then
        mkdir -p .fb_best; cp "$SF" "$BF"; echo "$SC" > .fb_best_score
      fi
    fi
    NOIN=1; for f in tests/*.in; do [ -s "$f" ] && NOIN=0; done   # 所有測資輸入都是空的（程式不讀輸入）：對拍沒意義，不做
    printf '%s' "$OUT" | grep -q '全部通過' && { mkdir -p .fb_pass; cp "$SF" ".fb_pass/$(basename "$SF")"; }   # 保留最後一個「目前測資全過」的版本（之後越改越壞時可以拿回來交）
    if ! printf '%s' "$OUT" | grep -q '全部通過' && [ -f ".fb_pass/$(basename "$SF")" ] && printf '%s' "$OUT" | grep -qE '第一筆失敗：[0-9]+\.in'; then
      echo "⚠️ 這一版連題目範例都錯了（之前通過範例的版本在 .fb_pass/$(basename "$SF")；時間不夠時可以 cp .fb_pass/$(basename "$SF") $SF 拿回來交）" >&2
    fi
    if printf '%s' "$OUT" | grep -q '全部通過' && [ "$MODE" != ros ] && [ "$NOIN" = 0 ] && [ "${STRESS:-1}" = 1 ] && [ ! -f .fb_stress_ok ]; then   # 專案模式（起始檔＋Makefile）也對拍＋最大規模計時（效能題、隱藏 bug、多執行緒題）
      if [ -s brute.py ] && [ -s gen.py ]; then   # 之前已經有暴力解＋產生器：直接再對拍，不用再問 AI
        stress_run; stress_after $? "$SF"
      else
        echo brute > .stage
        echo "✅ 範例都過了！考試時：現在就先打 fb submit 交一版，看 GitLab 的評分（綠勾＝這題完成，打 fb skip 收工）。" >&2; echo "   想更保險、或評分是紅叉，再做「對拍」找隱藏的錯：把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
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
      echo "❌ 還沒過。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "（AI 回答後：先打 fb 按 Enter，看到「👉 請貼上」才貼上）" >&2; echo "--------" >&2
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
      echo "【修正任務】你是上機考解題助手。下面是題目、目前的程式和執行回報。照這個順序回答：(1) 針對回報裡第一筆失敗的那一行輸入，照題目規則列出正確的處理步驟（3～6 行；不用算出數值，只寫結構：這筆輸入共有幾個單位、哪一段是哪個欄位、陣列索引從哪到哪、迴圈跑幾次、什麼條件算錯誤）。(2) 指出目前程式哪一行和上面的步驟不一樣（常見：長度或索引差 1、緩衝區太小、迴圈多跑或少跑、條件寫反、輸出時重新讀取已經用掉的資料、位元順序弄反、型別溢位）。(3) 給修正後的完整程式（只給一個程式碼區塊，程式裡不要寫註解）。輸出格式逐字照題目範例。"
      KEY=$(grep -m1 '^👉' "$REP"); [ -n "$KEY" ] && { echo "【這次只要修這一個錯（最重要，先看這段）】"; printf '%s\n' "$KEY"; echo; }   # 診斷放最前面：小模型常只看開頭，跑去改無關的地方
      echo "【題目】"; prob_wo "$SRC"; echo
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
  # 缺的標頭檔是「題目起始程式本來就有 include 的 SDK 標頭」（或 Pico SDK 的路徑）而且專案裡找不到 → 不是 AI 寫錯，是這台電腦沒有那個 SDK
  HDR=$(grep -m1 -oE 'fatal error: [^ ]+: No such file or directory' "$REP.err" | sed -E 's/fatal error: (.*): No such file or directory/\1/')
  if [ -n "$HDR" ] && [ -z "$(find . -name "$(basename "$HDR")" ! -path './.fb*' ! -path './build/*' 2>/dev/null | head -1)" ] \
     && { grep -qF -- "$HDR" problem.txt 2>/dev/null || grep -rqF -- "$HDR" .fb_bak 2>/dev/null || [[ "$HDR" =~ ^(pico|hardware|boards)/ ]] || [[ "$HDR" =~ \.pio\.h$ ]]; }; then
    say "【只能用 CI 驗證】"; say "⚠️ 這台電腦沒有 $HDR（考場的 SDK／開發板才有），沒辦法在本機編譯。"; cat "$REP"; rm -f "$REP" "$REP.err" "$BIN"; exit 0
  fi
  say "結果：編譯失敗"
  say "--- 第一個錯誤（編譯器原文）---"
  if grep -qE 'error|undefined reference|multiple definition' "$REP.err"; then grep -m1 -A4 -E 'error:|undefined reference|multiple definition' "$REP.err" | cut_lines 8 >> "$REP"
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
ci_only() {   # 這個專案沒辦法在本機編譯／執行（要考場的 SDK 或開發板）：不當成程式錯誤，改用 GitLab 評分當測試
  say "【只能用 CI 驗證】"; say "$1"; cat "$REP"; rm -f "$REP" "$REP.err" "$BIN"; exit 0
}
if [ -n "$PROJ" ] && [[ "$SRC" != *.py ]] && [ ! -f Makefile ] && [ ! -f makefile ] && [ -f CMakeLists.txt ]; then   # CMake 專案（例如 Pico 韌體）
  command -v cmake >/dev/null 2>&1 || ci_only "⚠️ 這是 CMake 專案，但這台電腦沒有 cmake，沒辦法在本機編譯。"
  if ! cmake -S . -B build > "$REP.err" 2>&1; then
    grep -qiE 'PICO_SDK|pico_sdk|toolchain|arm-none-eabi|riscv|CMAKE_C_COMPILER|Could not find|not found' "$REP.err" && ci_only "⚠️ 這個 CMake 專案在本機設定失敗（缺少考場的 SDK／交叉編譯器），沒辦法在本機編譯。"
    compile_fail
  fi
  cmake --build build > "$REP.err" 2>&1 || compile_fail
  ci_only "✅ 本機編譯（cmake）成功。這是要在開發板上跑的韌體，本機不能執行。"
fi
if [ -n "$PROJ" ] && [[ "$SRC" != *.py ]] && [ ! -f Makefile ] && [ ! -f makefile ]; then   # 有起始檔但沒有 Makefile：gcc 編 SRC 和同資料夾的 .c（SRC 有 main 時，別的有 main 的 .c 不編）
  LTAG=c; CS="$SRC"; HM=0; grep -qE '(int|void)[[:space:]]+main[[:space:]]*\(' "$SRC" && HM=1
  for f in "$(dirname "$SRC")"/*.c; do [ "$f" -ef "$SRC" ] && continue; [ $HM = 1 ] && grep -qE '(int|void)[[:space:]]+main[[:space:]]*\(' "$f" && continue; CS="$CS $f"; done
  gcc -O2 -Wall -Wextra -Wno-unused-result -pthread -o .fb_app $CS -lm 2> "$REP.err" || compile_fail
  RUN=./.fb_app; echo ./.fb_app > .fb_prog
  W=$(grep -c 'warning' "$REP.err")
  [ "$W" -gt 0 ] && { say "編譯（gcc $CS）：成功，但有 $W 個 warning（第一個如下）"; grep -m1 'warning' "$REP.err" | cut_lines 1 >> "$REP"; } || say "編譯（gcc $CS）：成功"
elif [ -n "$PROJ" ] && [[ "$SRC" != *.py ]]; then   # 多檔案專案：用 make 編，執行檔＝這次 make 新產生的可執行檔（或 PROG=路徑 指定）
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
        gcc -O2 -Wall -Wextra -Wno-unused-result -pthread -o "$BIN" "$SRC" -lm 2> "$REP.err" || compile_fail
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
NT=0; for f in "$TDIR"/*.out; do grep -qE '[0-9][[:space:]]*((ms|us|ns|sec|secs|seconds|CPUs?|cpus?|cores?|times)\b|毫秒|秒)' "$f" 2>/dev/null && NT=1; done
ntime() { if [ $NT = 1 ]; then sed -E 's/[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*((ms|us|ns|sec|secs|seconds|CPUs?|cpus?|cores?|times)\b|毫秒|秒)/ #\2/g'; else cat; fi; }   # 預期輸出有「61.2 ms」「12 CPUs」這種每台電腦都不同的數字：比對時不看這些數字
[ $NT = 1 ] && say "（預期輸出含執行時間／CPU 數等每次不同的數字：比對時這些數字不算）"
if [ ${#INS[@]} -eq 0 ]; then
  say "（沒有測資，直接執行一次，最多 ${TO} 秒）"
  S=$(date +%s%N); OUTP=$(timeout "$TO" $RUN < /dev/null 2>&1); RC=$?; E=$(( ($(date +%s%N)-S)/1000000 ))
  say "結束碼：$RC（124=逾時，134=assert/abort，139=記憶體錯誤）；時間 ${E} ms"
  say "--- 輸出（前 15 行）---"; printf '%s\n' "$OUTP" | cut_lines 15 >> "$REP"
else
  PASS=0; MAXE=0; FAILED=""; TOTAL=${#INS[@]}
  RN=1; grep -qE 'pthread_create|thrd_create|fork[[:space:]]*\(' "$SRC" 2>/dev/null && RN=3   # 多執行緒：每筆測資跑 3 次，有一次錯就算錯（race 不一定每次都出現）
  [ $RN -gt 1 ] && say "（多執行緒程式：每筆測資跑 $RN 次，每次都要對）"
  for IN in "${INS[@]}"; do
    EXP="${IN%.in}.out"
    for r in $(seq 1 $RN); do
      S=$(date +%s%N); GOT=$(runone "$IN" 2>"$REP.se"); RC=$?; E=$(( ($(date +%s%N)-S)/1000000 )); [ $E -gt $MAXE ] && MAXE=$E
      [ $RC -eq 0 ] && [ -f "$EXP" ] && diff -q <(printf '%s\n' "$GOT" | tidy | ntime) <(tidy < "$EXP" | ntime) >/dev/null || break
    done
    if [ $RC -eq 0 ] && [ -f "$EXP" ] && diff -q <(printf '%s\n' "$GOT" | tidy | ntime) <(tidy < "$EXP" | ntime) >/dev/null; then
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
    printf '%s\n' "$FGOT" | ntime > "$REP.got"; ntime < "${FAILED%.in}.out" > "$REP.exp"
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
            else if (i <= ne && i <= ng && a ~ /^[A-Za-z_ ]+$/ && b ~ /[0-9]/ && index(b, a) == 0)
              printf "👉 這一行預期是題目規定的特殊輸出「%s」，你卻印了一般資料「%s」：程式沒有偵測到這一筆的錯誤條件，或偵測到之前就已經把前面的值印出去了。改法：這一行要印的值先全部存進變數或陣列，整筆讀完、確認沒有任何錯誤才印；任何一步出錯就只印「%s」。具體寫法（C）：每一筆開頭宣告 char line[1024]; int n = 0, bad = 0; 原本每個 printf(...) 都改成 n += snprintf(line + n, sizeof line - n, ...)（先不印）；任何讀取或檢查失敗就 bad = 1；這一筆處理完才 if (bad) puts(\"%s\"); else puts(line);。Python 則用 list 收集，最後才 print。\n", a, b, a, a
            else if (i <= ne && i <= ng && b ~ /^[A-Za-z_ ]+$/ && a ~ /[0-9]/ && index(a, b) == 0)
              printf "👉 這一行是正常資料（預期「%s」），你卻印了「%s」：錯誤條件寫得太嚴，把正常的輸入也判成錯誤。找出印「%s」的每一個 if，逐條對照題目「什麼情況才算錯」，把題目沒有規定的條件拿掉（例如資料後面還有剩下的補零位元、長度不是剛好用完，都不算錯）。\n", a, b, b
            else if (i <= ne && i <= ng && length(a) > 0 && length(b) > length(a) && substr(b, length(b) - length(a) + 1) == a)
              printf "👉 你的這一行「開頭多印了」「%s」，後面才是正確的「%s」。通常是：還沒確認這一筆資料全部有效，就先印出了一部分（例如先印欄位、讀到一半才發現錯誤再印 %s）。改法：先把這一行要印的所有值算好存進變數或陣列，整筆都檢查完沒有錯誤才一次印出；有錯誤就只印「%s」，前面什麼都不要印。具體寫法（C）：每一筆開頭宣告 char line[1024]; int n = 0, bad = 0; 原本每個 printf(...) 都改成 n += snprintf(line + n, sizeof line - n, ...)（先不印）；任何讀取或檢查失敗就 bad = 1；這一筆處理完才 if (bad) puts(\"%s\"); else puts(line);。Python 則用 list 收集，最後才 print。\n", substr(b, 1, length(b) - length(a)), a, a, a, a
            else if (i <= ne && i <= ng && length(a) > 0 && length(b) > length(a) && substr(b, 1, length(a)) == a)
              printf "👉 你的這一行前面都對，但「結尾多印了」「%s」。把多印的部分拿掉（檢查是不是多跑了一次迴圈、或錯誤時又多印了東西）。\n", substr(b, length(a) + 1)
            else if (i <= ne && i <= ng && length(b) > 0 && length(a) > length(b) && substr(a, 1, length(b)) == b)
              printf "👉 你的這一行前面都對，但「少印了結尾」「%s」。檢查迴圈次數、或是不是提早 break。\n", substr(a, length(b) + 1)
            exit
          }
        }
      }' "$REP.exp" >> "$REP"
    say "（␣ 代表一個空白。請逐字對照題目的輸出格式，格式以題目為準，不是情境包。）"
    rm -f "$REP.got" "$REP.exp"
    say "請找出原因並修正，給完整程式。不要心算，必要時加 printf 除錯。"
  else
    say "全部通過。（最慢一筆 ${MAXE} ms）"
  fi
fi
emit
rm -f "$REP" "$REP.err" "$BIN"
