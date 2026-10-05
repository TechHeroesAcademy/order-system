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
