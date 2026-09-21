#!/usr/bin/env bash
#
# compare-models.sh — วัด model ก่อนเอาไปใช้จริง
#
# ทำไมต้องมี: ผลวัดคุณภาพและค่า ai_timeout ผูกกับ model + provider + ภาษาของโค้ด
# เปลี่ยนอย่างใดอย่างหนึ่ง = ตัวเลขชุดเดิมเป็นโมฆะทั้งหมด
# ต้องวัดใหม่เสมอ อย่ายกตัวเลขข้ามบริบทมาใช้
#
# สคริปต์นี้วัดสองอย่างที่ตัดสินว่า setup ใช้ได้จริงไหม:
#   1. latency distribution  -> เอาไปตั้ง ai_timeout
#   2. SECURITY_STATUS compliance -> Gate จะมีผลจริงหรือไร้ผลเงียบ ๆ
#
# ⚠️ ข้อจำกัดที่ต้องรู้: สคริปต์ยิง provider ตรง ด้วย prompt ที่ "ประมาณ" ของ pr-agent
#    ของจริง pr-agent ส่ง system prompt ยาวกว่านี้ ตัวเลข latency ที่ได้จึงเป็น
#    ขอบล่าง (lower bound) ไม่ใช่ค่าที่จะเจอบน CI เป๊ะ ๆ — เผื่อไว้เสมอ
#
# ใช้:
#   export DASHSCOPE_API_KEY=...
#   git diff main...HEAD > /tmp/sample.diff
#   ./scripts/compare-models.sh --diff /tmp/sample.diff --rounds 5
#
set -euo pipefail

API_BASE_ENV="${DASHSCOPE_API_BASE:-}"   # ถ้าไม่ตั้ง จะเดาจาก prefix ของคีย์ด้านล่าง
DIFF_FILE=""
ROUNDS=5
MODELS="qwen3-coder-plus,qwen3-max"
MAX_TIME=600

while [ $# -gt 0 ]; do
  case "$1" in
    --diff)   DIFF_FILE="${2:?--diff ต้องตามด้วย path}"; shift 2 ;;
    --rounds) ROUNDS="${2:?}"; shift 2 ;;
    --models) MODELS="${2:?}"; shift 2 ;;
    --max-time) MAX_TIME="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,28p' "$0"; exit 0 ;;
    *) echo "ไม่รู้จัก option: $1" >&2; exit 2 ;;
  esac
done

: "${DASHSCOPE_API_KEY:?ต้อง export DASHSCOPE_API_KEY ก่อน}"
[ -n "$DIFF_FILE" ] || { echo "ต้องระบุ --diff <file>" >&2; exit 2; }
[ -f "$DIFF_FILE" ] || { echo "ไม่พบไฟล์: $DIFF_FILE" >&2; exit 2; }
command -v python3 >/dev/null || { echo "ต้องมี python3" >&2; exit 2; }

DIFF_BYTES=$(wc -c < "$DIFF_FILE" | tr -d ' ')
if [ "$DIFF_BYTES" -eq 0 ]; then
  echo "diff ว่างเปล่า (0 bytes): $DIFF_FILE" >&2
  echo "วัดกับ diff ว่างไม่มีความหมาย — สร้างใหม่ก่อน เช่น" >&2
  echo "  git -C <repo> diff HEAD~5 HEAD > $DIFF_FILE" >&2
  exit 2
fi

# เลือก endpoint จากชนิดของคีย์ — QwenCloud ผูกคีย์กับ base URL แบบสลับกันไม่ได้
# (เอกสาร: "The two key types are not interchangeable — each key is bound to its own base URL")
# ใส่ค่านี้ผิด = 401 invalid_api_key ซึ่งอ่านแล้วนึกว่าคีย์เสีย ทั้งที่คีย์ถูกทุกตัวอักษร
case "$DASHSCOPE_API_KEY" in
  sk-sp-*) KEY_KIND="Token Plan";     GUESS_BASE="https://token-plan.maas.qwencloudapi.com/compatible-mode/v1" ;;
  sk-ws-*) KEY_KIND="Pay-as-you-go (workspace)"; GUESS_BASE="https://maas.qwencloudapi.com/compatible-mode/v1" ;;
  sk-*)    KEY_KIND="Pay-as-you-go";  GUESS_BASE="https://maas.qwencloudapi.com/compatible-mode/v1" ;;
  *)       KEY_KIND="ไม่รู้จัก (ไม่ขึ้นต้นด้วย sk-)"; GUESS_BASE="https://maas.qwencloudapi.com/compatible-mode/v1" ;;
