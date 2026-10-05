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

    if v_row.maps_url ~ '!3d-?[0-9.]+!4d-?[0-9.]+' then
      v_lat := (regexp_match(v_row.maps_url, '!3d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '!4d(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    elsif v_row.maps_url ~ '@-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '@(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '@-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;

    elsif v_row.maps_url ~ '[?&]q=-?[0-9]+(\.[0-9]+)?,-?[0-9]+(\.[0-9]+)?' then
      v_lat := (regexp_match(v_row.maps_url, '[?&]q=(-?[0-9]+(?:\.[0-9]+)?),'))[1]::double precision;
      v_lng := (regexp_match(v_row.maps_url, '[?&]q=-?[0-9]+(?:\.[0-9]+)?,(-?[0-9]+(?:\.[0-9]+)?)'))[1]::double precision;
    end if;

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
end$$;
