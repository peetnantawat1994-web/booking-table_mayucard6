-- MAYUCARD 6 — floor plan v2 (step 1 of 2: SAFE to run while the old page is still live).
-- Idempotent. Run in the SQL editor of the Supabase project, once for production.
--   * existing tables keep their old x/y/w/h (the old page keeps working) and get a "v2" position
--   * new tables / zones are flagged "v2only": the old page never receives them (see get_public_state)
--   * B03-B05 are not on the new plan: flagged "v2gone" (deleted by layout-v2-finalize.sql after the new page is live)
--   * SP01-SP05 and the 3 card-teaching tables (T01-T03) are created LOCKED: customers cannot book them,
--     admins can still open and edit everything
-- Back up first (see DEPLOY.md). Applies to both the live and the draft layout.
do $$
declare
  s text;
  layout jsonb := '{"VIP01":{"x":38.95,"y":31.579,"w":3.65,"h":2.229},"P01":{"x":43.0,"y":31.579,"w":3.65,"h":2.229},"P02":{"x":47.1,"y":31.579,"w":3.65,"h":2.229},"P03":{"x":51.25,"y":31.579,"w":3.65,"h":2.229},"P04":{"x":55.375,"y":31.579,"w":3.65,"h":2.229},"P05":{"x":59.5,"y":31.579,"w":3.65,"h":2.229},"P06":{"x":63.6,"y":31.579,"w":3.65,"h":2.229},"P07":{"x":67.7,"y":31.579,"w":3.65,"h":2.229},"P08":{"x":71.825,"y":31.579,"w":3.65,"h":2.229},"P09":{"x":76.0,"y":31.579,"w":3.65,"h":2.229},"P10":{"x":80.2,"y":31.579,"w":3.65,"h":2.229},"VIP09":{"x":84.3,"y":31.579,"w":3.65,"h":2.229},"VIP02":{"x":38.95,"y":36.718,"w":3.65,"h":2.291},"S01":{"x":43.0,"y":36.718,"w":3.65,"h":2.291},"S02":{"x":47.1,"y":36.718,"w":3.65,"h":2.291},"S03":{"x":51.25,"y":36.718,"w":3.65,"h":2.291},"S04":{"x":55.375,"y":36.718,"w":3.65,"h":2.291},"S05":{"x":59.5,"y":36.718,"w":3.65,"h":2.291},"S06":{"x":63.6,"y":36.718,"w":3.65,"h":2.291},"S07":{"x":67.7,"y":36.718,"w":3.65,"h":2.291},"S08":{"x":71.825,"y":36.718,"w":3.65,"h":2.291},"S09":{"x":76.0,"y":36.718,"w":3.65,"h":2.291},"S10":{"x":80.2,"y":36.718,"w":3.65,"h":2.291},"VIP10":{"x":84.275,"y":36.718,"w":3.65,"h":2.291},"VIP03":{"x":38.9,"y":44.892,"w":3.65,"h":2.291},"S11":{"x":43.0,"y":44.892,"w":3.65,"h":2.291},"S12":{"x":47.1,"y":44.892,"w":3.65,"h":2.291},"S13":{"x":51.25,"y":44.892,"w":3.65,"h":2.291},"S14":{"x":55.375,"y":44.892,"w":3.65,"h":2.291},"S15":{"x":59.5,"y":44.892,"w":3.65,"h":2.291},"S16":{"x":63.6,"y":44.892,"w":3.65,"h":2.291},"S17":{"x":67.7,"y":44.892,"w":3.65,"h":2.291},"S18":{"x":71.825,"y":44.892,"w":3.65,"h":2.291},"S19":{"x":76.0,"y":44.892,"w":3.65,"h":2.291},"S20":{"x":80.2,"y":44.892,"w":3.65,"h":2.291},"VIP11":{"x":84.3,"y":44.892,"w":3.65,"h":2.291},"VIP04":{"x":38.95,"y":57.585,"w":3.65,"h":2.291},"S25":{"x":43.0,"y":57.585,"w":3.65,"h":2.291},"S26":{"x":47.1,"y":57.585,"w":3.65,"h":2.291},"S27":{"x":51.25,"y":57.585,"w":3.65,"h":2.291},"S28":{"x":55.375,"y":57.585,"w":3.65,"h":2.291},"S29":{"x":59.5,"y":57.585,"w":3.65,"h":2.291},"S30":{"x":63.6,"y":57.585,"w":3.65,"h":2.291},"S31":{"x":67.7,"y":57.585,"w":3.65,"h":2.291},"S32":{"x":71.825,"y":57.585,"w":3.65,"h":2.291},"S33":{"x":76.0,"y":57.585,"w":3.65,"h":2.291},"S34":{"x":80.2,"y":57.585,"w":3.65,"h":2.291},"VIP13":{"x":84.3,"y":57.585,"w":3.65,"h":2.291},"VIP05":{"x":38.95,"y":63.034,"w":3.65,"h":2.291},"S35":{"x":43.0,"y":63.034,"w":3.65,"h":2.291},"S36":{"x":47.1,"y":63.034,"w":3.65,"h":2.291},"S37":{"x":51.25,"y":63.034,"w":3.65,"h":2.291},"S38":{"x":55.375,"y":63.034,"w":3.65,"h":2.291},"S39":{"x":59.5,"y":63.034,"w":3.65,"h":2.291},"S40":{"x":63.6,"y":63.034,"w":3.65,"h":2.291},"S41":{"x":67.7,"y":63.034,"w":3.65,"h":2.291},"S42":{"x":71.825,"y":63.034,"w":3.65,"h":2.291},"S43":{"x":76.0,"y":63.034,"w":3.65,"h":2.291},"S44":{"x":80.2,"y":63.034,"w":3.65,"h":2.291},"VIP14":{"x":84.275,"y":63.034,"w":3.65,"h":2.291},"VIP06":{"x":38.95,"y":70.464,"w":3.65,"h":2.291},"S45":{"x":43.0,"y":70.464,"w":3.65,"h":2.291},"S46":{"x":47.1,"y":70.464,"w":3.65,"h":2.291},"S47":{"x":51.25,"y":70.464,"w":3.65,"h":2.291},"S48":{"x":55.375,"y":70.464,"w":3.65,"h":2.291},"S49":{"x":59.5,"y":70.464,"w":3.65,"h":2.291},"S50":{"x":63.6,"y":70.464,"w":3.65,"h":2.291},"S51":{"x":67.7,"y":70.464,"w":3.65,"h":2.291},"S52":{"x":71.825,"y":70.464,"w":3.65,"h":2.291},"S53":{"x":76.0,"y":70.464,"w":3.65,"h":2.291},"S54":{"x":80.2,"y":70.464,"w":3.65,"h":2.291},"VIP15":{"x":84.3,"y":70.464,"w":3.65,"h":2.291},"VIP07":{"x":38.95,"y":83.096,"w":3.65,"h":2.229},"S59":{"x":43.0,"y":83.096,"w":3.65,"h":2.229},"S60":{"x":47.1,"y":83.096,"w":3.65,"h":2.229},"S61":{"x":51.25,"y":83.096,"w":3.65,"h":2.229},"S62":{"x":55.375,"y":83.096,"w":3.65,"h":2.229},"S63":{"x":59.5,"y":83.096,"w":3.65,"h":2.229},"S64":{"x":63.6,"y":83.096,"w":3.65,"h":2.229},"S65":{"x":67.7,"y":83.096,"w":3.65,"h":2.229},"S66":{"x":71.825,"y":83.096,"w":3.65,"h":2.229},"S67":{"x":76.0,"y":83.096,"w":3.65,"h":2.229},"S68":{"x":80.2,"y":83.096,"w":3.65,"h":2.229},"VIP17":{"x":84.275,"y":83.096,"w":3.65,"h":2.229},"VIP08":{"x":38.925,"y":88.607,"w":3.65,"h":2.291},"P11":{"x":43.0,"y":88.607,"w":3.65,"h":2.291},"P12":{"x":47.1,"y":88.607,"w":3.65,"h":2.291},"P13":{"x":51.25,"y":88.607,"w":3.65,"h":2.291},"P14":{"x":55.375,"y":88.607,"w":3.65,"h":2.291},"P15":{"x":59.475,"y":88.607,"w":3.65,"h":2.291},"P16":{"x":63.6,"y":88.607,"w":3.65,"h":2.291},"P17":{"x":67.7,"y":88.607,"w":3.65,"h":2.291},"P18":{"x":71.825,"y":88.607,"w":3.65,"h":2.291},"P19":{"x":76.0,"y":88.607,"w":3.65,"h":2.291},"P20":{"x":80.2,"y":88.607,"w":3.65,"h":2.291},"VIP18":{"x":84.275,"y":88.607,"w":3.65,"h":2.291},"A01":{"x":38.975,"y":50.279,"w":3.65,"h":2.229},"V01":{"x":49.575,"y":50.279,"w":3.65,"h":2.229},"S21":{"x":53.475,"y":50.279,"w":3.65,"h":2.229},"S22":{"x":57.475,"y":50.279,"w":3.65,"h":2.229},"S23":{"x":61.475,"y":50.279,"w":3.65,"h":2.229},"V02":{"x":65.425,"y":50.279,"w":3.65,"h":2.229},"B01":{"x":76.275,"y":50.279,"w":3.65,"h":2.229},"S24":{"x":80.175,"y":50.279,"w":3.65,"h":2.229},"VIP12":{"x":84.225,"y":50.279,"w":3.65,"h":2.229},"A02":{"x":38.975,"y":76.099,"w":3.65,"h":2.291},"V03":{"x":49.575,"y":76.099,"w":3.65,"h":2.291},"S55":{"x":53.475,"y":76.099,"w":3.65,"h":2.291},"S56":{"x":57.475,"y":76.099,"w":3.65,"h":2.291},"S57":{"x":61.475,"y":76.099,"w":3.65,"h":2.291},"V04":{"x":65.425,"y":76.099,"w":3.65,"h":2.291},"B02":{"x":76.275,"y":76.099,"w":3.65,"h":2.291},"S58":{"x":80.175,"y":76.099,"w":3.65,"h":2.291},"VIP16":{"x":84.225,"y":76.099,"w":3.65,"h":2.291},"SP01":{"x":49.4,"y":22.353,"w":3.65,"h":2.167},"SP02":{"x":53.575,"y":22.353,"w":3.65,"h":2.167},"SP03":{"x":57.8,"y":22.353,"w":3.65,"h":2.167},"SP04":{"x":61.775,"y":22.353,"w":3.65,"h":2.167},"SP05":{"x":65.975,"y":22.353,"w":3.65,"h":2.167},"T01":{"x":74.2,"y":22.353,"w":3.65,"h":2.167},"T02":{"x":78.375,"y":22.353,"w":3.65,"h":2.167},"T03":{"x":82.575,"y":22.353,"w":3.65,"h":2.167}}'::jsonb;
  newt   jsonb := '{"P15":"premium","P16":"premium","P17":"premium","P18":"premium","P19":"premium","P20":"premium","SP01":"special","SP02":"special","SP03":"special","SP04":"special","SP05":"special","T01":"teach","T02":"teach","T03":"teach"}'::jsonb;
  k text;
