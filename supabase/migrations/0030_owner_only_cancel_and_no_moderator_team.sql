create or replace function public.owner_cancel_order(p_order_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order public.orders;
begin
  if not public.is_owner() then
    raise exception 'إلغاء الأوردر من صلاحية المدير فقط' using errcode = '42501';
  end if;

  select * into v_order from public.orders where id = p_order_id for update;
  if v_order is null then raise exception 'الأوردر غير موجود'; end if;
  if v_order.status in ('delivered', 'cancelled') then
    raise exception 'لا يمكن إلغاء أوردر تم تسليمه أو ملغى بالفعل';
  end if;

  update public.orders set status = 'cancelled', cancelled_at = now(), cancel_reason = p_reason where id = p_order_id;
  perform public.log_order_event(p_order_id, 'cancelled', v_order.status, 'cancelled', p_reason);
  perform public.notify_staff(p_order_id, 'order_cancelled', 'تم إلغاء الأوردر ' || v_order.order_number, p_reason, auth.uid());
end;
$$;

revoke all on function public.owner_cancel_order(uuid, text) from public;
grant execute on function public.owner_cancel_order(uuid, text) to authenticated;
