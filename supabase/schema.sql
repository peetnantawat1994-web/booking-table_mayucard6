-- =====================================================================
-- MAYUCARD 6 — Supabase backend
-- Run this whole file once in Supabase: Dashboard > SQL Editor > New query.
-- It is safe to run again (everything is "create or replace" / "if not exists").
--
-- Design
--   * One table, `documents`, keeps the same collection/id document model the
--     front end already uses (zones, tables, bookings, config), in two stores:
--       live  = what customers see
--       draft = the admin's working copy of the LAYOUT (zones/tables/config)
--     Bookings are never drafted: they always live in `live`.
--   * Nobody can touch the table directly (RLS on, no policies). Every read and
--     write goes through the functions below, which decide what each caller
--     may see or change.
--   * The public read (get_public_state) returns NO customer contact details,
--     only which tables are booked (+ the logo once a booking is paid).
--   * Admins are Supabase Auth users listed in `admins`.
-- =====================================================================

create table if not exists public.documents (
  store      text not null check (store in ('live','draft')),
  collection text not null,
  id         text not null,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (store, collection, id)
);
alter table public.documents enable row level security;
revoke all on public.documents from anon, authenticated;

create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from anon, authenticated;

-- ---------------------------------------------------------------------
-- helpers (not callable from the browser)
-- ---------------------------------------------------------------------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public._require_admin() returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_admin() then
    raise exception 'not authorized' using errcode = '42501';
  end if;
end $$;

create or replace function public._docs(p_store text, p_collection text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(id, data), '{}'::jsonb)
  from public.documents where store = p_store and collection = p_collection;
$$;

-- same as _docs, but optionally leaves out documents flagged "v2only" (the new floor-plan layout is
-- rolled out in two steps so the old page keeps working until the new page is deployed)
create or replace function public._docs_vis(p_store text, p_collection text, p_all boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_object_agg(id, data), '{}'::jsonb)
  from public.documents where store = p_store and collection = p_collection
    and (p_all or coalesce(data->>'v2only', '') <> 'true');
$$;

