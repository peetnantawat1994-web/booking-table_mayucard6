# MAYUCARD 6 — ระบบจองบูท

เว็บจริง: https://bookingmayucard6.netlify.app/
Netlify deploy อัตโนมัติจาก branch **`main`** ของ repo นี้

## กติกา (สำคัญ)
1. **`main` = เว็บที่ลูกค้าใช้อยู่** ห้ามแก้หรือ commit ลง `main` โดยตรง
2. ทุกการแก้ไขทำใน **branch ใหม่** → ทดสอบบนลิงก์ preview ของ Netlify → แล้วค่อย merge เข้า `main`
3. ก่อนเวอร์ชันใหม่ขึ้นทุกครั้ง เวอร์ชันเดิมจะถูก **backup เป็น tag `backup/...` อัตโนมัติ** (GitHub Action)
4. ถ้าเวอร์ชันใหม่มีปัญหา **ย้อนกลับได้ทันที** ดูวิธีใน [DEPLOY.md](DEPLOY.md)

## โครงสร้าง
```
index.html                              หน้าเว็บ (ลูกค้า + แอดมิน) ไฟล์เดียว
netlify.toml                            ตั้งค่า Netlify (ไม่มี build)
.github/workflows/backup-production.yml backup เวอร์ชันเดิมทุกครั้งที่ main เปลี่ยน
DEPLOY.md                               ขั้นตอนออกเวอร์ชันใหม่ + ย้อนกลับ
```
