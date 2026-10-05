create or replace function public.update_order_details(
  p_order_id uuid,
  p_customer_name text,
  p_customer_phone text,
  p_customer_address text,
  p_customer_maps_url text,
  p_region_id uuid,
  p_pieces_count integer,
  p_piece_details text,
  p_color text,
  p_work_required text,
  p_customer_notes text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
  v_new_maps_url text := nullif(trim(coalesce(p_customer_maps_url, '')), '');
  v_changes text := '';
begin
  if not coalesce(public.is_owner_or_moderator(), false) then
    raise exception 'غير مصرح لك بتعديل بيانات الأوردر' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then
    raise exception 'الأوردر غير موجود';
  end if;

  if length(trim(coalesce(p_customer_name, ''))) = 0 then
    raise exception 'اسم العميل مطلوب' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_phone, ''))) < 8 then
    raise exception 'رقم هاتف العميل غير صالح' using errcode = '22023';
  end if;
  if length(trim(coalesce(p_customer_address, ''))) < 5 then
    raise exception 'العنوان قصير جدًا' using errcode = '22023';
  end if;
  if p_pieces_count is null or p_pieces_count < 1 then
    raise exception 'عدد القطع يجب أن يكون 1 على الأقل' using errcode = '22023';
  end if;

  if trim(v_order.customer_name) is distinct from trim(p_customer_name) then
    v_changes := v_changes || 'الاسم، ';
  end if;
  if trim(v_order.customer_phone) is distinct from trim(p_customer_phone) then
    v_changes := v_changes || 'الهاتف، ';
  end if;
  if trim(v_order.customer_address) is distinct from trim(p_customer_address) then
    v_changes := v_changes || 'العنوان، ';
  end if;
  if coalesce(v_order.customer_maps_url, '') is distinct from coalesce(v_new_maps_url, '') then
    v_changes := v_changes || 'رابط الخريطة، ';
  end if;
  if v_order.region_id is distinct from p_region_id then
    v_changes := v_changes || 'المنطقة، ';
  end if;
  if v_order.pieces_count is distinct from p_pieces_count then
    v_changes := v_changes || 'عدد القطع، ';
  end if;
  if coalesce(v_order.piece_details, '') is distinct from coalesce(p_piece_details, '') then
    v_changes := v_changes || 'تفاصيل القطع، ';
  end if;
  if coalesce(v_order.color, '') is distinct from coalesce(p_color, '') then
    v_changes := v_changes || 'اللون، ';
  end if;
  if coalesce(v_order.work_required, '') is distinct from coalesce(p_work_required, '') then
    v_changes := v_changes || 'المطلوب عمله، ';
  end if;
  if coalesce(v_order.customer_notes, '') is distinct from coalesce(p_customer_notes, '') then
    v_changes := v_changes || 'الملاحظات، ';
  end if;

  update public.orders set
    customer_name = trim(p_customer_name),
    customer_phone = trim(p_customer_phone),
    customer_address = trim(p_customer_address),
    customer_maps_url = v_new_maps_url,
    region_id = p_region_id,
    pieces_count = p_pieces_count,
    piece_details = p_piece_details,
    color = p_color,
    work_required = p_work_required,
    customer_notes = p_customer_notes
  where id = p_order_id;

  if v_changes <> '' then
    perform public.log_order_event(p_order_id, 'details_edited', v_order.status, v_order.status,
      'تم تعديل: ' || left(v_changes, length(v_changes) - 2));
  end if;
end;
$$;

revoke all on function public.update_order_details from public, anon, authenticated;
grant execute on function public.update_order_details to authenticated;
