-- 0027_factory_only_order_creation.sql
--
-- "when creating orders choose the factory only not the driver and it
-- should [be] assigned auto" — clarified: the Moderator now also gets a
-- factory picker at order creation (previously Owner-only, migration 0024),
-- but nobody picks a driver manually at creation time anymore, not even
-- the Owner — it is always the fair region-based auto-pick
-- (create_order_internal's p_driver_id-is-null branch, unchanged since
-- 0024/0025), and it always stays a *pending suggestion* until the Owner
-- approves or reassigns it from <DistributionPanel> — same gate a
-- Moderator's order already went through, now also applied to an Owner's
-- own orders. Assigning/reassigning/approving a driver after creation
-- remains Owner-only (set_order_distribution / reassign_order_driver /
-- approve_distribution / clear_order_distribution — all unchanged, already
-- Owner-only since 0024).
--
-- create_order_internal itself needs no change: it has done exactly the
-- right thing since 0024 (then 0025's p_region_id -> p_region_name switch)
-- whenever p_driver_id is null. Only moderator_create_order's gate
-- changes — factory_id opens up to any staff member who can create an
-- order, and driver_id is rejected from everyone rather than only from a
-- Moderator. Signature (text,text,text,text,integer,text,text,text,text,
-- uuid,uuid,text) is unchanged from 0025 — only the body changes, so this
-- is a plain CREATE OR REPLACE, no drop/ambiguity risk.
create or replace function public.moderator_create_order(
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_region_name text,
  p_pieces_count integer,
  p_piece_details text default null,
  p_color text default null,
  p_work_required text default null,
  p_customer_notes text default null,
  p_factory_id uuid default null,
  p_driver_id uuid default null,
  p_customer_maps_url text default null
)
returns public.new_order_result
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_owner_or_moderator() then
    raise exception 'غير مصرح لك بإنشاء أوردر' using errcode = '42501';
  end if;

  -- The driver is never picked directly at order creation by anyone,
  -- Owner included, as of this migration — it's always the fair
  -- region-based auto-suggestion, pending the Owner's approval. The
  -- frontend never sends p_driver_id from this form anymore; this is the
  -- server-side half of that rule (defense in depth, same pattern as
  -- every other role check in this file).
  if p_driver_id is not null then
    raise exception 'يتم تعيين المندوب تلقائيًا عند إنشاء الأوردر، لا يمكن اختياره يدويًا' using errcode = '42501';
  end if;

  return public.create_order_internal(
    p_customer_name, p_customer_phone, p_customer_address, p_region_name,
    p_pieces_count, p_piece_details, p_color, p_work_required, p_customer_notes,
    'messenger', auth.uid(), p_factory_id, null, p_customer_maps_url
  );
end;
$$;

revoke all on function public.moderator_create_order(text, text, text, text, integer, text, text, text, text, uuid, uuid, text) from public;
grant execute on function public.moderator_create_order(text, text, text, text, integer, text, text, text, text, uuid, uuid, text) to authenticated;
