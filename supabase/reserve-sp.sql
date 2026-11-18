-- MAYUCARD 6: SP01-SP05 (green tables, top row) are held in advance: shown as "booked", customers cannot book
-- them (they stay locked in the database), admins can still edit everything. Idempotent. Back up first.
do $$
declare s text;
begin
  foreach s in array array['live','draft'] loop
    continue when s = 'draft' and not exists (select 1 from public.documents where store = 'draft' and collection = 'tables');
    update public.documents
       set data = data || jsonb_build_object('locked', true, 'reserved', true), updated_at = now()
     where store = s and collection = 'tables' and id in ('SP01','SP02','SP03','SP04','SP05');
  end loop;
end $$;
select store, count(*) filter (where data->>'reserved' = 'true') reserved, count(*) filter (where data->>'locked' = 'true') locked
from public.documents where collection = 'tables' and store in ('live','draft') group by store order by store;
