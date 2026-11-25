-- =============================================================================
-- Ubicación de entrega en el mapa (solo referencia para el repartidor).
--
-- - El cliente marca un punto en el mapa al pedir a domicilio (opcional). La
--   dirección escrita (colonia, calle, casa, referencia) sigue siendo obligatoria
--   y la escribe el cliente; el mapa NO la llena.
-- - restaurant_settings.delivery_map_enabled: interruptor desde la app (Ajustes).
--   Apagado, la web deja de mostrar el mapa y el servidor ignora el punto.
-- - Cambio aditivo: columnas opcionales y un dato opcional en create_guest_order;
--   una versión anterior de la web o la app sigue funcionando igual.
-- =============================================================================

alter table public.restaurant_settings
  add column if not exists delivery_map_enabled boolean not null default true;

alter table public.orders
  add column if not exists delivery_lat numeric(9, 6),
  add column if not exists delivery_lng numeric(9, 6),
  add column if not exists delivery_accuracy_m integer,
  add column if not exists delivery_location_source text;

alter table public.orders drop constraint if exists orders_delivery_location_chk;
alter table public.orders add constraint orders_delivery_location_chk check (
  (delivery_lat is null and delivery_lng is null and delivery_accuracy_m is null and delivery_location_source is null)
  or (delivery_lat between -90 and 90 and delivery_lng between -180 and 180
      and delivery_location_source in ('GPS', 'MAP')
      and (delivery_accuracy_m is null or delivery_accuracy_m between 0 and 100000)));

-- -----------------------------------------------------------------------------
-- Configuración: se agrega deliveryMapEnabled (público: la web lo necesita).
-- -----------------------------------------------------------------------------
create or replace function public._settings_json(p_full boolean default false)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'name', s.name, 'slug', s.slug, 'tagline', s.tagline, 'phone', s.phone, 'address', s.address,
    'timezone', s.timezone, 'currency', s.currency, 'currencySymbol', s.currency_symbol,
    'isOpen', s.is_open, 'pickupEnabled', s.pickup_enabled, 'deliveryEnabled', s.delivery_enabled,
    'deliveryFee', s.delivery_fee, 'estimatedPrepMinutes', s.estimated_prep_minutes,
    'deliveryMapEnabled', s.delivery_map_enabled,
    'paymentMethods', s.payment_methods,
    'businessHours', coalesce((
      select jsonb_agg(jsonb_build_object(
        'weekday', h.weekday, 'label', h.label,
        'opensAt', to_char(h.opens_at, 'HH24:MI'), 'closesAt', to_char(h.closes_at, 'HH24:MI'),
        'isClosed', h.is_closed) order by h.weekday)
      from public.business_hours h), '[]'::jsonb)
  ) || case when p_full then jsonb_build_object(
    'kitchenDelayMinutes', s.kitchen_delay_minutes,
    'showUnavailableProducts', s.show_unavailable_products
  ) else '{}'::jsonb end
  from public.restaurant_settings s
  where s.id = 1
$$;

