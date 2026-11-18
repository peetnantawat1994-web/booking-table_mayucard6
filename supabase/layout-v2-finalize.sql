-- MAYUCARD 6 — floor plan v2 (step 2 of 2: run AFTER the new page is merged / live).
-- Makes the new positions permanent: x/y/w/h = v2, drops the flags, deletes B03-B05.
-- Idempotent. Back up first.
do $$
declare s text;
begin
  foreach s in array array['live','draft'] loop
    -- a draft that does not exist yet is simply copied from live on the first admin visit
    continue when s = 'draft' and not exists (select 1 from public.documents where store = 'draft' and collection = 'tables');
    delete from public.documents where store = s and collection = 'tables' and data->>'v2gone' = 'true'
       and not exists (select 1 from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id = documents.id);
    update public.documents
       set data = ((data - 'v2' - 'v2only' - 'v2gone') || coalesce(data->'v2', '{}'::jsonb)), updated_at = now()
     where store = s and collection = 'tables' and (data ? 'v2' or data ? 'v2only');
    update public.documents set data = data - 'v2only', updated_at = now()
     where store = s and collection = 'zones' and data ? 'v2only';
  end loop;
end $$;
select store, count(*) from public.documents where collection = 'tables' and store in ('live','draft') group by store order by store;
