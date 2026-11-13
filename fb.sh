#!/usr/bin/env bash
# fb.sh v5（考場版：一般題＋ROS 2 題）— 你當手腳、考場 AI 當大腦：每一輪都只做同一個動作。
#   ① 終端機打 ./fb.sh ，貼上「題目」或「AI 的整段回覆」，Enter 後按 Ctrl-D
#   ② 把終端機印出來的內容整段複製，到考場 AI「開新對話」貼上
#   ③ 把 AI 的整段回覆複製，回到 ①；直到出現「🎉 全部通過」
# 其他指令：./fb.sh selfcheck（檢查環境）
#          ./fb.sh reset（換下一題，清空這個資料夾的狀態）
#          ./fb.sh test（不貼東西，直接重跑目前的程式）
#          ./fb.sh pack S06（手動換情境包）
#          TO=1 ./fb.sh（效能題：每筆測資限時 1 秒）
# 需要同資料夾或 fb.sh 旁邊有 packs.txt（30 個情境包）。每一題建議用一個新資料夾。
SELF="$(readlink -f "$0")"; HERE="$(dirname "$SELF")"
PACKS="${PACKS:-$HERE/packs.txt}"; [ -f "$PACKS" ] || PACKS="./packs.txt"

if [ "$1" = "checkros" ]; then
  LIMIT=1800; VER="${VERIFY:-verify.sh}"; EXPF="${EXPECT:-expected.txt}"
  REP=$(mktemp); say() { printf '%s\n' "$*" >> "$REP"; }
  source /opt/ros/jazzy/setup.bash >/dev/null 2>&1 || { echo "❌ 找不到 ROS 2（/opt/ros/jazzy/setup.bash）"; exit 1; }
  export ROS_DOMAIN_ID=$(( RANDOM % 80 + 20 ))
  LIB=$(mktemp)
  cat > "$LIB" <<'FB_ROSLIB'
