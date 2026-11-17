# ออกเวอร์ชันใหม่ และย้อนกลับ

## ตั้งค่าครั้งแรก (ทำครั้งเดียว)
**Netlify** → ไซต์ `bookingmayucard6` → **Site configuration → Build & deploy**
1. **Link repository** → GitHub → `booking-table_mayucard6`
2. Production branch: `main` · Publish directory: `.` · Build command: เว้นว่าง
3. **Branches and deploy contexts** → Deploy Previews: *Any pull request* · Branch deploys: *All*

> ก่อนกด Link ให้ push `main` ขึ้น GitHub ก่อน — `main` คือไฟล์เดียวกับที่เว็บใช้อยู่ตอนนี้ เว็บจึงไม่เปลี่ยน

## ออกเวอร์ชันใหม่ (ทุกครั้ง)
1. แตก branch ใหม่จาก `main` เช่น `fix/ชื่องาน` หรือ `feature/ชื่องาน`
2. แก้และ commit ใน branch นั้น แล้ว push
3. เปิด **Pull Request** เข้า `main` → Netlify สร้างลิงก์ **Deploy Preview** ให้
4. ทดสอบบนลิงก์ preview (มือถือ + คอม, ฝั่งลูกค้า + แอดมิน)
   ⚠️ preview ใช้ฐานข้อมูลเดียวกับเว็บจริง การจองทดสอบจะเข้าไปจริง ลบทิ้งหลังทดสอบ
5. ผ่านแล้วค่อย **Merge** → Netlify ขึ้นเว็บจริงเอง
   และ GitHub Action จะสร้าง tag `backup/<วันเวลา>-<commit>` ของเวอร์ชันก่อนหน้าให้อัตโนมัติ

## ย้อนกลับเมื่อเวอร์ชันใหม่มีปัญหา
**ทันที (ไม่กี่วินาที):** Netlify → **Deploys** → คลิก deploy ก่อนหน้าที่ใช้งานได้ → **Publish deploy**
เว็บกลับเป็นเวอร์ชันเดิมทันที (Netlify จะหยุด auto-publish ไว้ให้จนกว่าจะเปิดอีกครั้ง)

**จากนั้นแก้ `main` ให้ตรงกัน** (ไม่อย่างนั้น push ครั้งหน้าจะเอาเวอร์ชันที่พังกลับมา):
- GitHub → Pull request ที่ merge ไป → ปุ่ม **Revert** → merge PR ที่ revert
- หรือใน Terminal ย้อน `main` กลับไปที่ tag backup:
  ```bash
  git checkout main && git reset --hard backup/<ชื่อ-tag> && git push --force-with-lease origin main
  ```
แล้วกลับไปที่ Netlify → Deploys → **Start auto publishing**

ดู tag backup ทั้งหมด: GitHub → repo → **Tags** หรือ `git tag -l 'backup/*'`
