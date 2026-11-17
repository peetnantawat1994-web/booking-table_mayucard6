// Copies data from the OLD Google Apps Script backend into Supabase, as SQL.
//
//   node tools/sync-from-apps-script.mjs --mode initial|delta \
//        --supabase-url https://xxxx.supabase.co --anon <anon key> \
//        --apps-script <web app url> --out <file.sql> [--map <uploads-map.json>]
//
// mode initial : zones, tables, settings and ALL bookings (upsert; the Sheet wins).
// mode delta   : ONLY bookings that Supabase does not have yet (insert, never
//                overwrite). Use it right before / after the switch and while the
//                old Sheet backend may still receive bookings from open browser tabs.
//                Bookings present on both sides with a different status/price are
//                only REPORTED, never changed.
//
// Slip/logo images that live on Google Drive are downloaded and copied to the
// Supabase "uploads" bucket (the Drive URL is kept as `driveUrl`). The map file
// remembers what was already copied, so re-running never uploads twice.
// The output SQL holds customers' contact details: keep it OUT of git.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";

const arg = (n, d) => { const i = process.argv.indexOf("--" + n); return i > -1 ? process.argv[i + 1] : d; };
const mode = arg("mode"), SB = arg("supabase-url"), ANON = arg("anon"), GAS = arg("apps-script"), OUT = arg("out"), MAP = arg("map");
if (!["initial", "delta"].includes(mode) || !SB || !ANON || !GAS || !OUT) {
  console.error("usage: --mode initial|delta --supabase-url U --anon K --apps-script U --out file.sql [--map map.json]"); process.exit(2);
}
const map = MAP && existsSync(MAP) ? JSON.parse(readFileSync(MAP, "utf8")) : {};
const ALLOWED = { "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp", "image/gif": "gif" };
const MAX_BYTES = 5 * 1024 * 1024;

const res = await fetch(GAS + "?action=getAll", { cache: "no-store" });
const json = await res.json();
if (!json?.ok) throw new Error("getAll failed: " + JSON.stringify(json).slice(0, 200));
const d = json.data || {};

async function copyImage(file, kind, warnings, label) {
  if (!file || !file.dataUrl) return file || null;
  const src = file.dataUrl;
  if (src.startsWith(SB + "/storage/")) return file;                 // already ours
  if (map[src]) return { ...file, dataUrl: map[src], driveUrl: /^https:/.test(src) ? src : file.driveUrl };
  try {
    let bytes, type;
    if (src.startsWith("data:")) {
      const m = /^data:([^;]+);base64,(.+)$/s.exec(src); if (!m) throw new Error("bad data URI");
      type = m[1]; bytes = Buffer.from(m[2], "base64");
    } else if (/^https:\/\//.test(src)) {
      const r = await fetch(src, { redirect: "follow" }); if (!r.ok) throw new Error("download HTTP " + r.status);
      type = (r.headers.get("content-type") || "").split(";")[0].trim(); bytes = Buffer.from(await r.arrayBuffer());
    } else throw new Error("unsupported URL");
    const ext = ALLOWED[type]; if (!ext) throw new Error("type " + type + " not allowed");
    if (bytes.length > MAX_BYTES) throw new Error("too large");
    const path = `${kind}/${randomUUID()}.${ext}`;
    const up = await fetch(`${SB}/storage/v1/object/uploads/${path}`, { method: "POST", headers: { apikey: ANON, authorization: "Bearer " + ANON, "content-type": type }, body: bytes });
    if (!up.ok) throw new Error("upload HTTP " + up.status + " " + (await up.text()).slice(0, 100));
    const url = `${SB}/storage/v1/object/public/uploads/${path}`;
    map[src] = url;
    return { ...file, dataUrl: url, driveUrl: /^https:/.test(src) ? src : file.driveUrl };
  } catch (e) {
    warnings.push(`${label}: image not copied (${e.message}); keeping original link`);
    return /^https:/.test(src) ? file : null;
  }
}

const quote = (s) => { let tag = "mc"; while (s.includes("$" + tag + "$")) tag += "x"; return `$${tag}$${s}$${tag}$`; };
const row = (col, id, data) => `  ('live', ${quote(col)}, ${quote(id)}, ${quote(JSON.stringify(data))}::jsonb)`;

// what Supabase already has (public view: ids + status only)
const pubRes = await fetch(`${SB}/rest/v1/rpc/get_public_state`, { method: "POST", headers: { apikey: ANON, authorization: "Bearer " + ANON, "content-type": "application/json" }, body: "{}" });
const pub = await pubRes.json();
const have = pub?.bookings || {};

const warnings = [], notes = [];
const bookingRows = [];
let skipped = 0, conflicts = 0;
for (const [id, b0] of Object.entries(d.bookings || {})) {
  if (mode === "delta" && have[id]) {
    skipped++;
    if ((have[id].status || "pending") !== (b0.status || "pending")) { conflicts++; notes.push(`${id}: status differs (supabase=${have[id].status}, sheet=${b0.status}) - left untouched`); }
    continue;
  }
  const b = { ...b0 };
  b.slipData = await copyImage(b.slipData, "slip", warnings, id + " slip");
  b.logoData = await copyImage(b.logoData, "logo", warnings, id + " logo");
  b.hasSlip = !!b.slipData; b.hasLogo = !!b.logoData;
  bookingRows.push(row("bookings", id, b));
}

const layoutRows = [];
if (mode === "initial") {
  for (const col of ["zones", "tables"]) for (const [id, v] of Object.entries(d[col] || {})) layoutRows.push(row(col, id, v));
  const s = d.config?.settings;
  if (s) {
    if (s.paymentAccountImage) s.paymentAccountImage = await copyImage(s.paymentAccountImage, "other", warnings, "payment image");
    layoutRows.push(row("config", "settings", s));
  }
  if (d.config?.customFields) layoutRows.push(row("config", "customFields", d.config.customFields));
}

let sql = `-- generated ${new Date().toISOString()} mode=${mode} | ${bookingRows.length} bookings to insert, ${layoutRows.length} layout docs\n`;
if (layoutRows.length) sql += `insert into public.documents (store, collection, id, data) values\n${layoutRows.join(",\n")}\non conflict (store, collection, id) do update set data = excluded.data, updated_at = now();\n\n`;
if (bookingRows.length) {
  sql += `insert into public.documents (store, collection, id, data) values\n${bookingRows.join(",\n")}\n`;
  sql += mode === "initial" ? `on conflict (store, collection, id) do update set data = excluded.data, updated_at = now();\n\n` : `on conflict (store, collection, id) do nothing;\n\n`;
}
if (mode === "initial") sql += `select public._reset_draft();\n`;
sql += `select count(*) filter (where collection='bookings' and store='live') as bookings, count(*) filter (where collection='tables' and store='live') as tables, count(*) filter (where collection='zones' and store='live') as zones from public.documents;\n`;
writeFileSync(OUT, sql, { mode: 0o600 });
if (MAP) writeFileSync(MAP, JSON.stringify(map, null, 1), { mode: 0o600 });

console.log(`mode=${mode}: sheet has ${Object.keys(d.bookings || {}).length} bookings | already in supabase ${skipped} | to insert ${bookingRows.length} | layout docs ${layoutRows.length}`);
for (const n of notes) console.log("NOTE", n);
for (const w of warnings) console.log("WARN", w);
console.log("wrote", OUT);