_f() { echo "/tmp/fbros_$(echo "$1" | tr '/' '_')"; }
grab() { timeout 12 ros2 topic echo "$1" > "$(_f "$1")" 2>&1 & GRAB_PIDS="$GRAB_PIDS $!"; sleep 2; }
send() { timeout 10 ros2 topic pub --once -w 1 "$1" "$2" "$3" > /dev/null 2>&1 || echo "（send $1 失敗：沒有節點訂閱 $1，或型別／YAML 寫錯）"; sleep 0.7; }
show() { sleep 1; for p in $GRAB_PIDS; do kill -INT "$p" 2>/dev/null; done; wait $GRAB_PIDS 2>/dev/null; GRAB_PIDS=""; echo "== $1 收到："; grep -vE '^---$|WARNING|does not appear' "$(_f "$1")" | head -40; }
call() { echo "== call $1："; timeout 12 ros2 service call "$1" "$2" "$3" 2>&1 | tail -3; }
FB_ROSLIB
  rm -f /tmp/fbros_*
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
    elif [ $ALIVE -eq 1 ]; then say "（沒有驗收腳本，只檢查節點有沒有正常啟動）"; : > verify.out; fi
    kill -INT "$NP" 2>/dev/null; sleep 2; kill -9 "$NP" 2>/dev/null
    ROSPASS=1
    [ $ALIVE -eq 0 ] && { say "❌ 節點啟動後就結束了（可能程式出錯或沒有 spin）"; ROSPASS=0; }
    if grep -q "Traceback" node.log; then
      say "❌ 節點有錯誤（Traceback；若是在 Ctrl-C 之後才出現，代表沒有處理 ExternalShutdownException）"; ROSPASS=0
    fi
    if [ -s "$EXPF" ] && [ $ALIVE -eq 1 ]; then
      MISS=""; while IFS= read -r L; do
        L2=$(printf '%s' "$L" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'); [ -z "$L2" ] && continue
        grep -qF -- "$L2" verify.out || MISS="$MISS$L2"$'\n'
      done < "$EXPF"
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
  rm -f "$REP" "$REP.err" "$LIB" /tmp/fbros_*; exit 0
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
cat <<'FB_PCODE'
你是上機考解題助手。根據下面的【題目】寫出完整、單一檔案、可直接編譯的 C 程式（gcc -O2 -Wall -pthread，#include 要齊全），從 stdin 讀、寫到 stdout。
規則：1. 輸出格式（空白、逗號、大小寫、換行）逐字照題目範例，不要多印任何文字。2. 【參考零件】只是參考，和題目不同時以題目為準。3. 數字、位元欄位、指令編碼不要心算，寫進程式。4. 有時間限制先估複雜度：N 到 10^5 以上要 O(N log N) 以下。題目附原始程式的，保留原本的輸入輸出與要求（例如必須用多執行緒）。5. 只輸出一個 ```c 程式碼區塊，程式裡不要寫註解（省長度），前面最多 2 行說明。
FB_PCODE
echo "【題目】"; cat problem.txt
[ -f pack.txt ] && { echo "【參考零件】"; cat pack.txt; }
}
get_pack() {   # 從 packs.txt 取出某個情境包
  [ -f "$PACKS" ] || { echo "⚠️ 找不到 packs.txt，這次不附情境包" >&2; return 1; }
  awk -v id="$1" '/^@@@ /{p=($2==id); next} p' "$PACKS" > pack.tmp
  if [ -s pack.tmp ]; then mv pack.tmp pack.txt; return 0; else rm -f pack.tmp; return 1; fi
}
split_blocks() {   # 把貼上的回覆拆成程式碼區塊：$1/b<n>.lang .tag .body
  awk -v D="$1" '
    BEGIN { n=0; inb=0; tag="" }
    { line=$0; sub(/\r$/, "", line) }
    !inb && line ~ /^[ \t]*```/ { inb=1; n++; lang=line; sub(/^[ \t]*```[ \t]*/, "", lang)
        print lang > (D "/b" n ".lang"); close(D "/b" n ".lang")
        print tag  > (D "/b" n ".tag");  close(D "/b" n ".tag")
        printf "" > (D "/b" n ".body"); tag=""; next }
    inb && line ~ /^[ \t]*```[ \t]*$/ { inb=0; close(D "/b" n ".body"); next }
    inb { print line >> (D "/b" n ".body"); next }
    line ~ /範例輸入/ { tag="in" }
    line ~ /範例輸出|預期輸出/ { tag="out" }
    line ~ /驗收/ { tag="verify" }
    END { print n > (D "/count") }' "$1/in.txt"
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
  reset) rm -rf .stage .sid .mode problem.txt pack.txt main.c main.py .fb_sig .fb_n tests verify.sh expected.txt node.log verify.out
         echo "已清空。開始新的一題：./fb.sh 然後貼上題目"; exit 0 ;;
  test)  [ "$(cat .mode 2>/dev/null)" = ros ] && exec bash "$SELF" checkros
         for f in main.c main.py; do [ -f "$f" ] && exec bash "$SELF" check "$f"; done
         echo "還沒有程式"; exit 1 ;;
  pack)  get_pack "$2" && echo "已換成情境 $2（下一次 ./fb.sh 會附上）" || echo "packs.txt 裡沒有 $2"; exit 0 ;;
esac

STAGE=$(cat .stage 2>/dev/null || echo start)
case "$STAGE" in
  start)  HINT="題目（整段）" ;;
  select) HINT="AI 的回覆（情境編號＋範例）" ;;
  done)   echo "🎉 這一題已經全部通過。要做下一題：./fb.sh reset"; exit 0 ;;
  *)      HINT="AI 的整段回覆（含程式碼）" ;;
esac
echo "👉 請貼上【$HINT】，貼完按 Enter，再按 Ctrl-D" >&2
IN=$(cat)
[ -n "$IN" ] || { echo "沒有貼到任何東西" >&2; exit 1; }
T=$(mktemp -d); printf '%s\n' "$IN" > "$T/in.txt"; split_blocks "$T"; NB=$(cat "$T/count")

