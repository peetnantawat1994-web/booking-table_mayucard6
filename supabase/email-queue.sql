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
