begin;

do $$
declare
  v_left integer;
begin
  drop function if exists public.public_create_order(
    text, text, text, text, integer, text, text, text, text, uuid, text
  );

  select count(*) into v_left
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'public_create_order';

  if v_left > 0 then
    raise exception
      'public_create_order still exists with % signature(s); drop it explicitly rather than leaving it callable', v_left;
  end if;
end;
$$;

do $$
declare
  v_bad text[];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}')
    into v_bad
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname in (
       'create_order_internal', 'moderator_create_order', 'driver_create_field_order'
     )
     and p.prosecdef
     and p.proname <> 'create_order_internal'
     and p.prosrc !~ 'is_owner_or_moderator|current_user_role|auth\.uid';

  if cardinality(v_bad) > 0 then
    raise exception 'order-creating function(s) with no caller check: %', v_bad;
  end if;
end;
$$;

commit;
