-- 0031_wider_order_numbers.sql
--
-- "increase zeros in ORD bcs the mass is maybe high... tell me what will
-- happen when reach 9999" —
--
-- What actually happens at 9999 with the old 4-digit lpad: nothing breaks.
-- lpad() only *pads up to* a width, it never truncates — order #10000
-- would simply become "ORD-10000" (5 digits) on its own, #100000 becomes
-- "ORD-100000", and so on forever, with no collision risk either way
-- (uniqueness comes from the sequence, not the digit count). The only real
-- downside is cosmetic: sorting order_number as *text* breaks exactly at
-- that width boundary ("ORD-10000" sorts before "ORD-9999", since '1' <
-- '9') — orders are actually listed by created_at everywhere in this app,
-- never by order_number text, so this was never going to bite functionally
-- either. Still, widening now — while the numbers are still small — means
-- the vast majority of this business's order history stays visually
-- consistent at one width, rather than only the last handful of orders
-- before some future 99999-order milestone looking different from
-- everything before them.
--
-- This only changes new orders going forward — every existing order
-- number is already stored as plain text on its row and is never
-- recomputed, so nothing already printed on a receipt or read out to a
-- customer changes.

create or replace function public.set_order_number()
returns trigger
language plpgsql
as $$
begin
  if new.order_number is null or new.order_number = '' then
    new.order_number := 'ORD-' || lpad(nextval('public.order_number_seq')::text, 5, '0');
  end if;
  return new;
end;
$$;
