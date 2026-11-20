-- MAYUCARD 6 — floor plan v3, step 2 of 2: run AFTER the new page is live. Makes the v3 positions permanent. Idempotent.
do $$
declare s text;
begin
  foreach s in array array['live','draft'] loop
    continue when s = 'draft' and not exists (select 1 from public.documents where store = 'draft' and collection = 'tables');
    update public.documents set data = ((data - 'v3') || coalesce(data->'v3', '{}'::jsonb)), updated_at = now()
     where store = s and collection = 'tables' and data ? 'v3';
  end loop;
end $$;
select store, count(*) filter (where data ? 'v3') still_v3, count(*) total from public.documents where collection = 'tables' and store in ('live','draft') group by store order by store;
