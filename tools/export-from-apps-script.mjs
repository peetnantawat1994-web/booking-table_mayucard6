// Copies the CURRENT live data (zones, tables, bookings, settings) out of the
// old Google Apps Script backend and writes it as SQL for Supabase.
//
//   node tools/export-from-apps-script.mjs
//
// Output: supabase/seed-data.sql  (git-ignored — it holds customers' contact
// details). Run it right before switching over, then paste the file into the
// Supabase SQL Editor. Re-running the SQL is safe: rows are upserted.

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const SCRIPT_URL =
  "https://script.google.com/macros/s/AKfycbwWuBZocTo25f4kTVW0_oJ7hnf3clLidUAtQauruui2LQB1_tssrCMQVyjnWf5QJa3WnQ/exec";

const res = await fetch(SCRIPT_URL + "?action=getAll", { cache: "no-store" });
const json = await res.json();
if (!json || !json.ok) throw new Error("getAll failed: " + JSON.stringify(json).slice(0, 200));
const d = json.data || {};

const rows = [];
for (const col of ["zones", "tables", "bookings"]) {
  for (const [id, data] of Object.entries(d[col] || {})) rows.push([col, id, data]);
}
if (d.config?.settings) rows.push(["config", "settings", d.config.settings]);
if (d.config?.customFields) rows.push(["config", "customFields", d.config.customFields]);

// dollar-quote with a tag that can't appear in the data
const quote = (s) => {
  let tag = "mc";
  while (s.includes("$" + tag + "$")) tag += "x";
  return `$${tag}$${s}$${tag}$`;
};

const values = rows
  .map(([col, id, data]) => `  ('live', ${quote(col)}, ${quote(id)}, ${quote(JSON.stringify(data))}::jsonb)`)
  .join(",\n");

const sql = `-- generated ${new Date().toISOString()} from the Apps Script backend
-- ${rows.filter((r) => r[0] === "bookings").length} bookings, ${rows.filter((r) => r[0] === "tables").length} tables, ${rows.filter((r) => r[0] === "zones").length} zones
insert into public.documents (store, collection, id, data) values
${values}
on conflict (store, collection, id) do update set data = excluded.data, updated_at = now();

-- start the admin draft fresh from this live data
delete from public.documents where store = 'draft';
`;

const out = join(dirname(fileURLToPath(import.meta.url)), "..", "supabase", "seed-data.sql");
writeFileSync(out, sql);
console.log(`wrote ${out}`);
console.log(sql.split("\n").slice(0, 2).join("\n"));
