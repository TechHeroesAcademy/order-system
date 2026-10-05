begin;

revoke all on function public.create_order_internal(
  text, text, text, text, integer, text, text, text, text,
  public.order_source, uuid, uuid, uuid, text
) from public, authenticated, app_user;

do $$
declare
  v_exposed text[];
begin
  select coalesce(array_agg(p.proname order by p.proname), '{}')
    into v_exposed
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prosecdef
     and p.prosrc ~* 'insert into (public\.)?orders'
     and p.prosrc !~ 'is_owner|is_owner_or_moderator|current_user_role|auth\.uid'
     and has_function_privilege('app_user', p.oid, 'EXECUTE');

  if cardinality(v_exposed) > 0 then
    raise exception
      'these insert an order, never check the caller, and app_user can execute them: %',
      v_exposed;
  end if;
end;
$$;

commit;