case "$STAGE" in
  start)
    printf '%s\n' "$IN" > problem.txt; echo select > .stage
    if grep -qiE 'ros ?2|rclpy|ros2 |topic|publisher|subscriber|節點' problem.txt; then echo ros > .mode; else echo std > .mode; fi
    echo "✅ 已存題目（題型：$( [ "$(cat .mode)" = ros ] && echo 'ROS 2' || echo '一般輸入輸出' )）。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
    if [ "$(cat .mode)" = ros ]; then print_select_ros; else print_select; fi ;;
  select)
    if [ "$(cat .mode 2>/dev/null)" = ros ]; then
      rm -f verify.sh expected.txt
      for i in $(seq 1 "$NB"); do
        tg=$(cat "$T/b$i.tag"); lg=$(tr 'A-Z' 'a-z' < "$T/b$i.lang" | tr -d ' \r')
        if [ "$tg" = verify ] || { [ ! -f verify.sh ] && [[ "$lg" =~ ^(bash|sh|shell)$ ]]; }; then cp "$T/b$i.body" verify.sh
        elif [ "$tg" = out ]; then cp "$T/b$i.body" expected.txt; fi
      done
      SID=$(grep -o 'S[0-9][0-9]' "$T/in.txt" | head -1); [ -n "$SID" ] && echo "$SID" > .sid
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
    P=$(norm < problem.txt)
    for j in $(seq 1 $k); do
      x=$(norm < "tests/$j.in"); y=$(norm < "tests/$j.out")
      { [ -n "$x" ] && [[ "$P" != *"$x"* ]]; } && echo "⚠️ 第 $j 組範例輸入在題目裡找不到，可能被 AI 抄錯，請自己對一下 tests/$j.in" >&2
      { [ -n "$y" ] && [[ "$P" != *"$y"* ]]; } && echo "⚠️ 第 $j 組範例輸出在題目裡找不到，可能被 AI 抄錯，請自己對一下 tests/$j.out" >&2
    done
    for j in $(seq $((k+1)) 20); do rm -f "tests/$j.in" "tests/$j.out"; done
    SID=$(grep -o 'S[0-9][0-9]' "$T/in.txt" | head -1)
    [ -n "$SID" ] && echo "$SID" > .sid
    rm -f pack.txt; [ -n "$SID" ] && get_pack "$SID"
    echo write > .stage
    echo "✅ 建了 $k 組測資；情境：${SID:-無}。把下面整段複製，到 AI 開新對話貼上：" >&2
    [ "$k" -eq 0 ] && echo "⚠️ AI 沒照格式抄範例，所以沒有測資；之後只能直接執行看輸出。" >&2
    echo "--------" >&2
    print_write ;;
  write|fix)
    PICK=""; EXT=""
    for i in $(seq 1 "$NB"); do
      lg=$(tr 'A-Z' 'a-z' < "$T/b$i.lang" | tr -d ' \r')
      if   [[ "$lg" =~ ^(c|h|cpp|c\+\+)$ ]] || { [ -z "$lg" ] && grep -q '#include' "$T/b$i.body"; }; then PICK=$i; EXT=c
      elif [[ "$lg" =~ ^(python|py|python3)$ ]] || { [ -z "$lg" ] && grep -qE '^(import|from|def) ' "$T/b$i.body"; }; then PICK=$i; EXT=py; fi
    done
    if [ -z "$PICK" ]; then
      echo "⚠️ AI 的回覆裡沒有程式碼區塊。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
      if [ "$(cat .mode 2>/dev/null)" = ros ]; then echo "（上一次你沒有給程式碼。請只給一個完整的 ${FENCE}python 程式碼區塊。）"; print_write_ros
      else echo "（上一次你沒有給程式碼。請只給一個完整、可編譯的 ${FENCE}c 程式碼區塊。）"; print_write; fi; exit 0
    fi
    rm -f main.c main.py; cp "$T/b$PICK.body" "main.$EXT"
    if [ "$(cat .mode 2>/dev/null)" = ros ]; then
      for i in $(seq 1 "$NB"); do [ "$(cat "$T/b$i.tag")" = verify ] && { cp "$T/b$i.body" verify.sh; echo "（AI 更新了驗收腳本）" >&2; }; done
      OUT=$(bash "$SELF" checkros)
    else
      OUT=$(bash "$SELF" check "main.$EXT")
    fi
    if printf '%s' "$OUT" | grep -q '全部通過'; then
      echo done > .stage; printf '%s\n' "$OUT"
      echo "🎉 全部通過！可以交卷（git add -A && git commit -m ... && git push，或交 OJ）。下一題：./fb.sh reset" >&2
    else
      echo fix > .stage
      echo "❌ 還沒過。把下面整段複製，到 AI 開新對話貼上：" >&2; echo "--------" >&2
      printf '%s\n' "$OUT"
    fi ;;
