-- 0043_moderator_notifications_delivered_only.sql
--
-- A Moderator's bell now carries one thing: an order was delivered.
--
-- Until now they received eleven types — collected, heading to factory, left
-- factory, factory received, ready for pickup, delivered, refused, cancelled,
-- driver reassigned, factory reassigned, and needs_allocation. All of it came
-- through notify_staff(), which fans out to every active owner and moderator
-- with no distinction between them, so this is one change rather than eleven
-- call sites edited.
--
-- Several of those were never actionable for a Moderator anyway:
-- needs_allocation asks someone to allocate an order, and allocation has been
-- Manager-only at the database level since 0035; driver_reassigned and
-- factory_reassigned report a decision only a Manager can make. They were
-- noise in the one place that is supposed to mean "something needs you".
--
-- Not affected: new_order and chat_message already went to owners only
-- (notify_role('owner')), and a Manager's bell is unchanged in every respect.

-- Which notification types reach a Moderator. A function rather than a
-- literal inside notify_staff so there is one obvious place to look, and one
-- line to change if another type ever earns a Moderator's attention.
create or replace function public.moderator_notification_types()
returns text[]
language sql
immutable
as $$ select array['order_delivered'] $$;

-- notify_staff, with the one added condition. Everything else — the active
-- check, the p_exclude that keeps the person who acted from being told about
-- their own action, the delegation to notify_user — is unchanged from 0019.
create or replace function public.notify_staff(
  p_order_id uuid,
  p_type text,
  p_title text,
  p_body text default null,
  p_exclude uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user record;
begin
  for v_user in
    select id from public.profiles
    where role in ('owner', 'moderator') and is_active
      and (p_exclude is null or id <> p_exclude)
      -- Managers get everything, as before. Moderators get only the types
      -- listed above. Written this way round on purpose: a new notification
      -- type added later reaches Managers automatically and Moderators only
      -- if someone deliberately adds it, which is the safer default for the
      -- role with the narrower job.
      and (role = 'owner' or p_type = any (public.moderator_notification_types()))
  loop
    perform public.notify_user(v_user.id, p_order_id, p_type, p_title, p_body);
  end loop;
end;
$$;

revoke all on function public.notify_staff(uuid, text, text, text, uuid) from public;
revoke all on function public.moderator_notification_types() from public;

-- ── the ones already sitting in their bells ─────────────────────────────
--
-- The change above stops new ones being written; it does nothing about what
-- is already there, and a Moderator opening the bell would still see months
-- of the types they are no longer meant to get.
--
-- Deleting is safe here specifically because notifications are not the
-- record. Every one of these events is written to order_history by
-- log_order_event() in the same transaction, and that is what the order
-- timeline and every report read. A notification is a nudge that something
-- happened; the history is the fact that it did. Nothing auditable is lost.
--
-- Scoped to moderators and to types that are no longer sent, so a Manager's
-- bell is untouched and a Moderator keeps every delivered notification they
-- already had.
delete from public.notifications n
 using public.profiles p
 where p.id = n.user_id
   and p.role = 'moderator'
   and not (n.type = any (public.moderator_notification_types()));
