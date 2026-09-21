# agent-pr-review

AI review บน pull request ด้วย [pr-agent](https://github.com/qodo-ai/pr-agent) + [QwenCloud](https://www.qwencloud.com/)
เป็น **reusable workflow** เรียกใช้จากโปรเจกต์ไหนก็ได้ด้วย caller ประมาณ 10 บรรทัด

รันบน `ubuntu-latest` ไม่ต้องดูแล runner เอง และ pr-agent ยิง QwenCloud ตรงโดยไม่มี proxy คั่นกลาง
config ส่งผ่าน env กับ CLI ล้วน จึงไม่มีไฟล์คีย์ตกค้างบนดิสก์ของ runner

## ตั้งค่า

1. เอา API key จาก [QwenCloud](https://www.qwencloud.com/)
2. ใส่เป็น secret ชื่อ `DASHSCOPE_API_KEY` **ที่ repo ทุกตัวที่จะถูกรีวิว**
   (`Settings > Secrets and variables > Actions > New repository secret`)
3. ก๊อป `examples/caller.yml` ไปวางที่ `.github/workflows/ai-review.yml` ในโปรเจกต์นั้น
   แล้วแก้ `OWNER` เป็น GitHub username ของคุณ

> ⚠️ GitHub Actions มี secret แค่ 3 ระดับ: repository, environment, organization
> **ไม่มีระดับ personal account** (ที่มีคือของ Codespaces ซึ่งใช้กับ Actions ไม่ได้)
> และบนแพลน Free นั้น org-level secret ก็เข้าถึงจาก private repo ไม่ได้
> สรุปคือต้องใส่ทีละ repo ไม่มีทางลัด — reusable workflow รับ secret จาก caller เสมอ

### ⚠️ กับดัก endpoint — สาเหตุอันดับหนึ่งของ 401

คีย์ต้องยิงไปที่ endpoint ที่ออกคีย์มา ไม่งั้นได้ `401 invalid_api_key`
ซึ่งอ่านแล้วนึกว่าคีย์ผิดหรือก๊อปมาไม่ครบ ทั้งที่คีย์ถูกต้องทุกตัวอักษร
เอกสาร QwenCloud เขียนว่า *"The two key types are not interchangeable — each key is bound to its own base URL"*

| ชนิดคีย์ | prefix | base URL |
|---|---|---|
| Token Plan (รายเดือน) | `sk-sp-` | `https://token-plan.maas.qwencloudapi.com/compatible-mode/v1` |
| Pay-as-you-go | `sk-` / `sk-ws-` | `https://maas.qwencloudapi.com/compatible-mode/v1` |
| Model Studio นอกจีน | `sk-` | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` |
| Model Studio ในจีน | `sk-` | `https://dashscope.aliyuncs.com/compatible-mode/v1` |

ทั้ง workflow และ `compare-models.sh` **เดา endpoint จาก prefix ของคีย์ให้เอง**
(`sk-sp-` → token-plan, นอกนั้น → maas) ปล่อย `api_base` ว่างไว้ได้เลย
ใส่เองเฉพาะเมื่อใช้ Model Studio ซึ่งเดาไม่ได้เพราะขึ้นต้น `sk-` เหมือนกัน

หมายเหตุอีกชั้น: litellm ตั้ง default ของ dashscope **chat** เป็น endpoint ในจีน
(ขณะที่ฝั่ง embed กับ image ใช้ `-intl`) จึงต้อง override ผ่าน `DASHSCOPE_API_BASE` เสมอ

## inputs

ทุกตัวมีค่า default ใส่เฉพาะที่อยากเปลี่ยน

| input | default | หมายเหตุ |
|---|---|---|
| `model` | `dashscope/qwen3.8-flash` | เลือกเพราะราคา ดูผลวัดในคอมเมนต์ของ workflow |
| `api_base` | ว่าง = เดาจาก prefix ของคีย์ | ดูตารางกับดักข้างบน |
| `ai_timeout` | `480` | วินาทีต่อ request — **ถูกคูณ 6** ดูด้านล่าง |
| `custom_model_max_tokens` | `40000` | จำเป็นเมื่อ model ไม่อยู่ใน price map ของ litellm |
| `pr_agent_version` | `0.44.0` | ปักหมุดไว้ อย่าปล่อย latest |
| `run_improve` | `true` | ปิดเพื่อประหยัด GitHub minutes |
| `extra_instructions` | checklist TypeScript | ภาษาอื่นควรเขียนเอง |

### ai_timeout ถูกคูณ 6

ค่าที่ตั้งไม่ใช่เพดานเวลาจริง กรณีแย่สุดคือ

```
pr-agent ลองเอง 2 รอบ           (MODEL_RETRIES=2, tenacity @retry)
× openai SDK ใน litellm 3 รอบ   (max_retries=2 default)
= 6 requests × ai_timeout
```

เวลาตั้งค่านี้ให้คิดเลขก่อนเสมอ และเทียบกับ `timeout-minutes` ของ step Review

## ผลวัด

`scripts/compare-models.sh` วัด latency กับอัตราการทำตามรูปแบบ `SECURITY_STATUS`
โดยยิง provider ตรง (prompt ประมาณของ pr-agent ตัวเลขจึงเป็นขอบล่าง)

วัดเมื่อ 2026-09-21 บน QwenCloud Token Plan · diff 38KB · 5 รอบต่อ model

| model | latency | SECURITY_STATUS |
|---|---|---|
| `qwen3.8-max` | 76-128s · median 116s | 5/5 |
| `qwen3.8-flash` | 41-189s · median 128s | 5/5 |
| `qwen3-coder-plus` | 404 Model not exist บน Token Plan | — |

`max` เร็วกว่าและแกว่งน้อยกว่า (1.7 เท่า เทียบกับ flash 4.6 เท่า) แต่ราคาแพงกว่าราว 13 เท่า
($2.00/$6.00 เทียบกับ $0.15/$0.47 ต่อล้าน token) จึง **เลือก flash เพราะราคา ไม่ใช่เพราะเร็วกว่า**
แล้วชดเชยความแกว่งด้วย `ai_timeout` ที่สูงขึ้น

อัตราการจับบั๊ก: PR ทดสอบที่ฝังบั๊กไว้ 5 ข้อ flash จับได้ 5/5 พร้อมระบุเลขบรรทัดถูกทุกข้อ
**แต่ n=1** วัดรอบเดียวบน diff เดียว ยังสรุปความสม่ำเสมอไม่ได้

> ⚠️ ตัวเลขทั้งหมดนี้ผูกกับ model + provider + ภาษาของโค้ด
> เปลี่ยนอย่างใดอย่างหนึ่งแล้วต้องวัดใหม่ อย่ายกข้ามบริบทมาใช้

## ปักหมุดเวอร์ชัน อย่าใช้ @main

caller ในตัวอย่างชี้ไป `@v1` ไม่ใช่ `@main` โดยตั้งใจ

`@main` เป็น ref ที่เปลี่ยนได้ ทุก push เข้า main จะมีผลทันทีกับทุก repo ที่เรียกใช้
และเนื่องจาก caller ส่ง `DASHSCOPE_API_KEY` เข้ามาด้วย โค้ดที่ยังไม่ถูกรีวิว
จะรันได้โดยเข้าถึงทั้ง secret และเนื้อโค้ดของ PR นั้น

| วิธีปักหมุด | กันความพลาด | กันบัญชีถูกยึด | อัปเดตทุก repo ทีเดียว |
|---|---|---|---|
| `@main` | ไม่ | ไม่ | ได้ |
| `@v1` (tag) | ได้ | ไม่ (tag เลื่อนได้) | ได้ |
| `@<commit sha>` | ได้ | ได้ | ไม่ ต้องไล่แก้ทีละ repo |

ปล่อยเวอร์ชันใหม่ด้วยการเลื่อน tag

```bash
git tag -fa v1 -m "release v1" && git push -f origin v1
```

ถ้าต้องการความปลอดภัยสูงสุด ให้ใช้ commit SHA แทนแล้วยอมไล่อัปเดตเอง

## ทำให้ Gate บล็อก merge ได้จริง

⚠️ ติดตั้ง workflow เฉย ๆ **ยังไม่บล็อกอะไร** — check จะขึ้นแดงแต่กด Merge ได้ตามปกติ
ต้องไปตั้งเป็น required status check ที่ `Settings > Branches`
ชื่อ check อยู่ในรูป `<ชื่อ job ใน caller> / review` เช่น `ai-review / review`
GitHub ให้เลือกจากรายการ check ที่เคยเห็นแล้วเท่านั้น จึงต้องเปิด PR ทดสอบก่อนหนึ่งอัน

ทดสอบ **ทั้งสองเส้นทาง** ก่อนไว้ใจ — Gate ที่บล็อกเป็นแต่ไม่เคยปล่อยผ่าน คือ Gate ที่ใช้งานไม่ได้
เปิด PR ที่มีปัญหาจริงหนึ่งอัน (ต้องแดง) และ PR ที่สะอาดหนึ่งอัน (ต้องเขียว)

## เมื่อ Gate บล็อกความเสี่ยงที่คุณยอมรับแล้ว

Gate บล็อกทุก `SECURITY_STATUS: FINDINGS` รวมถึงความเสี่ยงที่คุณประเมินแล้วว่ารับได้
ถ้าเจอบ่อยจนน่ารำคาญ **อย่าปิด Gate** — ให้ประกาศความเสี่ยงนั้นใน `extra_instructions` แทน

สิ่งสำคัญคือ **เขียนให้แคบ** ประกาศกว้าง ๆ ว่า "ไม่ต้องสนใจเรื่อง supply chain"
จะกลายเป็นจุดบอดถาวรที่คุณลืมไปแล้วว่าเคยปิดไว้ วิธีที่ปลอดภัยคือระบุเคสที่ยอมรับ
**คู่กับ** เคสที่ยังต้องรายงานเสมอ

```yaml
        ความเสี่ยงที่ประเมินและยอมรับแล้วสำหรับโปรเจกต์นี้ ไม่ต้องรายงาน:
        การเรียก reusable workflow จาก repo ของเจ้าของคนเดียวกัน ที่ปักหมุดด้วย tag หรือ commit SHA
        และการส่ง secret ให้ workflow นั้น ถือว่ายอมรับได้
        แต่ยังต้องรายงานถ้าพบ: เรียก workflow หรือ action ของเจ้าของรายอื่น
        หรืออ้างอิงด้วย ref ที่เปลี่ยนได้อย่าง @main หรือชื่อ branch
        หรือส่ง secret ให้ปลายทางที่ไม่จำเป็นต้องใช้
```

ประโยคท่อนหลังคือส่วนที่ทำให้การยกเว้นไม่กลายเป็นการปิดตา

## สิ่งที่ห้ามลบเพราะคิดว่าไม่จำเป็น

โค้ดป้องกันหลายจุดดูเกินจำเป็น แต่ทุกอันมาจากอาการที่เกิดขึ้นจริง

- **เช็ค log หลัง pr-agent ว่ามีคำว่า `Failed to ...`** — pr-agent คืน exit 0 แม้รีวิวล้ม
  ถ้าไม่เช็ค step จะเขียวทั้งที่ไม่ได้รีวิวอะไรเลย แล้วไปโผล่ผิดที่ที่ Gate ทีหลัง
- **`RC=0; X=$(curl ...) || RC=$?`** — เขียน `X=$(curl ...)` เฉย ๆ คู่กับ `set -e`
  จะทำให้ step ตายก่อนพิมพ์ error เหลือแค่ exit code ลอย ๆ
- **Gate ถอด HTML tag ก่อน grep** — คอมเมนต์ GitHub เป็น HTML และ pr-agent แทรก tag
  คั่นกลาง token ของจริงที่เจอคือ `<strong>No⏎SECURITY_STATUS:</strong><br> CLEAN`
  ถ้า grep ตรง ๆ จะไม่เจอ แล้ว check จะแดงทุกครั้งที่โค้ดสะอาด
- **ห้าม grep คำว่า "Security concerns" ลอย ๆ** — มันคือหัวข้อที่มีทุกครั้งแม้ตอนสะอาด
- **`--config.fallback_models='[]'`** — default ของ pr-agent ไม่ใช่ลิสต์ว่าง
  ถ้าไม่ปิด มันจะพยายาม fallback ไป provider อื่นเอง
- **ลบ placeholder ด้วย `if: always()`** — improve โพสต์ "Work in progress" ก่อนทำงาน
  ถ้า job ตายกลางทาง placeholder จะค้างบน PR ตลอดไป
- **`extra_instructions` override สัญญา SECURITY_STATUS ไม่ได้** — workflow ต่อท้ายให้เสมอ
  กันเคสที่ปรับ checklist ต่อโปรเจกต์แล้วเผลอทำ Gate ตายไปด้วย
- **ไม่มี `actions/checkout`** — ไม่ใช่ลืม pr-agent ดึง diff ผ่าน GitHub API ไม่ได้ใช้ working tree

## ข้อจำกัด

- PR จาก fork ไม่ได้ secret ตาม security model ของ GitHub — review จะไม่รัน
- `improve` รันเฉพาะตอนเปิด PR ไม่รันทุก push เพราะช้ากว่า review ได้หลายเท่า
- diff ของทุก PR ถูกส่งออกไปที่ QwenCloud — พิจารณาก่อนใช้กับโค้ดที่อ่อนไหว
- reusable workflow จาก repo **private** เรียกได้เฉพาะ caller ที่เป็น private ด้วยกัน
  ถ้า caller เป็น public repo นี้ต้องเป็น public ด้วย