esac

echo "key: ยาว ${#DASHSCOPE_API_KEY} ตัวอักษร · ชนิดที่เดาได้: $KEY_KIND"
case "$DASHSCOPE_API_KEY" in
  sk-*) : ;;
  *) echo "  ⚠️ ไม่ขึ้นต้นด้วย sk- — แน่ใจนะว่าก๊อปคีย์มาครบ ไม่ใช่ placeholder" ;;
esac
case "$DASHSCOPE_API_KEY" in
  *[[:space:]]*) echo "  ⚠️ มีช่องว่าง/ขึ้นบรรทัดใหม่ปนในคีย์ — มักเกิดตอนก๊อปวาง จะทำให้ auth ไม่ผ่าน" ;;
esac

if [ -n "$API_BASE_ENV" ]; then
  API_BASE="$API_BASE_ENV"
  if [ "$API_BASE" != "$GUESS_BASE" ]; then
    echo "  ⚠️ endpoint ที่คุณระบุไม่ตรงกับชนิดคีย์ที่เดาได้ — ถ้าเจอ 401 ให้ลอง $GUESS_BASE"
  fi
else
  API_BASE="$GUESS_BASE"
fi

echo "diff: $DIFF_FILE ($DIFF_BYTES bytes) · rounds: $ROUNDS · endpoint: $API_BASE"
echo

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# สัญญาเดียวกับที่ workflow ต่อท้ายให้เสมอ — ต้องเหมือนกันเป๊ะ ไม่งั้นวัดคนละอย่างกับของจริง
CONTRACT='ปิดท้ายส่วน security ด้วยบรรทัดเดียวเป๊ะ ๆ ว่า SECURITY_STATUS: CLEAN ถ้าไม่พบปัญหาด้านความปลอดภัยเลย หรือ SECURITY_STATUS: FINDINGS ถ้าพบ บรรทัดนี้ต้องมีเสมอและห้ามเปลี่ยนรูปแบบ เพราะ CI อ่านบรรทัดนี้ตัดสินว่าจะบล็อก merge ไหม'

for MODEL in $(printf '%s' "$MODELS" | tr ',' ' '); do
  echo "=== $MODEL ==="
  : > "$WORK/times"
  COMPLY=0; OK=0; FAIL=0

  # สร้าง payload ด้วย python3 เพราะ diff มี quote/newline/backslash ที่ทำ JSON พังถ้าต่อ string เอง
  MODEL="$MODEL" DIFF_FILE="$DIFF_FILE" CONTRACT="$CONTRACT" python3 - > "$WORK/payload.json" <<'PYEOF'
