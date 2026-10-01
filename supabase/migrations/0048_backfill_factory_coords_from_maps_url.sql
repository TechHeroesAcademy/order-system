-- 0048_backfill_factory_coords_from_maps_url.sql
--
-- Fills in lat/lng for factories that have a pasted Google Maps link but no
-- coordinates, so they appear on the map instead of being invisible.
--
-- The app already extracts coordinates when a link is entered (it runs when
-- the موقع field loses focus). But that only helps going forward: a factory
-- saved before that existed — or one where the field was never blurred,
-- because the link was pasted and the form submitted straight away — keeps
-- the link and no numbers. The map plots lat/lng, so those factories are
-- simply absent from it with nothing to indicate why.
--
-- Idempotent, and it only ever writes where both columns are currently
-- null, so a pin someone placed by hand is never overwritten by a less
-- precise value from a URL.

do $$
declare
  v_row record;
  v_lat double precision;
  v_lng double precision;
  v_filled int := 0;
  v_skipped int := 0;
begin
  for v_row in
    select id, name, maps_url
      from public.factories
     where maps_url is not null
       and trim(maps_url) <> ''
       and (lat is null or lng is null)
  loop
    v_lat := null;
    v_lng := null;

    -- !3d<lat>!4d<lng> — the place itself. Preferred, because the other
    -- pair in a Google place URL (@lat,lng) is where the camera was
    -- pointing when the link was made, which in a real pasted example sat
    -- about 250 m away from the building. Close enough to look right on a
    -- map and wrong enough to send a driver to the wrong gate.
    if v_row.maps_url ~ '!3d-?[0-9.]+!4d-?[0-9.]+' then
      v_lat := (regexp_match(v_row.maps_url, '!3d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '!4d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    -- @<lat>,<lng> — the camera centre. Only when there is no place pair,
    -- which is what a dropped pin or a plain map view looks like.
    elsif v_row.maps_url ~ '@-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '@(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '@-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    -- ?q=<lat>,<lng> — older share format, and hand-built links.
    elsif v_row.maps_url ~ '[?&]q=-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '[?&]q=(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '[?&]q=-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
    end if;

    -- A short share link (maps.app.goo.gl/…) carries no coordinates at all
    -- and can only be resolved by following its redirect, which the
    -- database cannot do. Those are counted and reported rather than
    -- guessed at — re-saving the factory in the app resolves them.
    if v_lat is null or v_lng is null
       or abs(v_lat) > 90 or abs(v_lng) > 180
       or (v_lat = 0 and v_lng = 0) then
      v_skipped := v_skipped + 1;
      raise notice 'no usable coordinates in the link for: %', v_row.name;
      continue;
    end if;

    update public.factories
       set lat = v_lat, lng = v_lng
     where id = v_row.id;
    v_filled := v_filled + 1;
    raise notice 'placed % at %, %', v_row.name, v_lat, v_lng;
  end loop;

  raise notice '— % factory/factories placed on the map, % still without coordinates', v_filled, v_skipped;
  if v_skipped > 0 then
    raise notice '— for those, open the factory in إدارة الفريق and re-save, or click its location on the map';
  end if;
end $$;
