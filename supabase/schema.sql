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
    'zones',  public._docs('live', 'zones'),
    'tables', public._docs('live', 'tables'),
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
declare v jsonb;
begin
  v := public._clean_booking(p_table_id, p_data, null);
  insert into public.documents (store, collection, id, data)
  values ('live', 'bookings', p_table_id, v)
  on conflict (store, collection, id) do nothing;   -- the primary key makes double-booking impossible
  if not found then raise exception 'table already booked'; end if;
  return jsonb_build_object('ok', true, 'booking', v);
end $$;

create or replace function public.create_booking_multi(p_items jsonb) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  g uuid := gen_random_uuid(); item jsonb; tid text; v jsonb;
  booked text[] := '{}'; skipped text[] := '{}'; out_b jsonb := '{}'::jsonb;
begin
  if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'missing bookings';
  end if;
  if jsonb_array_length(p_items) > 20 then raise exception 'too many tables in one booking'; end if;
  for item in select value from jsonb_array_elements(p_items) loop
    tid := item->>'tableId';
    if tid is null or public._doc('live', 'tables', tid) is null then
      skipped := skipped || coalesce(tid, '?');
      continue;
    end if;
    v := public._clean_booking(tid, item->'data', g);
    insert into public.documents (store, collection, id, data)
    values ('live', 'bookings', tid, v)
    on conflict (store, collection, id) do nothing;
    if found then booked := booked || tid; out_b := out_b || jsonb_build_object(tid, v);
    else skipped := skipped || tid; end if;
  end loop;
  return jsonb_build_object('ok', true, 'groupId', g, 'booked', to_jsonb(booked),
                            'skipped', to_jsonb(skipped), 'bookings', out_b);
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

-- ---------------------------------------------------------------------
-- file uploads (slip / logo / payment QR) — Supabase Storage
-- Public bucket: files are readable by their (random, unguessable) URL,
-- like the old "anyone with the link" Drive files. Nobody can list or
-- overwrite them; anyone can add an image up to 5 MB.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('uploads', 'uploads', true, 5242880, array['image/jpeg', 'image/png', 'image/webp', 'image/gif'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "uploads: anyone can add images" on storage.objects;
create policy "uploads: anyone can add images" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'uploads' and (storage.foldername(name))[1] in ('slip', 'logo', 'other'));