begin
  foreach s in array array['live','draft'] loop
    -- a draft that does not exist yet is simply copied from live on the first admin visit
    continue when s = 'draft' and not exists (select 1 from public.documents where store = 'draft' and collection = 'tables');
    -- zones for the two new table groups
    insert into public.documents (store, collection, id, data) values
      (s, 'zones', 'special', jsonb_build_object('key','special','label','SP','color','#018945','price',0,'v2only',true)),
      (s, 'zones', 'teach',   jsonb_build_object('key','teach','label','สอนเล่นการ์ด','color','#f1592a','price',0,'v2only',true))
    on conflict (store, collection, id) do nothing;

    for k in select jsonb_object_keys(layout) loop
      if exists (select 1 from public.documents where store = s and collection = 'tables' and id = k) then
        update public.documents
           set data = data || jsonb_build_object('v2', layout->k), updated_at = now()
         where store = s and collection = 'tables' and id = k;
      else
        insert into public.documents (store, collection, id, data)
        values (s, 'tables', k, jsonb_build_object('id', k, 'zoneKey', newt->>k,
                 'x', layout->k->'x', 'y', layout->k->'y', 'w', layout->k->'w', 'h', layout->k->'h',
                 'v2', layout->k, 'v2only', true)
                 || case when (newt->>k) in ('special','teach') then jsonb_build_object('locked', true) else '{}'::jsonb end);
      end if;
    end loop;

    update public.documents set data = data || jsonb_build_object('v2gone', true), updated_at = now()
     where store = s and collection = 'tables' and id in ('B03','B04','B05')
       and not exists (select 1 from public.documents b where b.store = 'live' and b.collection = 'bookings' and b.id in ('B03','B04','B05'));
  end loop;
end $$;

select store, count(*) filter (where data ? 'v2') with_v2, count(*) filter (where data->>'v2only' = 'true') new_tables,
       count(*) filter (where data->>'locked' = 'true') locked, count(*) filter (where data->>'v2gone' = 'true') gone
from public.documents where collection = 'tables' and store in ('live','draft') group by store order by store;
