-- =====================================================================
-- MAYUCARD 6 — customer confirmation e-mails (queue for the Apps Script sender)
-- Idempotent. The database never sends mail itself: a small Google Apps Script in the sender's Google
-- account asks "who is due an e-mail?", sends it from that account, then reports back (see tools/email-sender).
-- Safety: mode 'off' (default) | 'dry' (list only, nothing is sent) | 'live'. Every call needs a secret token.
-- Rule: every table of the shop is confirmed/paid (the admin checks the slips before confirming). The read slip amount is shown
-- to the admins as information only (slipOk) and does not block sending.
-- Control per shop (admin): send = approved (goes out within a minute) | review = on hold | cancel = never.
-- No decision = "ready": sent only if the admin switch "auto send" is on, after the grace period.
-- =====================================================================
create table if not exists public.email_settings (
  id          int primary key default 1 check (id = 1),
  mode        text not null default 'off' check (mode in ('off', 'dry', 'live')),
  token_hash  text,
  updated_at  timestamptz not null default now()
);
alter table public.email_settings add column if not exists delay_minutes int not null default 10;   -- grace period before an AUTO e-mail goes out
alter table public.email_settings add column if not exists auto_send boolean not null default false; -- off: only shops an admin approved are sent
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
-- admin decision per shop: 'approved' (send), 'hold' (waiting for review), 'cancelled' (do not send)
create table if not exists public.email_decision (
  shop_key   text primary key,
  decision   text not null check (decision in ('approved', 'hold', 'cancelled')),
  by_email   text,
  decided_at timestamptz not null default now()
);
alter table public.email_decision enable row level security;
revoke all on public.email_decision from anon, authenticated;
do $mig$ begin   -- the earlier "hold" table becomes decisions of type 'hold'
  if to_regclass('public.email_hold') is not null then
    insert into public.email_decision (shop_key, decision, decided_at) select shop_key, 'hold', held_at from public.email_hold on conflict do nothing;
    drop table public.email_hold;
  end if;
end $mig$;

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
alter table public.email_outbox add column if not exists approved_by text;
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

-- every shop with its totals and the two rule checks
create or replace function public._email_shops() returns table (
  shop_key text, shop text, contact text, email text, tables text[], lines jsonb, total numeric, paid numeric, has_logo boolean,
  valid_email boolean, all_ok boolean, paid_ok boolean, n_open int)
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
           sum(price) as total, bool_and(st in ('confirmed', 'paid')) as all_ok, bool_and(logo) as has_logo,
           count(*) filter (where st not in ('confirmed', 'paid'))::int as n_open
    from b where k <> '' group by k),
  x as (select g.*, coalesce((select sum(amt) from share where share.k = g.shop_key), 0)::numeric as paid_amt from g)
  select x.shop_key, x.shop, x.contact, x.email, x.tables, x.lines, x.total, x.paid_amt, x.has_logo,
         x.email ~ '^[^@\s]+@[^@\s]+\.[^@\s]{2,}$', x.all_ok, (x.total > 0 and x.paid_amt >= x.total - 0.5), x.n_open
  from x;
$$;

-- which shops meet the rule right now = all tables confirmed/paid (and not yet sent / given up on)
create or replace function public._email_due() returns table (
  shop_key text, shop text, contact text, email text, tables text[], lines jsonb, total numeric, paid numeric, has_logo boolean, valid_email boolean)
language sql stable security definer set search_path = public as $$
  select s.shop_key, s.shop, s.contact, s.email, s.tables, s.lines, s.total, s.paid, s.has_logo, s.valid_email
  from public._email_shops() s
  where s.all_ok
    and not exists (select 1 from public.email_outbox o where o.shop_key = s.shop_key and (o.status = 'sent' or o.attempts >= 3));
$$;