import json, os, io
diff = io.open(os.environ["DIFF_FILE"], encoding="utf-8", errors="replace").read()
prompt = (
    "คุณคือ code reviewer ตรวจ diff ต่อไปนี้และรายงานเฉพาะปัญหาที่พบจริง "
    "พร้อมชื่อฟังก์ชันและบรรทัด จากนั้น" + os.environ["CONTRACT"] + "\n\n```diff\n" + diff + "\n```"
)
json.dump({
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": prompt}],
    "temperature": 0.2,
    "max_tokens": 2000,
}, io.open(1, "w", encoding="utf-8", closefd=False), ensure_ascii=False)
PYEOF

  for i in $(seq 1 "$ROUNDS"); do
    # ⚠️ อย่าเขียน X=$(curl ...) เฉย ๆ — set -e จะฆ่าสคริปต์ทันทีที่ curl ไม่ใช่ 0
    #    แล้วบรรทัดรายงาน error ข้างล่างจะไม่ถูกพิมพ์เลย เหลือแค่ exit code ลอย ๆ
    RC=0
    METRICS=$(curl -sS -o "$WORK/body.json" -w '%{http_code} %{time_total}' \
                --max-time "$MAX_TIME" "$API_BASE/chat/completions" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $DASHSCOPE_API_KEY" \
                --data-binary @"$WORK/payload.json") || RC=$?

    if [ "$RC" != "0" ]; then
      FAIL=$((FAIL+1)); printf '  รอบ %s: curl ล้ม (exit %s)\n' "$i" "$RC"; continue
    fi

    CODE=${METRICS%% *}; SECS=${METRICS##* }

    if [ "$CODE" = "401" ] || [ "$CODE" = "403" ]; then
      # auth พังคือพังเหมือนกันทุกรอบทุก model — ยิงต่อไม่ได้อะไรนอกจากเสียเวลา
      echo
      echo "HTTP $CODE: auth ไม่ผ่าน — หยุดทันที ไม่ไล่ยิงรอบที่เหลือ" >&2
      head -c 300 "$WORK/body.json" >&2; echo >&2
      echo >&2
      echo "เช็คตามลำดับนี้:" >&2
      echo "  1. endpoint ต้องตรงกับ *ชนิด* ของคีย์ (สลับกันไม่ได้):" >&2
      echo "       sk-sp-...  (Token Plan)    -> https://token-plan.maas.qwencloudapi.com/compatible-mode/v1" >&2
      echo "       sk-... / sk-ws-... (PAYG)  -> https://maas.qwencloudapi.com/compatible-mode/v1" >&2
      echo "     ส่วนคีย์จาก Alibaba Cloud Model Studio ใช้" >&2
      echo "       https://dashscope-intl.aliyuncs.com/compatible-mode/v1  (นอกจีน)" >&2
      echo "       https://dashscope.aliyuncs.com/compatible-mode/v1       (ในจีน)" >&2
      echo "     สลับด้วย: DASHSCOPE_API_BASE=<url> $0 ..." >&2
      echo "  2. คีย์ถูกก๊อปมาครบไหม ดูบรรทัด 'key: ยาว N ตัวอักษร' ด้านบน" >&2
      echo "  3. คีย์ยัง active อยู่ไหม / เครดิตหมดหรือยัง" >&2
      exit 1
    fi

    if [ "$CODE" != "200" ]; then
      FAIL=$((FAIL+1))
      printf '  รอบ %s: HTTP %s — %s\n' "$i" "$CODE" "$(head -c 200 "$WORK/body.json")"
      continue
    fi

    OK=$((OK+1)); echo "$SECS" >> "$WORK/times"

    # ดึงเนื้อคำตอบแล้วเช็คว่าทำตามสัญญาไหม (ถอด HTML tag แบบเดียวกับ Gate)
    if python3 -c "
import json,io,sys,re
d=json.load(io.open('$WORK/body.json',encoding='utf-8'))
t=d['choices'][0]['message'].get('content') or ''
flat=re.sub(r'\s+',' ',re.sub(r'<[^>]*>',' ',t))
sys.exit(0 if re.search(r'SECURITY_STATUS:\s*(CLEAN|FINDINGS)',flat) else 1)
" 2>/dev/null; then
      COMPLY=$((COMPLY+1)); printf '  รอบ %s: %ss · SECURITY_STATUS ✓\n' "$i" "$SECS"
    else
      printf '  รอบ %s: %ss · SECURITY_STATUS ✗ (ไม่ทำตามรูปแบบ)\n' "$i" "$SECS"
    fi
  done

  echo
  if [ "$OK" -gt 0 ]; then
    OK="$OK" COMPLY="$COMPLY" FAIL="$FAIL" ROUNDS="$ROUNDS" python3 - "$WORK/times" <<'PYEOF'
import sys, os, io
xs = sorted(float(l) for l in io.open(sys.argv[1]) if l.strip())
n = len(xs)
med = xs[n//2] if n % 2 else (xs[n//2-1] + xs[n//2]) / 2
ok, comply, fail, rounds = (int(os.environ[k]) for k in ("OK","COMPLY","FAIL","ROUNDS"))
print(f"  สำเร็จ {ok}/{rounds} · ล้ม {fail}")
print(f"  latency  min {xs[0]:.1f}s · median {med:.1f}s · max {xs[-1]:.1f}s")
print(f"  SECURITY_STATUS ทำตามรูปแบบ {comply}/{ok}")
sug = max(120, int(xs[-1] * 2.5 / 30 + 1) * 30)
print(f"  → ai_timeout ที่แนะนำ ~{sug}s (max × 2.5 เผื่อ variance + prompt จริงยาวกว่านี้)")
print(f"    ⚠️ กรณีแย่สุด {sug} × 6 = {sug*6/60:.0f} นาที ต้องไม่เกิน timeout-minutes ของ step Review")
if comply < ok:
    print(f"    ⚠️ ไม่ทำตามสัญญา {ok-comply}/{ok} รอบ — Gate จะปล่อยผ่านเงียบ ๆ ในสัดส่วนนี้")
    print("       ถ้าจะให้ Gate บล็อก merge ได้จริง ต้องได้ compliance เต็มก่อน")
PYEOF
  else
    echo "  ไม่มีรอบไหนสำเร็จเลย — เช็ค key / api_base (ต้องเป็น -intl สำหรับ QwenCloud นอกจีน) / ชื่อ model"
  fi
  echo
done
