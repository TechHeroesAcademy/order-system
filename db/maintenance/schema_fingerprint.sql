\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on

select 'TABLE|'||c.relname||'|'||c.relrowsecurity::text||'|'||c.relforcerowsecurity::text
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and c.relkind = 'r'
 order by 1;

select 'COL|'||table_name||'|'||column_name||'|'||data_type||'|'||is_nullable
       ||'|'||coalesce(column_default, '-')
  from information_schema.columns
 where table_schema = 'public'
 order by 1;

select 'POLICY|'||schemaname||'|'||tablename||'|'||policyname||'|'||cmd
       ||'|'||coalesce(roles::text, '-')||'|'||coalesce(qual, '-')
       ||'|'||coalesce(with_check, '-')
  from pg_policies
 where schemaname = 'public'
 order by 1;

select 'FUNC|'||p.proname||'|'||pg_get_function_identity_arguments(p.oid)
       ||'|'||pg_get_function_result(p.oid)||'|'||p.prosecdef::text
       ||'|'||p.provolatile::text||'|'||p.proretset::text
       ||'|'||coalesce(p.proconfig::text, '-')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public'
 order by 1;

select 'INDEX|'||indexname||'|'||indexdef
  from pg_indexes where schemaname = 'public' order by 1;

select 'TRIGGER|'||c.relname||'|'||t.tgname||'|'||pg_get_triggerdef(t.oid)
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
 where n.nspname = 'public' and not t.tgisinternal
 order by 1;

select 'CONSTRAINT|'||conrelid::regclass::text||'|'||conname||'|'||pg_get_constraintdef(oid)
  from pg_constraint where connamespace = 'public'::regnamespace order by 1;

select 'ENUM|'||t.typname||'|'||e.enumlabel||'|'||e.enumsortorder::text
  from pg_type t
  join pg_enum e on e.enumtypid = t.oid
  join pg_namespace n on n.oid = t.typnamespace
 where n.nspname = 'public'
 order by 1;

select 'GRANT|'||table_name||'|'||grantee||'|'||privilege_type
  from information_schema.role_table_grants
 where table_schema = 'public'
 order by 1;

select 'ROLE|'||rolname||'|'||rolcanlogin::text||'|'||rolsuper::text||'|'||rolbypassrls::text
  from pg_roles
 where rolname in ('app_user', 'authenticated', 'app_admin', 'anon', 'service_role')
 order by 1;