create or replace function public._actor() returns text
language sql stable as $$
  select nullif(coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email', ''), '');
$$;

-- called by the sender script (token-protected). Also keeps the grace-period clock for auto sending.
create or replace function public.email_queue_fetch(p_token text, p_limit int default 10) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m text; dl int; au boolean; items jsonb; bad jsonb; waiting jsonb;
begin
  if not public._email_token_ok(p_token) then raise exception 'not authorized' using errcode = '42501'; end if;
  select mode, delay_minutes, auto_send into m, dl, au from public.email_settings where id = 1;
  if m = 'off' then return jsonb_build_object('mode', 'off', 'items', '[]'::jsonb, 'invalid', '[]'::jsonb, 'waiting', '[]'::jsonb); end if;
  insert into public.email_pending (shop_key) select shop_key from public._email_due() on conflict do nothing;
  delete from public.email_pending where shop_key not in (select shop_key from public._email_due());   -- stopped being due: the clock restarts
  delete from public.email_decision where decision = 'approved' and shop_key not in (select shop_key from public._email_due()) and not exists (select 1 from public.email_outbox o where o.shop_key = email_decision.shop_key and o.status = 'sent');   -- an approval does not survive the shop falling out of the rule
  select coalesce(jsonb_agg(to_jsonb(x)), '[]'::jsonb) into items from (
    select d.shop_key as "shopKey", d.shop, d.contact, d.email, d.tables, d.lines, d.total, d.paid, d.has_logo as "hasLogo"
    from public._email_due() d join public.email_pending p on p.shop_key = d.shop_key
    left join public.email_decision n on n.shop_key = d.shop_key
    where d.valid_email
      and (n.decision = 'approved' or (n.decision is null and au and p.first_due_at <= now() - make_interval(mins => dl)))
    order by p.first_due_at limit greatest(1, least(coalesce(p_limit, 10), 50))) x;
  select coalesce(jsonb_agg(jsonb_build_object('shopKey', d.shop_key, 'shop', d.shop, 'sendAt', p.first_due_at + make_interval(mins => dl))), '[]'::jsonb) into waiting
    from public._email_due() d join public.email_pending p on p.shop_key = d.shop_key
    where au and d.valid_email and not exists (select 1 from public.email_decision n where n.shop_key = d.shop_key)
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
    insert into public.email_outbox (shop_key, shop, to_email, tables, total, paid, status, attempts, error, sent_at, approved_by)
    values (d.shop_key, d.shop, d.email, d.tables, d.total, d.paid,
            case when r->>'status' = 'sent' then 'sent' else 'failed' end, 1, left(r->>'error', 300),
            case when r->>'status' = 'sent' then now() end,
            (select by_email from public.email_decision where shop_key = d.shop_key and decision = 'approved'))
    on conflict (shop_key) do update
      set status = excluded.status, attempts = public.email_outbox.attempts + 1, error = excluded.error,
          sent_at = excluded.sent_at, to_email = excluded.to_email, tables = excluded.tables,
          total = excluded.total, paid = excluded.paid, approved_by = excluded.approved_by, updated_at = now();
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

-- one row per shop with a plain state for the dashboard:
-- sent | failed | queued (will go out) | ready (waiting for an admin or the auto switch) | hold | cancelled | notready (a table is not confirmed yet)
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
    'autoSend', (select auto_send from public.email_settings where id = 1),
    'shops', coalesce((select jsonb_agg(row_to_json(z)::jsonb order by z.shop) from (
      select s.shop_key as "shopKey", s.shop, s.email, s.tables, s.total, s.paid, s.valid_email as "validEmail", s.n_open as "nOpen",
        case when o.status = 'sent' then 'sent'
             when o.status = 'failed' and o.attempts >= 3 then 'failed'
             when not s.all_ok then 'notready'
             when n.decision = 'cancelled' then 'cancelled'
             when n.decision = 'hold' then 'hold'
             when n.decision = 'approved' or (e.auto_send and s.valid_email) then 'queued'
             else 'ready' end as state,
        case when s.all_ok then null else 'tables' end as reason, s.paid_ok as "slipOk",
        case when n.decision = 'approved' then null else p.first_due_at + make_interval(mins => e.delay_minutes) end as "sendAt",
        o.sent_at as "sentAt", o.attempts, o.error, coalesce(o.approved_by, n.by_email) as "by", n.decision, n.decided_at as "decidedAt"
      from public._email_shops() s cross join public.email_settings e
      left join public.email_outbox o on o.shop_key = s.shop_key
      left join public.email_decision n on n.shop_key = s.shop_key
      left join public.email_pending p on p.shop_key = s.shop_key
      where e.id = 1) z), '[]'::jsonb));
