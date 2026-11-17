# สลับจาก Google Sheet ไป Supabase (production)

ข้อมูลทั้งหมดถูกย้ายไปรอใน Supabase `mayucard6-prod` แล้ว (ตรวจเทียบกับ Sheet ทีละรายการ) หน้าเว็บใน branch นี้ชี้ไปที่ระบบจริงนั้น
**ลูกค้ายังใช้ระบบ Google Sheet จนกว่าจะ merge**

## ก่อนสลับ
1. มีแอดมินจริงใน Supabase (Authentication → Users → Add user, ติ๊ก Auto Confirm) และเพิ่มในตาราง `admins`
2. ทดสอบหน้า Deploy Preview ของ Pull Request (ล็อกอินแอดมิน, ดูรายการจอง) — ⚠️ preview ใช้ฐานข้อมูลจริง ห้ามจอง/แก้ไขโดยไม่จำเป็น
3. เลือกเวลาที่คนจองน้อย

## ลำดับสลับ
```bash
# 0. สำรองข้อมูลไว้ในเครื่อง (ใช้ getAll ของระบบเก่า) แล้วซิงก์การจองใหม่ล่าสุด
node tools/sync-from-apps-script.mjs --mode delta --supabase-url <URL> --anon <ANON> \
     --apps-script <APPS_SCRIPT_URL> --out /tmp/delta.sql --map /tmp/uploads-map.json
#    แล้วรันไฟล์ /tmp/delta.sql ใน Supabase SQL Editor (ถ้า "to insert 0" ไม่ต้องรัน)
# 1. merge Pull Request (squash) → Netlify deploy เอง ~1–2 นาที
#    GitHub Action จะ tag เวอร์ชันก่อนหน้าเป็น backup/... ให้
# 2. ตรวจเว็บจริง: ผังโหลด, จองโต๊ะทดสอบ 1 โต๊ะ (แล้วลบ), ล็อกอินแอดมิน
# 3. ซิงก์ delta อีกครั้งทันที และซ้ำ ที่ +10 นาที, +1 ชม., ทุกวัน 1 สัปดาห์
#    (เก็บการจองที่ลูกค้าส่งจากหน้าเก่าที่ยังเปิดค้างและเขียนเข้า Sheet)
```
โหมด `delta` **ไม่ทับ** ข้อมูลใน Supabase: เพิ่มเฉพาะการจองที่ยังไม่มี และรายงานโต๊ะที่สถานะไม่ตรงกัน (ให้ตรวจเอง)

## ย้อนกลับ
1. Netlify → Deploys → เลือก deploy ก่อนหน้า → **Publish deploy** (ลูกค้ากลับไปใช้ Google Sheet ทันที)
2. การจองที่เกิดใน Supabase หลังสลับจะ**ไม่อยู่ใน Sheet** ให้ export จาก Supabase (Table Editor → documents → collection = bookings) แล้วคัดลอกเข้า Sheet ก่อนเปิดระบบเก่าให้ลูกค้าอีกครั้ง
3. ย้อน `main` ให้ตรงกัน: ใช้ tag `backup/...` ตามขั้นตอนใน DEPLOY.md

## ไฟล์ที่ห้ามขึ้น Git
`supabase/seed-data.sql`, `supabase/migration*.sql`, `*uploads-map*.json` — มีข้อมูลติดต่อลูกค้า