create or replace function public.update_settings(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_role public.app_role := public._require_role(array['ADMIN', 'MANAGER']::public.app_role[]);
  v_key text;
  v_allowed text[] := case when v_role = 'ADMIN' then
    array['isOpen', 'pickupEnabled', 'deliveryEnabled', 'deliveryFee', 'estimatedPrepMinutes', 'kitchenDelayMinutes',
          'showUnavailableProducts', 'phone', 'address', 'tagline', 'deliveryMapEnabled']
    else array['isOpen'] end;   -- el encargado solo abre/cierra pedidos
begin
  for v_key in select jsonb_object_keys(params) loop
    if not (v_key = any (v_allowed)) then
      perform public._raise(403, 'FORBIDDEN', 'No puedes cambiar "' || v_key || '".');
    end if;
  end loop;

  update public.restaurant_settings set
    is_open = coalesce((params ->> 'isOpen')::boolean, is_open),
    pickup_enabled = coalesce((params ->> 'pickupEnabled')::boolean, pickup_enabled),
    delivery_enabled = coalesce((params ->> 'deliveryEnabled')::boolean, delivery_enabled),
    delivery_fee = coalesce((params ->> 'deliveryFee')::numeric, delivery_fee),
    estimated_prep_minutes = coalesce((params ->> 'estimatedPrepMinutes')::int, estimated_prep_minutes),
    kitchen_delay_minutes = coalesce((params ->> 'kitchenDelayMinutes')::int, kitchen_delay_minutes),
    show_unavailable_products = coalesce((params ->> 'showUnavailableProducts')::boolean, show_unavailable_products),
    delivery_map_enabled = coalesce((params ->> 'deliveryMapEnabled')::boolean, delivery_map_enabled),
    phone = coalesce(public._clean(params ->> 'phone', 160), phone),
    address = coalesce(public._clean(params ->> 'address', 160), address),
    tagline = coalesce(public._clean(params ->> 'tagline', 160), tagline),
    updated_by = auth.uid()
  where id = 1;
  return public._settings_json(true);
end;
$$;

-- -----------------------------------------------------------------------------
-- create_guest_order: acepta `location` opcional { lat, lng, accuracy?, source }.
-- Un punto inválido o fuera de Honduras se ignora (nunca bloquea el pedido).
-- -----------------------------------------------------------------------------
alter function public.create_guest_order(jsonb) rename to _create_guest_order_scheduled;
revoke execute on function public._create_guest_order_scheduled(jsonb) from public, anon, authenticated;

create or replace function public.create_guest_order(params jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  v_loc jsonb := case when jsonb_typeof(params -> 'location') = 'object' then params -> 'location' end;
  v_lat numeric;
  v_lng numeric;
  v_acc integer;
  v_src text;
  v_result jsonb;
begin
  if v_loc is not null then
    begin
      v_lat := round((v_loc ->> 'lat')::numeric, 6);
      v_lng := round((v_loc ->> 'lng')::numeric, 6);
      v_acc := least(100000, greatest(0, round((v_loc ->> 'accuracy')::numeric)))::integer;
      v_src := upper(coalesce(v_loc ->> 'source', ''));
    exception when others then
      v_lat := null;
    end;
    -- Honduras (con margen; incluye islas).
    if v_lat is null or v_lng is null
       or v_lat not between 12.9 and 17.5 or v_lng not between -89.4 and -83.1
       or v_src not in ('GPS', 'MAP') then
      v_lat := null;
    end if;
  end if;

  v_result := public._create_guest_order_scheduled(params - 'location');

  if v_lat is not null
     and not coalesce((v_result ->> 'replayed')::boolean, false)
     and coalesce(params ->> 'orderType', '') = 'DELIVERY'
     and (select delivery_map_enabled from public.restaurant_settings where id = 1) then
    update public.orders
       set delivery_lat = v_lat, delivery_lng = v_lng, delivery_location_source = v_src,
           delivery_accuracy_m = case when v_src = 'GPS' then v_acc end
     where order_number = v_result ->> 'orderNumber';
  end if;
  return v_result;
end;
$$;

revoke execute on function public.create_guest_order(jsonb) from public;
grant execute on function public.create_guest_order(jsonb) to anon, authenticated;

-- -----------------------------------------------------------------------------
-- Pedido JSON (app): agrega el punto de entrega.
-- -----------------------------------------------------------------------------
create or replace function public._order_json(o public.orders, p_role public.app_role)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select public._order_json_base(o, p_role) || jsonb_build_object(
    'channel', o.channel,
    'createdBy', (select full_name from public.employee_profiles where user_id = o.created_by),
    'deliveryLocation', case when o.delivery_lat is not null then jsonb_build_object(
      'lat', o.delivery_lat, 'lng', o.delivery_lng,
      'accuracy', o.delivery_accuracy_m, 'source', o.delivery_location_source) end)
$$;
revoke execute on function public._order_json(public.orders, public.app_role) from public, anon, authenticated;

notify pgrst, 'reload schema';