end $$;

create or replace function public._email_decide(p_shop_key text, p_decision text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare d record;
begin
  perform public._require_admin();
  if exists (select 1 from public.email_outbox where shop_key = p_shop_key and status = 'sent') then raise exception 'already sent'; end if;
  if p_decision = 'approved' then
    select * into d from public._email_due() where shop_key = p_shop_key;
    if not found then raise exception 'shop does not meet the rule yet'; end if;
    if not d.valid_email then raise exception 'invalid e-mail address'; end if;
  end if;
  insert into public.email_decision (shop_key, decision, by_email) values (p_shop_key, p_decision, public._actor())
  on conflict (shop_key) do update set decision = excluded.decision, by_email = excluded.by_email, decided_at = now();
  return jsonb_build_object('ok', true, 'decision', p_decision);
end $$;

create or replace function public.admin_email_approve(p_shop_key text) returns jsonb
language sql volatile security definer set search_path = public as $$ select public._email_decide(p_shop_key, 'approved'); $$;
create or replace function public.admin_email_review(p_shop_key text) returns jsonb
language sql volatile security definer set search_path = public as $$ select public._email_decide(p_shop_key, 'hold'); $$;
create or replace function public.admin_email_cancel(p_shop_key text) returns jsonb
language sql volatile security definer set search_path = public as $$ select public._email_decide(p_shop_key, 'cancelled'); $$;

-- back to "ready" (no decision)
create or replace function public.admin_email_clear(p_shop_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  delete from public.email_decision where shop_key = p_shop_key;
  update public.email_pending set first_due_at = now() where shop_key = p_shop_key;   -- the grace period starts again
  return jsonb_build_object('ok', true);
end $$;

-- send again (failed, or the customer says it never arrived): forget the old result and approve
create or replace function public.admin_email_resend(p_shop_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  delete from public.email_outbox where shop_key = p_shop_key;
  return public._email_decide(p_shop_key, 'approved');
end $$;

create or replace function public.admin_email_set_auto(p_on boolean) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  update public.email_settings set auto_send = coalesce(p_on, false), updated_at = now() where id = 1;
  if coalesce(p_on, false) then update public.email_pending set first_due_at = now(); end if;   -- switching on starts the grace period for everyone
  return jsonb_build_object('ok', true, 'autoSend', coalesce(p_on, false));
end $$;

create or replace function public.admin_email_set_delay(p_minutes int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  if p_minutes is null or p_minutes < 0 or p_minutes > 120 then raise exception 'bad delay'; end if;
  update public.email_settings set delay_minutes = p_minutes, updated_at = now() where id = 1;
  return jsonb_build_object('ok', true, 'delayMinutes', p_minutes);
end $$;

-- forget everything about a shop (result and decision)
create or replace function public.admin_email_reset(p_shop_key text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform public._require_admin();
  delete from public.email_outbox where shop_key = p_shop_key;
  delete from public.email_pending where shop_key = p_shop_key;
  delete from public.email_decision where shop_key = p_shop_key;
  return jsonb_build_object('ok', true);
end $$;

drop function if exists public.admin_email_hold(text);
drop function if exists public.admin_email_release(text);

grant execute on function public.email_queue_fetch(text, int)       to anon, authenticated;
grant execute on function public.email_queue_mark(text, jsonb)      to anon, authenticated;
grant execute on function public.admin_email_set_mode(text)         to authenticated;
grant execute on function public.admin_email_set_token(text)        to authenticated;
grant execute on function public.admin_email_status()               to authenticated;
grant execute on function public.admin_email_reset(text)            to authenticated;
grant execute on function public.admin_email_approve(text)          to authenticated;
grant execute on function public.admin_email_review(text)           to authenticated;
grant execute on function public.admin_email_cancel(text)           to authenticated;
grant execute on function public.admin_email_clear(text)            to authenticated;
grant execute on function public.admin_email_resend(text)           to authenticated;
grant execute on function public.admin_email_set_auto(boolean)      to authenticated;
grant execute on function public.admin_email_set_delay(int)         to authenticated;
revoke execute on function public._email_decide(text, text) from public, anon, authenticated;
revoke execute on function public._email_shops() from public, anon, authenticated;