esac
rm -rf "$T"; exit 0
fi
shift
SRC="$1"; TDIR="${2:-tests}"; LIMIT=1500; TO="${TO:-5}"
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
      [ -f pack.txt ] && { echo "【參考零件】（只是參考，和題目不同時以題目為準）"; cat pack.txt; echo; }
      echo "【目前程式】"; echo '```'"$LTAG"; cat "$SRC"; echo '```'
    fi
  fi
  head -c $LIMIT "$REP"; echo
  [ "$(wc -c < "$REP")" -gt $LIMIT ] && echo "（回報已截斷到 $LIMIT 字元）"
  [ "$N" -eq 1 ] && echo "⚠️ 這個錯誤已經連續 2 次一模一樣，代表上次的修改沒有改到真正原因。這次在算出錯值的地方加 fprintf(stderr, ...) 印出中間值，答案照常印到 stdout；我會把 stderr 一起貼給你。"
  return 0
}

say "【執行回報】檔案：$SRC"
case "$SRC" in
  *.c)  LTAG=c; RUN="$BIN"
        if ! gcc -O2 -Wall -Wextra -pthread -o "$BIN" "$SRC" -lm 2> "$REP.err"; then
          say "結果：編譯失敗"
          say "--- 第一個錯誤（gcc 原文）---"
          grep -m1 -A4 'error' "$REP.err" | cut_lines 8 >> "$REP"
          LN=$(grep -m1 -oE ':[0-9]+:[0-9]+: error' "$REP.err" | cut -d: -f2)
          if [ -n "$LN" ]; then
            say "--- 原始碼第 $((LN>2?LN-2:1))～$((LN+2)) 行 ---"
            sed -n "$((LN>2?LN-2:1)),$((LN+2))p" "$SRC" | nl -ba -v $((LN>2?LN-2:1)) | cut -c1-160 >> "$REP"
          fi
          say "請只修正這個錯誤，給完整程式。"
          emit; rm -f "$REP" "$REP.err" "$BIN"; exit 1
        fi
        W=$(grep -c 'warning' "$REP.err")
        [ "$W" -gt 0 ] && { say "編譯：成功，但有 $W 個 warning（第一個如下）"; grep -m1 'warning' "$REP.err" | cut_lines 1 >> "$REP"; } || say "編譯：成功，0 warning" ;;
  *.py) LTAG=python; RUN="python3 $SRC"
        python3 -m py_compile "$SRC" 2> "$REP.err" || { say "結果：Python 語法錯誤"; cut_lines 8 < "$REP.err" >> "$REP"; emit; rm -f "$REP" "$REP.err" "$BIN"; exit 1; } ;;
  *) echo "只支援 .c / .py"; exit 1 ;;
esac

shopt -s nullglob; INS=("$TDIR"/*.in)
if [ ${#INS[@]} -eq 0 ]; then
  say "（沒有測資，直接執行一次，最多 ${TO} 秒）"
  S=$(date +%s%N); OUTP=$(timeout "$TO" $RUN < /dev/null 2>&1); RC=$?; E=$(( ($(date +%s%N)-S)/1000000 ))
  say "結束碼：$RC（124=逾時，134=assert/abort，139=記憶體錯誤）；時間 ${E} ms"
  say "--- 輸出（前 15 行）---"; printf '%s\n' "$OUTP" | cut_lines 15 >> "$REP"
else
  PASS=0; MAXE=0; FAILED=""; TOTAL=${#INS[@]}
  for IN in "${INS[@]}"; do
    EXP="${IN%.in}.out"; S=$(date +%s%N)
    GOT=$(timeout "$TO" $RUN < "$IN" 2>"$REP.se"); RC=$?; E=$(( ($(date +%s%N)-S)/1000000 )); [ $E -gt $MAXE ] && MAXE=$E
    if [ $RC -eq 0 ] && [ -f "$EXP" ] && diff -q <(printf '%s\n' "$GOT" | sed 's/[[:space:]]*$//') <(sed 's/[[:space:]]*$//' "$EXP") >/dev/null; then
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
            if (p == q) printf "👉 這一行只差在「空白」：內容都對，請只改 printf 的格式字串，讓空白位置和預期一模一樣（␣ 是空白；例如逗號後面要不要空格）。不要改其他邏輯。\n"
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