create or replace function public._doc(p_store text, p_collection text, p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select data from public.documents
  where store = p_store and collection = p_collection and id = p_id;
$$;

create or replace function public._reset_draft() returns void
language sql volatile security definer set search_path = public as $$
  delete from public.documents where store = 'draft';
  insert into public.documents (store, collection, id, data, updated_at)
    select 'draft', collection, id, data, now()
    from public.documents where store = 'live' and collection <> 'bookings';
$$;

-- an uploaded file reference: only https URLs + filename survive.
-- dataUrl = the Supabase Storage copy (primary); driveUrl = the Google Drive
-- copy the team uses (optional, kept only when it is a clean https URL).
create or replace function public._clean_file(f jsonb) returns jsonb
language sql immutable as $$
  select case
    when jsonb_typeof(f) = 'object' and (f->>'dataUrl') ~ '^https://[^\s"''<>]+$'
    then jsonb_strip_nulls(jsonb_build_object(
           'dataUrl',  left(f->>'dataUrl', 500),
           'filename', left(coalesce(f->>'filename', ''), 120),
           'driveUrl', case when (f->>'driveUrl') ~ '^https://[^\s"''<>]+$' then left(f->>'driveUrl', 500) end))
  end;
$$;

-- a booking has a usable payment slip only if its slip file lives in this project's slip folder in storage
-- (so a made-up link cannot satisfy the "slip required" rule)
create or replace function public._has_slip_file(v jsonb) returns boolean
language sql immutable as $$
  select coalesce((v->'slipData'->>'dataUrl') ~ '^https://[^/]+/storage/v1/object/public/uploads/slip/[^\s"''<>]+$', false);
$$;

create or replace function public._num(v text) returns numeric
language sql immutable as $$
  select case when v ~ '^\s*\d+(\.\d+)?\s*$' then v::numeric end;
$$;

-- Builds the stored booking from what a customer sent. Only known fields are
-- kept, text is length-capped, status always starts as "pending", and the
-- PRICE IS COMPUTED HERE from the table/zone (+ power fee), so it can't be
-- changed by editing the request.
create or replace function public._clean_booking(p_table_id text, p_data jsonb, p_group uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  t jsonb; z jsonb; base numeric; has_power boolean; now_txt text; slip jsonb; logo jsonb; custom jsonb;
begin
  t := public._doc('live', 'tables', p_table_id);
  if t is null then raise exception 'unknown table: %', p_table_id; end if;
  z := public._doc('live', 'zones', t->>'zoneKey');
  base := coalesce(public._num(t->>'price'), public._num(z->>'price'), 0);
  has_power := coalesce(p_data->'hasPower' = 'true'::jsonb, false);
  if coalesce(btrim(p_data->>'shop'), '') = '' or coalesce(btrim(p_data->>'contact'), '') = ''
     or coalesce(btrim(p_data->>'phone'), '') = '' or coalesce(btrim(p_data->>'email'), '') = '' then
    raise exception 'missing required fields';
  end if;
  if length(regexp_replace(p_data->>'shop', '[\s.\-_''"()]', '', 'g')) < 2
     or length(regexp_replace(p_data->>'contact', '[\s.\-_''"()]', '', 'g')) < 2
     or regexp_replace(p_data->>'contact', '\s', '', 'g') ~ '^\d+$'
     or length(regexp_replace(p_data->>'phone', '\D', '', 'g')) not between 8 and 15
     or (p_data->>'phone') ~ '[^0-9\s+()\-.]'
     or btrim(p_data->>'email') !~ '^[^\s@]+@[^\s@]+\.[A-Za-z]{2,}$' then
    raise exception 'invalid contact details';
  end if;
  slip := public._clean_file(p_data->'slipData');
  logo := public._clean_file(p_data->'logoData');
  custom := case when jsonb_typeof(p_data->'custom') = 'object' and length((p_data->'custom')::text) <= 4000
                 then p_data->'custom' end;
  now_txt := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  return jsonb_strip_nulls(jsonb_build_object(
    'tableId',   p_table_id,
    'shop',      left(btrim(p_data->>'shop'), 80),
    'contact',   left(btrim(p_data->>'contact'), 60),
    'phone',     left(btrim(p_data->>'phone'), 20),
    'email',     left(btrim(p_data->>'email'), 120),
    'line',      left(btrim(coalesce(p_data->>'line', '')), 40),
    'category',  left(coalesce(p_data->>'category', ''), 40),
    'note',      left(coalesce(p_data->>'note', ''), 300),
    'hasPower',  has_power,
    'powerFee',  case when has_power then 500 else 0 end,
    'price',     base + case when has_power then 500 else 0 end,
    'status',    'pending',
    'createdAt', now_txt,
    'updatedAt', now_txt,
    'custom',    custom,
    'hasSlip',   slip is not null,
    'hasLogo',   logo is not null,
    'slipData',  slip,
    'logoData',  logo,
    'groupId',   p_group
  ));
end $$;

-- ---------------------------------------------------------------------
-- PUBLIC API (anyone)
-- ---------------------------------------------------------------------
create or replace function public.get_public_state() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'zones',  public._docs_vis('live', 'zones', false),
    'tables', public._docs_vis('live', 'tables', false),
    'zonesAll',  public._docs_vis('live', 'zones', true),
    'tablesAll', public._docs_vis('live', 'tables', true),
    'bookings', coalesce((
      select jsonb_object_agg(id, jsonb_strip_nulls(jsonb_build_object(
        'tableId',  id,
        'status',   coalesce(data->>'status', 'pending'),
        'groupId',  data->'groupId',
        'logoData', case when data->>'status' in ('paid', 'confirmed') then data->'logoData' end
      )))
      from public.documents where store = 'live' and collection = 'bookings'
    ), '{}'::jsonb),
    'config', jsonb_build_object(
      'settings',     public._doc('live', 'config', 'settings'),
      'customFields', public._doc('live', 'config', 'customFields')
    )
  );
$$;

create or replace function public.create_booking(p_table_id text, p_data jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v jsonb; s jsonb;
begin
  if not public.is_admin() and public._doc('live', 'tables', p_table_id)->>'locked' = 'true' then
    raise exception 'table locked';
  end if;
  v := public._stamp_dups(public._clean_booking(p_table_id, p_data, null), p_data, null);
  -- a customer booking without a payment slip is not accepted (admins may book on behalf of someone)
  if not public.is_admin() and not public._has_slip_file(v) then
    raise exception 'slip required';
  end if;
  insert into public.documents (store, collection, id, data)
  values ('live', 'bookings', p_table_id, v)
  on conflict (store, collection, id) do nothing;   -- the primary key makes double-booking impossible
  if not found then raise exception 'table already booked'; end if;
  s := public._record_slip(array[p_table_id], null, p_data->'slip', v->'slipData', public._num(v->>'price'));
  return jsonb_build_object('ok', true, 'booking', v, 'slip', s);
end $$;

create or replace function public.create_booking_multi(p_items jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  g uuid := gen_random_uuid(); item jsonb; tid text; v jsonb;
  booked text[] := '{}'; skipped text[] := '{}'; out_b jsonb := '{}'::jsonb;
  first_item jsonb; first_v jsonb; total numeric := 0; s jsonb;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'missing bookings';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'too many tables in one booking'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    tid := item->>'tableId';
    if tid is null or public._doc('live', 'tables', tid) is null
       or (not public.is_admin() and public._doc('live', 'tables', tid)->>'locked' = 'true') then
      skipped := skipped || coalesce(tid, '?');
      continue;
    end if;
    v := public._stamp_dups(public._clean_booking(tid, item->'data', g), item->'data', g);
    if not public.is_admin() and not public._has_slip_file(v) then
      raise exception 'slip required';   -- aborts the whole call: nothing is booked
    end if;
    insert into public.documents (store, collection, id, data)
    values ('live', 'bookings', tid, v)
    on conflict (store, collection, id) do nothing;
    if found then
      booked := booked || tid; out_b := out_b || jsonb_build_object(tid, v);
      total := total + coalesce(public._num(v->>'price'), 0);
      if first_item is null then first_item := item->'data'; first_v := v; end if;
    else skipped := skipped || tid; end if;
  end loop;
  if first_item is not null then   -- the slip is shared by the whole group: store it once
    s := public._record_slip(booked, g, first_item->'slip', first_v->'slipData', total);
  end if;
  return jsonb_build_object('ok', true, 'groupId', g, 'booked', to_jsonb(booked),
                            'skipped', to_jsonb(skipped), 'bookings', out_b, 'slip', s);
end $$;

-- ---------------------------------------------------------------------
-- ADMIN API (signed-in user listed in `admins`)
-- ---------------------------------------------------------------------
create or replace function public.get_admin_state() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  -- first admin visit ever: start the draft as a copy of live
  if not exists (select 1 from public.documents where store = 'draft' and collection <> '_deleted') then
    perform public._reset_draft();
  end if;
  return jsonb_build_object(
    'zones',    public._docs('draft', 'zones'),
    'tables',   public._docs('draft', 'tables'),
    'bookings', public._docs('live', 'bookings'),          -- always the real, current bookings
    'slips',    public._slips_json(),
    'changeRequests', public._change_requests_json(),
    'config', jsonb_build_object(
      'settings',     public._doc('draft', 'config', 'settings'),
      'customFields', public._doc('draft', 'config', 'customFields')
    )
  );
end $$;

-- p_path is "collection/id". Bookings always go to live; everything else to
-- the store asked for (the front end uses draft for layout edits).
create or replace function public.admin_set_doc(p_store text, p_path text, p_data jsonb, p_merge boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_col text := split_part(p_path, '/', 1);
  v_id  text := substr(p_path, length(split_part(p_path, '/', 1)) + 2);
  v_store text;
begin
  perform public._require_admin();
  if v_col = '' or v_id = '' or left(v_col, 1) = '_' then raise exception 'bad path: %', p_path; end if;
  v_store := case when v_col = 'bookings' then 'live' when p_store = 'live' then 'live' else 'draft' end;
  if p_merge then
    update public.documents set data = data || coalesce(p_data, '{}'::jsonb), updated_at = now()
    where store = v_store and collection = v_col and id = v_id;
    if not found then raise exception 'document not found: %', p_path; end if;
  else
    insert into public.documents (store, collection, id, data)
    values (v_store, v_col, v_id, coalesce(p_data, '{}'::jsonb))
    on conflict (store, collection, id) do update set data = excluded.data, updated_at = now();
  end if;
  if v_store = 'draft' then   -- writing a doc cancels an earlier delete of it
    delete from public.documents where store = 'draft' and collection = '_deleted' and id = v_col || '__' || v_id;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_delete_doc(p_store text, p_path text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_col text := split_part(p_path, '/', 1);
  v_id  text := substr(p_path, length(split_part(p_path, '/', 1)) + 2);
  v_store text;
begin
  perform public._require_admin();
  if v_col = '' or v_id = '' or left(v_col, 1) = '_' then raise exception 'bad path: %', p_path; end if;
  v_store := case when v_col = 'bookings' then 'live' when p_store = 'live' then 'live' else 'draft' end;
  delete from public.documents where store = v_store and collection = v_col and id = v_id;
  if v_store = 'draft' then   -- remember the delete so publish removes it from live too
    insert into public.documents (store, collection, id, data)
    values ('draft', '_deleted', v_col || '__' || v_id, jsonb_build_object('collection', v_col, 'id', v_id))
    on conflict (store, collection, id) do update set data = excluded.data, updated_at = now();
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.publish_draft() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  insert into public.documents (store, collection, id, data, updated_at)
    select 'live', collection, id, data, now()
    from public.documents where store = 'draft' and collection in ('zones', 'tables', 'config')
  on conflict (store, collection, id) do update set data = excluded.data, updated_at = now();
  delete from public.documents l
    using public.documents t
    where t.store = 'draft' and t.collection = '_deleted'
      and l.store = 'live' and l.collection = t.data->>'collection' and l.id = t.data->>'id'
      and l.collection <> 'bookings';
  perform public._reset_draft();
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.reset_draft_from_live() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  perform public._reset_draft();
  return jsonb_build_object('ok', true);
end $$;


-- =====================================================================
-- SLIP TRACKING (no bank API)
-- One row per payment slip that reaches the system. What can be trusted:
--   uploaded_at  : set by the SERVER when the slip arrived (customers can't change it)
--   bank_code + trans_ref : read from the slip's QR code by the page; the same bank
--                  transaction can only be the "original" once, later uses are flagged
-- What cannot be proven without a bank/verification API: that the slip is genuine.
-- transferred_at / amount are entered by an admin after reading the slip image.
-- =====================================================================
create table if not exists public.slips (
  id              uuid primary key default gen_random_uuid(),
  table_ids       text[] not null,                      -- tables this slip pays for (several = one grouped booking)
  group_id        uuid,
  bank_code       text,                                 -- 3-digit sending bank code from the slip QR (014 = SCB, ...)
  trans_ref       text,                                 -- bank transaction reference from the slip QR
  qr_found        boolean not null default false,
  file_url        text,                                 -- Supabase Storage copy (https)
  drive_url       text,                                 -- Google Drive copy (https)
  file_name       text,
  expected_amount numeric,                              -- what the booking costs (computed by the database)
  uploaded_at     timestamptz not null default now(),   -- when the slip reached the server
  transferred_at  timestamptz,                          -- transfer time read from the slip by an admin
  amount          numeric,                              -- amount an admin confirmed on the slip
  status          text not null default 'pending' check (status in ('pending','verified','mismatch','rejected')),
  duplicate_of    uuid references public.slips(id),     -- set when the same bank transaction was already used
  note            text,
  reviewed_by     uuid,
  reviewed_at     timestamptz
);
-- one "original" per bank transaction; later uses are stored but marked duplicate_of
create unique index if not exists slips_ref_original on public.slips (bank_code, trans_ref)
  where trans_ref is not null and duplicate_of is null;
create index if not exists slips_uploaded_at on public.slips (uploaded_at);
alter table public.slips enable row level security;
revoke all on public.slips from anon, authenticated;

create or replace function public._record_slip(p_table_ids text[], p_group uuid, p_slip jsonb, p_file jsonb, p_expected numeric)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_bank text := nullif(btrim(p_slip->>'bankCode'), '');
  v_ref  text := nullif(btrim(p_slip->>'transRef'), '');
  v_file jsonb := public._clean_file(p_file);
  v_id uuid; v_dup uuid;
begin
  if v_bank is null or v_bank !~ '^[0-9]{3}$' or v_ref is null or v_ref !~ '^[A-Za-z0-9]{10,40}$' then
    v_bank := null; v_ref := null;                      -- not a plausible slip QR: keep the file, drop the reference
  end if;
  if v_file is null and v_ref is null then return null; end if;   -- no slip was submitted
  for i in 1..2 loop
    v_dup := null;
    if v_ref is not null then
      select id into v_dup from public.slips where bank_code = v_bank and trans_ref = v_ref and duplicate_of is null limit 1;
    end if;
    begin
      insert into public.slips (table_ids, group_id, bank_code, trans_ref, qr_found, file_url, drive_url, file_name, expected_amount, duplicate_of)
      values (p_table_ids, p_group, v_bank, v_ref, v_ref is not null, v_file->>'dataUrl', v_file->>'driveUrl', v_file->>'filename', p_expected, v_dup)
      returning id into v_id;
      exit;
    exception when unique_violation then
      v_id := null;      -- the same reference was inserted at this very moment: retry, it will be stored as a duplicate
    end;
  end loop;
  if v_id is null then raise exception 'could not record slip'; end if;
  return jsonb_build_object('id', v_id, 'duplicate', v_dup is not null);
end $$;

-- all slips for the admin screen, in transfer order: confirmed transfer time first,
-- then slips whose transfer time is not entered yet (by arrival time)
create or replace function public._slips_json() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id, 'tableIds', to_jsonb(s.table_ids), 'groupId', s.group_id,
    'bankCode', s.bank_code, 'transRef', s.trans_ref, 'qrFound', s.qr_found,
    'fileUrl', s.file_url, 'driveUrl', s.drive_url, 'fileName', s.file_name,
    'expectedAmount', s.expected_amount, 'uploadedAt', s.uploaded_at, 'transferredAt', s.transferred_at,
    'amount', s.amount, 'status', s.status, 'duplicateOf', s.duplicate_of, 'note', s.note, 'reviewedAt', s.reviewed_at,
    'duplicateOfTables', (select to_jsonb(o.table_ids) from public.slips o where o.id = s.duplicate_of),
    'shop', (select b.data->>'shop' from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = s.table_ids[1]),
    'bookingStatus', (select b.data->>'status' from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = s.table_ids[1]),
    'bookingExists', exists (select 1 from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = s.table_ids[1])
  ) order by (s.transferred_at is null), s.transferred_at, s.uploaded_at), '[]'::jsonb)
  from public.slips s;
$$;

-- the admin read the slip: record the confirmed amount/time and the verdict
create or replace function public.admin_review_slip(p_id uuid, p_status text, p_amount numeric default null,
                                                    p_transferred_at timestamptz default null, p_note text default null,
                                                    p_mark_paid boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v public.slips;
begin
  perform public._require_admin();
  if p_status not in ('pending','verified','mismatch','rejected') then raise exception 'bad status: %', p_status; end if;
  if p_amount is not null and p_amount < 0 then raise exception 'bad amount'; end if;
  if p_transferred_at is not null and p_transferred_at > now() + interval '1 day' then raise exception 'transfer time is in the future'; end if;
  update public.slips
     set status = p_status, amount = p_amount, transferred_at = p_transferred_at, note = left(p_note, 500),
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id returning * into v;
  if not found then raise exception 'slip not found'; end if;
  if p_mark_paid and p_status = 'verified' then
    update public.documents
       set data = data || jsonb_build_object('status', 'paid', 'updatedAt', to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"')),
           updated_at = now()
     where store = 'live' and collection = 'bookings' and id = any (v.table_ids) and coalesce(data->>'status', 'pending') = 'pending';
  end if;
  return jsonb_build_object('ok', true, 'id', v.id, 'status', v.status);
end $$;

-- the admin adds / replaces a slip for an existing booking
create or replace function public.admin_attach_slip(p_table_id text, p_slip jsonb, p_file jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b jsonb; r jsonb;
begin
  perform public._require_admin();
  b := public._doc('live', 'bookings', p_table_id);
  if b is null then raise exception 'booking not found: %', p_table_id; end if;
  r := public._record_slip(array[p_table_id], nullif(b->>'groupId', '')::uuid, p_slip, p_file, public._num(b->>'price'));
  return jsonb_build_object('ok', true, 'slip', r);
end $$;

-- keep slips pointing at the right table when an admin moves a booking
create or replace function public.admin_retarget_slips(p_old text, p_new text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  update public.slips set table_ids = array_replace(table_ids, p_old, p_new) where p_old = any (table_ids);
  return jsonb_build_object('ok', true);
end $$;


-- ---------------------------------------------------------------------
-- DUPLICATE BOOKINGS + BOOKING CHANGES
-- ---------------------------------------------------------------------
create or replace function public._norm_text(s text) returns text
language sql immutable as $$
  select regexp_replace(lower(btrim(coalesce(s, ''))), '\s+', '', 'g');
$$;
create or replace function public._norm_phone(s text) returns text
language sql immutable as $$
  select regexp_replace(coalesce(s, ''), '\D', '', 'g');
$$;

-- Which existing bookings share the shop, phone, email or (3+ letter) contact
-- name with this one? Returns table ids + which fields matched. Internal only:
-- the browser gets just a yes/no from check_duplicate().
create or replace function public._find_dups(p_shop text, p_contact text, p_phone text, p_email text, p_exclude_group uuid default null)
returns table (table_id text, fields text[])
language sql stable security definer set search_path = public as $$
  select m.id, m.f from (
    select b.id,
           array_remove(array[
             case when public._norm_text(p_shop) <> '' and public._norm_text(b.data->>'shop') = public._norm_text(p_shop) then 'shop' end,
             case when length(public._norm_phone(p_phone)) >= 8 and public._norm_phone(b.data->>'phone') = public._norm_phone(p_phone) then 'phone' end,
             case when public._norm_text(p_email) <> '' and public._norm_text(b.data->>'email') = public._norm_text(p_email) then 'email' end,
             case when length(public._norm_text(p_contact)) >= 3 and public._norm_text(b.data->>'contact') = public._norm_text(p_contact) then 'contact' end
           ], null) as f
    from public.documents b
    where b.store = 'live' and b.collection = 'bookings'
      and (p_exclude_group is null or b.data->>'groupId' is distinct from p_exclude_group::text)
  ) m
  where cardinality(m.f) > 0
  order by m.id;
$$;

-- yes/no for the booking form: has this shop/contact/phone/email booked before?
create or replace function public.check_duplicate(p_shop text, p_contact text, p_phone text, p_email text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'duplicate', exists (select 1 from public._find_dups(p_shop, p_contact, p_phone, p_email)),
    'fields',    coalesce((select jsonb_agg(distinct f) from public._find_dups(p_shop, p_contact, p_phone, p_email) d, unnest(d.fields) f), '[]'::jsonb)
  );
$$;

-- remember (for the admin) which earlier bookings a new booking overlaps with
create or replace function public._stamp_dups(v jsonb, p_data jsonb, p_group uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ids text[]; flds text[];
begin
  select coalesce(array_agg(d.table_id order by d.table_id), '{}'), coalesce(array(select distinct f from public._find_dups(v->>'shop', v->>'contact', v->>'phone', v->>'email', p_group) d2, unnest(d2.fields) f), '{}')
    into ids, flds
    from public._find_dups(v->>'shop', v->>'contact', v->>'phone', v->>'email', p_group) d;
  if cardinality(ids) = 0 then return v; end if;
  return v || jsonb_build_object('dupOf', to_jsonb(ids), 'dupFields', to_jsonb(flds),
                                 'dupConfirmed', coalesce(p_data->>'dupConfirmed' = 'true', false));
end $$;

create table if not exists public.change_requests (
  id          uuid primary key default gen_random_uuid(),
  old_table   text not null,
  new_table   text not null,
  shop        text, contact text, phone text, email text,
  bank_code   text, trans_ref text, file_url text,
  data_ok     boolean not null default false,
  slip_ok     boolean not null default false,
  price_ok    boolean not null default false,
  status      text not null default 'pending' check (status in ('pending','approved','rejected','auto_moved')),
  reason      text,
  note        text,
  created_at  timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_at timestamptz
);
alter table public.change_requests enable row level security;
revoke all on public.change_requests from anon, authenticated;

-- price a table would have for this booking (zone/table price + power fee)
create or replace function public._price_for(p_table_id text, p_has_power boolean) returns numeric
language plpgsql stable security definer set search_path = public as $$
declare t jsonb; z jsonb;
begin
  t := public._doc('live', 'tables', p_table_id);
  if t is null then return null; end if;
  z := public._doc('live', 'zones', t->>'zoneKey');
  return coalesce(public._num(t->>'price'), public._num(z->>'price'), 0) + case when p_has_power then 500 else 0 end;
end $$;

-- move one booking to another free table (keeps everything else, fixes the price and the slips)
create or replace function public._move_booking(p_old text, p_new text) returns void
language plpgsql volatile security definer set search_path = public as $$
declare b jsonb; nb jsonb; now_txt text; price numeric;
begin
  b := public._doc('live', 'bookings', p_old);
  if b is null then raise exception 'booking not found'; end if;
  if p_old = p_new then raise exception 'same table'; end if;
  price := public._price_for(p_new, coalesce(b->'hasPower' = 'true'::jsonb, false));
  if price is null then raise exception 'new table not available'; end if;
  now_txt := to_char(now() at time zone 'utc', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"');
  nb := b || jsonb_build_object('tableId', p_new, 'price', price, 'updatedAt', now_txt, 'movedFrom', p_old, 'movedAt', now_txt);
  insert into public.documents (store, collection, id, data)
  values ('live', 'bookings', p_new, nb)
  on conflict (store, collection, id) do nothing;
  if not found then raise exception 'new table not available'; end if;
  delete from public.documents where store = 'live' and collection = 'bookings' and id = p_old;
  update public.slips set table_ids = array_replace(table_ids, p_old, p_new) where p_old = any (table_ids);
end $$;

-- A customer asks to move their booking. It is moved automatically ONLY when
--   * the shop/contact/phone/email match the booking,
--   * the slip QR reference matches a slip stored for that booking, and
--   * the new table costs the same.
-- Anything else becomes a request for an admin to approve.
create or replace function public.request_booking_change(p_old text, p_new text, p_data jsonb, p_slip jsonb, p_file jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  b jsonb; d_ok boolean; s_ok boolean := false; p_ok boolean; reason text[] := '{}';
  v_bank text := nullif(btrim(p_slip->>'bankCode'), ''); v_ref text := nullif(btrim(p_slip->>'transRef'), '');
  v_file jsonb := public._clean_file(p_file); v_id uuid; new_price numeric; pend int;
begin
  b := public._doc('live', 'bookings', p_old);
  if b is null then raise exception 'booking not found'; end if;
  if public._doc('live', 'tables', p_new) is null or public._doc('live', 'bookings', p_new) is not null
     or public._doc('live', 'tables', p_new)->>'locked' = 'true' then
    raise exception 'new table not available';
  end if;
  select count(*) into pend from public.change_requests where old_table = p_old and status = 'pending';
  if pend >= 5 then raise exception 'too many pending requests'; end if;
  d_ok := public._norm_text(p_data->>'shop') = public._norm_text(b->>'shop')
      and public._norm_text(p_data->>'contact') = public._norm_text(b->>'contact')
      and public._norm_text(p_data->>'email') = public._norm_text(b->>'email')
      and length(public._norm_phone(p_data->>'phone')) >= 8
      and public._norm_phone(p_data->>'phone') = public._norm_phone(b->>'phone');
  if v_bank is not null and v_bank ~ '^[0-9]{3}$' and v_ref is not null and v_ref ~ '^[A-Za-z0-9]{10,40}$' then
    s_ok := exists (select 1 from public.slips where p_old = any (table_ids) and bank_code = v_bank and trans_ref = v_ref);
  else v_bank := null; v_ref := null; end if;
  new_price := public._price_for(p_new, coalesce(b->'hasPower' = 'true'::jsonb, false));
  p_ok := new_price is not distinct from public._num(b->>'price');
  if not d_ok then reason := reason || 'data does not match the booking'::text; end if;
  if not s_ok then reason := reason || 'slip not matched'::text; end if;
  if not p_ok then reason := reason || 'price differs'::text; end if;
  insert into public.change_requests (old_table, new_table, shop, contact, phone, email, bank_code, trans_ref, file_url,
                                      data_ok, slip_ok, price_ok, status, reason)
  values (p_old, p_new, left(p_data->>'shop', 80), left(p_data->>'contact', 60), left(p_data->>'phone', 20), left(p_data->>'email', 120),
          v_bank, v_ref, v_file->>'dataUrl', d_ok, s_ok, p_ok,
          case when d_ok and s_ok and p_ok then 'auto_moved' else 'pending' end, array_to_string(reason, '; '))
  returning id into v_id;
  if d_ok and s_ok and p_ok then
    perform public._move_booking(p_old, p_new);
    return jsonb_build_object('ok', true, 'moved', true, 'requestId', v_id, 'newTable', p_new);
  end if;
  return jsonb_build_object('ok', true, 'moved', false, 'requestId', v_id);
end $$;

create or replace function public._change_requests_json() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'oldTable', c.old_table, 'newTable', c.new_table, 'shop', c.shop, 'contact', c.contact,
    'phone', c.phone, 'email', c.email, 'bankCode', c.bank_code, 'transRef', c.trans_ref, 'fileUrl', c.file_url,
    'dataOk', c.data_ok, 'slipOk', c.slip_ok, 'priceOk', c.price_ok, 'status', c.status, 'reason', c.reason,
    'note', c.note, 'createdAt', c.created_at, 'reviewedAt', c.reviewed_at,
    'bookingShop', (select b.data->>'shop' from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = c.old_table),
    'oldExists', exists (select 1 from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = c.old_table),
    'newFree', not exists (select 1 from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = c.new_table)
  ) order by (c.status <> 'pending'), c.created_at desc), '[]'::jsonb)
  from public.change_requests c;
$$;

create or replace function public.admin_decide_change(p_id uuid, p_approve boolean, p_note text default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c public.change_requests;
begin
  perform public._require_admin();
  select * into c from public.change_requests where id = p_id for update;
  if not found then raise exception 'request not found'; end if;
  if c.status <> 'pending' then raise exception 'request already decided'; end if;
  if p_approve then perform public._move_booking(c.old_table, c.new_table); end if;
  update public.change_requests
     set status = case when p_approve then 'approved' else 'rejected' end, note = left(p_note, 500),
         reviewed_by = auth.uid(), reviewed_at = now()
   where id = p_id;
  return jsonb_build_object('ok', true, 'status', case when p_approve then 'approved' else 'rejected' end);
end $$;

-- one transfer slip paid for several bookings: link it to more tables (the expected amount becomes their total)
create or replace function public.admin_link_slip(p_slip_id uuid, p_table_ids text[]) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare s public.slips; ids text[]; total numeric;
begin
  perform public._require_admin();
  select * into s from public.slips where id = p_slip_id for update;
  if not found then raise exception 'slip not found'; end if;
  select array(select distinct x from unnest(s.table_ids || p_table_ids) x order by x) into ids;
  select coalesce(sum(public._num(d.data->>'price')), 0) into total
    from public.documents d where d.store = 'live' and d.collection = 'bookings' and d.id = any (ids);
  update public.slips set table_ids = ids, expected_amount = total where id = p_slip_id;
  return jsonb_build_object('ok', true, 'tableIds', to_jsonb(ids), 'expectedAmount', total);
end $$;

-- ---------------------------------------------------------------------
-- who may call what
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.get_public_state()                     to anon, authenticated;
grant execute on function public.create_booking(text, jsonb)            to anon, authenticated;
grant execute on function public.create_booking_multi(jsonb)            to anon, authenticated;
grant execute on function public.is_admin()                             to authenticated;
grant execute on function public.get_admin_state()                      to authenticated;
grant execute on function public.admin_set_doc(text, text, jsonb, boolean) to authenticated;
grant execute on function public.admin_delete_doc(text, text)           to authenticated;
grant execute on function public.publish_draft()                        to authenticated;
grant execute on function public.reset_draft_from_live()                to authenticated;
grant execute on function public.admin_review_slip(uuid, text, numeric, timestamptz, text, boolean) to authenticated;
grant execute on function public.admin_attach_slip(text, jsonb, jsonb)  to authenticated;
grant execute on function public.admin_retarget_slips(text, text)       to authenticated;
grant execute on function public.check_duplicate(text, text, text, text)  to anon, authenticated;
grant execute on function public.request_booking_change(text, text, jsonb, jsonb, jsonb) to anon, authenticated;
grant execute on function public.admin_decide_change(uuid, boolean, text) to authenticated;
grant execute on function public.admin_link_slip(uuid, text[])           to authenticated;

-- ---------------------------------------------------------------------
-- file uploads (slip / logo / payment QR) — Supabase Storage
-- Public bucket: files are readable by their (random, unguessable) URL,
-- like the old "anyone with the link" Drive files. Nobody can list or
-- overwrite them; anyone can add an image up to 10 MB.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('uploads', 'uploads', true, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "uploads: anyone can add images" on storage.objects;
create policy "uploads: anyone can add images" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] in ('slip', 'logo', 'other'));

-- ===EMAIL-QUEUE===
-- =====================================================================
-- MAYUCARD 6 — customer confirmation e-mails (queue for the Apps Script sender)
-- Idempotent. The database never sends mail itself: a small Google Apps Script in the sender's Google
-- account asks "who is due an e-mail?", sends it from that account, then reports back (see tools/email-sender).
-- Safety: mode 'off' (default) | 'dry' (list only, nothing is sent) | 'live'. Every call needs a secret token.
-- Rule (option A): every table of the shop is confirmed/paid AND the read slip amounts cover the price.
-- =====================================================================
create table if not exists public.email_settings (
  id          int primary key default 1 check (id = 1),
  mode        text not null default 'off' check (mode in ('off', 'dry', 'live')),
  token_hash  text,
  updated_at  timestamptz not null default now()
);
alter table public.email_settings add column if not exists delay_minutes int not null default 10;   -- grace period before an e-mail goes out
insert into public.email_settings (id) values (1) on conflict (id) do nothing;
alter table public.email_settings enable row level security;
revoke all on public.email_settings from anon, authenticated;

-- when a shop first became "due" (starts the grace period; reset if it stops being due) and shops the admin put on hold
create table if not exists public.email_pending (
  shop_key     text primary key,
  first_due_at timestamptz not null default now()
);
alter table public.email_pending enable row level security;
revoke all on public.email_pending from anon, authenticated;
create table if not exists public.email_hold (
  shop_key text primary key,
  held_at  timestamptz not null default now()
);
alter table public.email_hold enable row level security;
revoke all on public.email_hold from anon, authenticated;

create table if not exists public.email_outbox (
  shop_key    text primary key,
  shop        text,
  to_email    text,
  tables      text[],
  total       numeric,
  paid        numeric,
  status      text not null check (status in ('sent', 'failed')),
  attempts    int not null default 0,
  error       text,
  sent_at     timestamptz,
  updated_at  timestamptz not null default now()
);
alter table public.email_outbox enable row level security;
revoke all on public.email_outbox from anon, authenticated;

create or replace function public._shop_key(s text) returns text
language sql immutable as $$ select lower(regexp_replace(coalesce(s, ''), '[^a-zA-Z0-9ก-๙]', '', 'g')); $$;

create or replace function public._email_token_ok(p_token text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.email_settings
                 where id = 1 and token_hash is not null and p_token is not null and length(p_token) >= 24
                   and token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex'));
$$;

-- which shops are due an e-mail right now (not yet sent, rule met, e-mail address plausible)
create or replace function public._email_due() returns table (
  shop_key text, shop text, contact text, email text, tables text[], lines jsonb, total numeric, paid numeric, has_logo boolean, valid_email boolean)
language sql stable security definer set search_path = public as $$
  with b as (
    select id, data->>'shop' as shop, public._shop_key(data->>'shop') as k, lower(btrim(coalesce(data->>'email', ''))) as email,
           data->>'contact' as contact, coalesce(public._num(data->>'price'), 0) as price,
           coalesce(data->>'status', 'pending') as st,
           ((data->'logoData') is not null or coalesce((data->>'hasLogo')::boolean, false)) as logo
    from public.documents where store = 'live' and collection = 'bookings'),
  share as (   -- each slip's amount is split over the booked tables it pays for, in proportion to their prices
    select b.k, s.amount * b.price / nullif(sum(b.price) over (partition by s.id), 0) as amt
    from public.slips s cross join lateral unnest(s.table_ids) as t(tid) join b on b.id = t.tid
    where s.status <> 'rejected' and s.amount is not null),
  g as (
    select k as shop_key, min(shop) as shop, (array_agg(contact order by id))[1] as contact, (array_agg(email order by id))[1] as email,
           array_agg(id order by id) as tables,
           jsonb_agg(jsonb_build_object('table', id, 'price', price) order by id) as lines,
           sum(price) as total, bool_and(st in ('confirmed', 'paid')) as all_ok, bool_and(logo) as has_logo
    from b where k <> '' group by k)
  select g.shop_key, g.shop, g.contact, g.email, g.tables, g.lines, g.total,
         coalesce((select sum(amt) from share where share.k = g.shop_key), 0)::numeric as paid, g.has_logo,
         g.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$' as valid_email
  from g
  where g.all_ok and g.total > 0
    and coalesce((select sum(amt) from share where share.k = g.shop_key), 0) >= g.total - 0.5
    and not exists (select 1 from public.email_outbox o where o.shop_key = g.shop_key and (o.status = 'sent' or o.attempts >= 3));
$$;

-- called by the sender script (token-protected). Also keeps the grace-period clock.
create or replace function public.email_queue_fetch(p_token text, p_limit int default 10) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m text; dl int; items jsonb; bad jsonb; waiting jsonb;
begin
  if not public._email_token_ok(p_token) then raise exception 'not authorized' using errcode = '42501'; end if;
  select mode, delay_minutes into m, dl from public.email_settings where id = 1;
  if m = 'off' then return jsonb_build_object('mode', 'off', 'items', '[]'::jsonb, 'invalid', '[]'::jsonb, 'waiting', '[]'::jsonb); end if;
  insert into public.email_pending (shop_key) select shop_key from public._email_due() on conflict do nothing;
  delete from public.email_pending where shop_key not in (select shop_key from public._email_due());   -- stopped being due: the clock restarts
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into items from (
    select d.shop_key as "shopKey", d.shop, d.contact, d.email, d.tables, d.lines, d.total, d.paid, d.has_logo as "hasLogo"
    from public._email_due() d join public.email_pending p on p.shop_key = d.shop_key
    where d.valid_email and not exists (select 1 from public.email_hold h where h.shop_key = d.shop_key)
      and p.first_due_at <= now() - make_interval(mins => dl)
    order by p.first_due_at limit greatest(1, least(coalesce(p_limit, 10), 50))) x;
  select coalesce(jsonb_agg(jsonb_build_object('shopKey', d.shop_key, 'shop', d.shop, 'sendAt', p.first_due_at + make_interval(mins => dl))), '[]'::jsonb) into waiting
    from public._email_due() d join public.email_pending p on p.shop_key = d.shop_key
    where d.valid_email and not exists (select 1 from public.email_hold h where h.shop_key = d.shop_key)
      and p.first_due_at > now() - make_interval(mins => dl);
  select coalesce(jsonb_agg(jsonb_build_object('shopKey', shop_key, 'shop', shop, 'email', email)), '[]'::jsonb) into bad
    from public._email_due() where not valid_email;
  return jsonb_build_object('mode', m, 'items', items, 'invalid', bad, 'waiting', waiting);
end $$;

create or replace function public.email_queue_mark(p_token text, p_results jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r jsonb; d record; n int := 0;
begin
  if not public._email_token_ok(p_token) then raise exception 'not authorized' using errcode = '42501'; end if;
  if (select mode from public.email_settings where id = 1) <> 'live' then raise exception 'mode is not live'; end if;
  for r in select value from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) loop
    select * into d from public._email_due() where shop_key = r->>'shopKey';
    continue when not found;     -- only shops that are really due can be marked
    insert into public.email_outbox (shop_key, shop, to_email, tables, total, paid, status, attempts, error, sent_at)
    values (d.shop_key, d.shop, d.email, d.tables, d.total, d.paid,
            case when r->>'status' = 'sent' then 'sent' else 'failed' end, 1, left(r->>'error', 300),
            case when r->>'status' = 'sent' then now() end)
    on conflict (shop_key) do update
      set status = excluded.status, attempts = public.email_outbox.attempts + 1, error = excluded.error,
          sent_at = excluded.sent_at, to_email = excluded.to_email, tables = excluded.tables,
          total = excluded.total, paid = excluded.paid, updated_at = now();
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'recorded', n);
end $$;

-- admin controls
create or replace function public.admin_email_set_mode(p_mode text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_mode not in ('off', 'dry', 'live') then raise exception 'bad mode'; end if;
  update public.email_settings set mode = p_mode, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'mode', p_mode);
end $$;

create or replace function public.admin_email_set_token(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_token is null or length(p_token) < 24 then raise exception 'token too short'; end if;
  update public.email_settings set token_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex'), updated_at = now() where id = 1;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_email_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare dl int;
begin
  perform public._require_admin();
  select delay_minutes into dl from public.email_settings where id = 1;
  return jsonb_build_object(
    'mode', (select mode from public.email_settings where id = 1),
    'hasToken', (select token_hash is not null from public.email_settings where id = 1),
    'delayMinutes', dl,
    'due', coalesce((select jsonb_agg(jsonb_build_object('shopKey', d.shop_key, 'shop', d.shop, 'email', d.email, 'tables', d.tables, 'total', d.total, 'paid', d.paid,
              'validEmail', d.valid_email, 'held', exists (select 1 from public.email_hold h where h.shop_key = d.shop_key),
              'sendAt', coalesce(p.first_due_at, now()) + make_interval(mins => dl)) order by d.shop)
              from public._email_due() d left join public.email_pending p on p.shop_key = d.shop_key), '[]'::jsonb),
    'sent', coalesce((select jsonb_agg(jsonb_build_object('shop', shop, 'email', to_email, 'status', status, 'attempts', attempts, 'sentAt', sent_at, 'error', error) order by updated_at desc) from public.email_outbox), '[]'::jsonb));
end $$;

create or replace function public.admin_email_hold(p_shop_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  insert into public.email_hold (shop_key) values (p_shop_key) on conflict do nothing;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_email_release(p_shop_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  delete from public.email_hold where shop_key = p_shop_key;
  update public.email_pending set first_due_at = now() where shop_key = p_shop_key;   -- released: the grace period starts again
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.admin_email_set_delay(p_minutes int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_minutes is null or p_minutes < 0 or p_minutes > 120 then raise exception 'bad delay'; end if;
  update public.email_settings set delay_minutes = p_minutes, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'delayMinutes', p_minutes);
end $$;

-- let a shop be e-mailed again (e.g. after its tables changed)
create or replace function public.admin_email_reset(p_shop_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  delete from public.email_outbox where shop_key = p_shop_key;
  delete from public.email_pending where shop_key = p_shop_key;
  delete from public.email_hold where shop_key = p_shop_key;
  return jsonb_build_object('ok', true);
end $$;

grant execute on function public.email_queue_fetch(text, int)       to anon, authenticated;
grant execute on function public.email_queue_mark(text, jsonb)      to anon, authenticated;
grant execute on function public.admin_email_set_mode(text)         to authenticated;
grant execute on function public.admin_email_set_token(text)        to authenticated;
grant execute on function public.admin_email_status()               to authenticated;
grant execute on function public.admin_email_reset(text)            to authenticated;
grant execute on function public.admin_email_hold(text)             to authenticated;
grant execute on function public.admin_email_release(text)          to authenticated;
grant execute on function public.admin_email_set_delay(int)         to authenticated;
