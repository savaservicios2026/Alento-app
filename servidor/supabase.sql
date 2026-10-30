-- Alento Reservas · base de datos en Supabase
-- Pégalo entero en Supabase → SQL Editor → New query y pulsa «Run». Se puede volver a ejecutar sin perder datos.
--
-- Todo el acceso pasa por funciones (rpc) que comprueban quién llama: las tablas tienen RLS activado
-- y ninguna política, así que nadie puede leerlas ni escribirlas directamente desde la app.
-- Preparado para varios centros: cada fila lleva center_id.

-- ---------- tablas ----------
create table if not exists centers (
  id text primary key,
  name text not null,
  cfg jsonb not null default '{}',          -- cupo, lista de espera, horas para cancelar, unidad
  week jsonb not null default '{}',         -- plantilla semanal: {"1":[["08:00","Reformer","laura","Inicial",8],...],...}
  test_payments boolean not null default true,  -- true: los pagos de la app son de prueba y suman clases
  created_at timestamptz not null default now()
);

create table if not exists profiles (
  id uuid primary key default gen_random_uuid(),
  auth_id uuid unique references auth.users(id) on delete set null,
  center_id text not null references centers(id),
  role text not null default 'socio' check (role in ('socio','admin')),
  email text not null default '',
  ficha jsonb not null default '{}',
  credits int not null default 0 check (credits >= 0),
  wallet jsonb not null default '{"cards":[],"iban":null}',
  subs jsonb,
  created_at timestamptz not null default now()
);
create unique index if not exists profiles_email on profiles (center_id, lower(email)) where email <> '';

create table if not exists classes (
  id uuid primary key default gen_random_uuid(),
  center_id text not null references centers(id),
  date date not null,
  time text not null,
  type text not null,
  instr text not null default '',
  level text not null default '',
  cap int not null default 8,
  starts_at timestamptz not null,
  unique (center_id, date, time, type)
);

create table if not exists bookings (
  class_id uuid not null references classes(id) on delete cascade,
  profile_id uuid not null references profiles(id) on delete cascade,
  status text not null check (status in ('booked','wait')),
  attended boolean not null default false,
  created_at timestamptz not null default clock_timestamp(),
  primary key (class_id, profile_id)
);

create table if not exists notifs (
  id bigserial primary key,
  center_id text not null references centers(id),
  profile_id uuid references profiles(id) on delete cascade,
  to_admin boolean not null default false,
  text text not null,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists messages (
  id bigserial primary key,
  center_id text not null references centers(id),
  thread uuid not null references profiles(id) on delete cascade,
  from_center boolean not null,
  text text not null,
  kind text not null default 'chat',
  cat text,
  read boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists payments (
  id bigserial primary key,
  center_id text not null references centers(id),
  profile_id uuid references profiles(id) on delete set null,
  concept text not null,
  amount numeric(10,2) not null,
  method text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists access_logs (
  id bigserial primary key,
  center_id text not null references centers(id),
  profile_id uuid references profiles(id) on delete set null,
  ok boolean not null,
  title text not null,
  manual boolean not null default false,
  created_at timestamptz not null default now()
);

do $$ declare t text; begin
  foreach t in array array['centers','profiles','classes','bookings','notifs','messages','payments','access_logs'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
  end loop;
end $$;

-- ---------- utilidades ----------
create or replace function me_profile() returns profiles
language sql stable security definer set search_path = public as $$
  select * from profiles where auth_id = auth.uid() limit 1
$$;

create or replace function ms(t timestamptz) returns bigint
language sql immutable as $$ select (extract(epoch from t) * 1000)::bigint $$;

create or replace function today_es() returns date
language sql stable as $$ select (now() at time zone 'Europe/Madrid')::date $$;

-- Crea las clases de los próximos 14 días a partir de la plantilla semanal del centro.
create or replace function ensure_classes(p_center text) returns void
language plpgsql security definer set search_path = public as $$
declare w jsonb; d date; e jsonb;
begin
  select week into w from centers where id = p_center;
  if w is null or w = '{}'::jsonb then return; end if;
  for i in 0..13 loop
    d := today_es() + i;
    for e in select * from jsonb_array_elements(coalesce(w -> (extract(dow from d)::int)::text, '[]'::jsonb)) loop
      insert into classes (center_id, date, time, type, instr, level, cap, starts_at)
      values (p_center, d, e->>0, e->>1, coalesce(e->>2,''), coalesce(e->>3,''), coalesce((e->>4)::int, 8),
              (d + (e->>0)::time) at time zone 'Europe/Madrid')
      on conflict (center_id, date, time, type) do nothing;
    end loop;
  end loop;
end $$;

-- Quien se registra en la app: si recepción ya le dio de alta con ese email, se enlaza; si no, se crea su ficha.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare cid text := coalesce(new.raw_user_meta_data->>'center', 'alento'); pid uuid;
begin
  if not exists (select 1 from centers where id = cid) then return new; end if;
  update profiles set auth_id = new.id
   where center_id = cid and lower(email) = lower(new.email) and auth_id is null
  returning id into pid;
  if pid is null then
    insert into profiles (auth_id, center_id, email, ficha)
    values (new.id, cid, lower(new.email), jsonb_build_object(
      'nombre', coalesce(new.raw_user_meta_data->>'nombre', ''),
      'apellidos', coalesce(new.raw_user_meta_data->>'apellidos', ''),
      'email', new.email, 'alta', ms(now()), 'origen', 'App'));
  end if;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

create or replace function notify_user(p_center text, p_profile uuid, p_text text) returns void
language sql security definer set search_path = public as $$
  insert into notifs (center_id, profile_id, text) values (p_center, p_profile, p_text)
$$;

create or replace function class_label(k classes) returns text
language sql immutable as $$ select k.type || ' del ' || to_char(k.date, 'DD/MM') || ' a las ' || k.time $$;

-- ---------- lectura: todo lo que la app necesita en una sola llamada ----------
create or replace function hydrate() returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; c centers; adm boolean;
begin
  p := me_profile();
  if p.id is null then return jsonb_build_object('profile', null); end if;
  select * into c from centers where id = p.center_id;
  perform ensure_classes(c.id);
  adm := p.role = 'admin';
  return jsonb_build_object(
    'profile', jsonb_build_object('id', p.id, 'role', p.role, 'email', p.email, 'credits', p.credits, 'wallet', p.wallet, 'subs', p.subs, 'ficha', p.ficha),
    'center', jsonb_build_object('id', c.id, 'name', c.name, 'cfg', c.cfg, 'week', c.week, 'test_payments', c.test_payments),
    'classes', (select coalesce(jsonb_agg(t.j order by t.d, t.tm), '[]'::jsonb) from (
      select k.date d, k.time tm, jsonb_build_object(
        'id', k.id, 'date', k.date, 'time', k.time, 'type', k.type, 'instr', k.instr, 'level', k.level, 'cap', k.cap,
        'booked', case when adm then (select coalesce(jsonb_agg(b.profile_id order by b.created_at), '[]'::jsonb) from bookings b where b.class_id = k.id and b.status = 'booked') end,
        'wait',   case when adm then (select coalesce(jsonb_agg(b.profile_id order by b.created_at), '[]'::jsonb) from bookings b where b.class_id = k.id and b.status = 'wait') end,
        'attended', case when adm then (select coalesce(jsonb_agg(b.profile_id), '[]'::jsonb) from bookings b where b.class_id = k.id and b.attended) end,
        'nb', (select count(*) from bookings b where b.class_id = k.id and b.status = 'booked'),
        'nw', (select count(*) from bookings b where b.class_id = k.id and b.status = 'wait'),
        'mine', (select b.status from bookings b where b.class_id = k.id and b.profile_id = p.id),
        'pos', (select count(*) from bookings b where b.class_id = k.id and b.status = 'wait'
                 and b.created_at <= (select m.created_at from bookings m where m.class_id = k.id and m.profile_id = p.id and m.status = 'wait'))
      ) j from classes k where k.center_id = c.id and k.date between today_es() - 1 and today_es() + 14) t),
    'clients', (select coalesce(jsonb_object_agg(x.id, x.ficha || jsonb_build_object('_credits', x.credits, '_cuenta', x.auth_id is not null, '_subs', x.subs)), '{}'::jsonb)
                from profiles x where x.center_id = c.id and x.role = 'socio' and (adm or x.id = p.id)),
    'messages', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'thread', m.thread, 'from_center', m.from_center, 'text', m.text, 'kind', m.kind, 'cat', m.cat, 'read', m.read, 'ts', ms(m.created_at)) order by m.created_at), '[]'::jsonb)
                 from messages m where m.center_id = c.id and (adm or m.thread = p.id) and m.created_at > now() - interval '120 days'),
    'notifs', (select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'text', n.text, 'read', n.read, 'ts', ms(n.created_at)) order by n.created_at desc), '[]'::jsonb)
               from (select * from notifs n where n.center_id = c.id and (case when adm then n.to_admin else n.profile_id = p.id end) order by n.created_at desc limit 80) n),
    'payments', (select coalesce(jsonb_agg(jsonb_build_object('id', y.id, 'uid', y.profile_id, 'concept', y.concept, 'amount', y.amount, 'method', y.method, 'ts', ms(y.created_at))), '[]'::jsonb)
                 from payments y where y.center_id = c.id and (adm or y.profile_id = p.id)),
    'access', case when adm then (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'uid', a.profile_id, 'ok', a.ok, 'title', a.title, 'manual', a.manual, 'ts', ms(a.created_at)) order by a.created_at desc), '[]'::jsonb)
                 from access_logs a where a.center_id = c.id and a.created_at > now() - interval '2 days') else '[]'::jsonb end
  );
end $$;

-- ---------- reservas ----------
-- Pasa a los de la lista de espera mientras haya plaza. Sin clases en el bono, la plaza pasa al siguiente.
create or replace function promote(p_class uuid) returns void
language plpgsql security definer set search_path = public as $$
declare k classes; nb int; w bookings; cr int; unit text; i int := 0;
begin
  select * into k from classes where id = p_class;
  select coalesce(cfg->>'unit', 'clase') into unit from centers where id = k.center_id;
  loop
    select count(*) into nb from bookings where class_id = k.id and status = 'booked';
    exit when nb >= k.cap;
    select * into w from bookings where class_id = k.id and status = 'wait' order by created_at limit 1;
    exit when not found;
    select credits into cr from profiles where id = w.profile_id for update;
    if cr >= 1 then
      update bookings set status = 'booked' where class_id = k.id and profile_id = w.profile_id;
      update profiles set credits = credits - 1 where id = w.profile_id;
      perform notify_user(k.center_id, w.profile_id, 'Se ha liberado una plaza y ya la tienes: ' || class_label(k) || '. Se ha descontado 1 ' || unit || ' de tu bono.');
    else
      delete from bookings where class_id = k.id and profile_id = w.profile_id;
      perform notify_user(k.center_id, w.profile_id, 'Se liberó una plaza en ' || class_label(k) || ', pero no te quedaban ' || unit || 's en el bono y pasó a la siguiente persona.');
    end if;
  end loop;
  for w in select * from bookings where class_id = k.id and status = 'wait' order by created_at loop
    i := i + 1;
    perform notify_user(k.center_id, w.profile_id, 'Subes al puesto ' || i || '.º de la lista de espera de ' || class_label(k) || '.');
  end loop;
end $$;

create or replace function book_class(p_class uuid) returns text
language plpgsql security definer set search_path = public as $$
declare p profiles; k classes; nb int; nw int; waitmax int;
begin
  p := me_profile();
  if p.id is null then raise exception 'NO_SESSION'; end if;
  select * into k from classes where id = p_class and center_id = p.center_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if k.starts_at <= now() then raise exception 'STARTED'; end if;
  if exists (select 1 from bookings where class_id = k.id and profile_id = p.id) then raise exception 'ALREADY'; end if;
  select coalesce((cfg->>'wait')::int, 2) into waitmax from centers where id = p.center_id;
  select credits into p.credits from profiles where id = p.id for update;
  if p.credits < 1 then raise exception 'NO_CREDITS'; end if;
  select count(*) filter (where status = 'booked'), count(*) filter (where status = 'wait') into nb, nw from bookings where class_id = k.id;
  if nb < k.cap then
    insert into bookings (class_id, profile_id, status) values (k.id, p.id, 'booked');
    update profiles set credits = credits - 1 where id = p.id;
    return 'booked';
  elsif nw < waitmax then
    insert into bookings (class_id, profile_id, status) values (k.id, p.id, 'wait');
    return 'wait:' || (nw + 1);
  end if;
  raise exception 'FULL';
end $$;

create or replace function cancel_booking(p_class uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare p profiles; k classes; b bookings; hours int; refund boolean := false;
begin
  p := me_profile();
  if p.id is null then raise exception 'NO_SESSION'; end if;
  select * into k from classes where id = p_class and center_id = p.center_id for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  select * into b from bookings where class_id = k.id and profile_id = p.id;
  if not found then return jsonb_build_object('refund', false); end if;
  delete from bookings where class_id = k.id and profile_id = p.id;
  if b.status = 'booked' then
    select coalesce((cfg->>'cancel')::int, 12) into hours from centers where id = p.center_id;
    refund := k.starts_at - now() >= make_interval(hours => hours);
    if refund then update profiles set credits = credits + 1 where id = p.id; end if;
    perform promote(k.id);
  end if;
  return jsonb_build_object('refund', refund);
end $$;

-- ---------- pagos de prueba ----------
create or replace function buy_plan(p_plan text, p_method text) returns int
language plpgsql security definer set search_path = public as $$
declare p profiles; c centers; n int; price numeric; pname text; rec boolean := false; unit text;
begin
  p := me_profile();
  if p.id is null then raise exception 'NO_SESSION'; end if;
  select * into c from centers where id = p.center_id;
  if not c.test_payments then raise exception 'PAYMENTS_OFF'; end if;
  select x.n, x.price, x.name, x.rec into n, price, pname, rec from (values
    ('p1', 1, 16, 'Clase suelta', false), ('p4', 4, 54, 'Bono 4', false), ('p8', 8, 98, 'Bono 8', false),
    ('p12', 12, 132, 'Bono 12', false), ('m8', 8, 89, 'Cuota mensual', true)) as x(id, n, price, name, rec)
  where x.id = p_plan;
  if n is null then raise exception 'NOT_FOUND'; end if;
  unit := coalesce(c.cfg->>'unit', 'clase');
  update profiles set credits = credits + n,
    subs = case when rec then jsonb_build_object('plan', p_plan, 'since', ms(now()), 'next', ms(date_trunc('month', now()) + interval '1 month'), 'method', p_method) else subs end
  where id = p.id returning credits into n;
  insert into payments (center_id, profile_id, concept, amount, method)
  values (c.id, p.id, case when rec then pname || ' (primer mes)' else pname end, price, p_method);
  perform notify_user(c.id, p.id, 'Pago recibido: ' || pname || ' (' || price || ' €). Se han añadido clases a tu bono.');
  return n;
end $$;

-- ---------- escrituras sueltas de la app (mensajes, avisos, fichas, lecturas…) ----------
-- Devuelve los id nuevos en el mismo orden en que llegan.
create or replace function push(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me profiles; adm boolean; x jsonb; uid uuid; ids_m jsonb := '[]'; ids_n jsonb := '[]'; ids_p jsonb := '[]'; ids_a jsonb := '[]'; nid bigint; k text;
begin
  me := me_profile();
  if me.id is null then raise exception 'NO_SESSION'; end if;
  adm := me.role = 'admin';

  for x in select * from jsonb_array_elements(coalesce(p->'msgs', '[]')) loop
    uid := (x->>'thread')::uuid;
    if adm then
      if not exists (select 1 from profiles where id = uid and center_id = me.center_id) then raise exception 'FORBIDDEN'; end if;
    elsif uid <> me.id or (x->>'from_center')::boolean then raise exception 'FORBIDDEN'; end if;
    insert into messages (center_id, thread, from_center, text, kind, cat)
    values (me.center_id, uid, adm and (x->>'from_center')::boolean, left(x->>'text', 4000), coalesce(x->>'kind', 'chat'), x->>'cat')
    returning id into nid;
    ids_m := ids_m || to_jsonb(nid);
  end loop;

  for x in select * from jsonb_array_elements(coalesce(p->'notifs', '[]')) loop
    if x->>'uid' = 'admin' then
      insert into notifs (center_id, to_admin, text) values (me.center_id, true, left(x->>'text', 1000)) returning id into nid;
    else
      uid := (x->>'uid')::uuid;
      if not (uid = me.id or (adm and exists (select 1 from profiles where id = uid and center_id = me.center_id))) then raise exception 'FORBIDDEN'; end if;
      insert into notifs (center_id, profile_id, text) values (me.center_id, uid, left(x->>'text', 1000)) returning id into nid;
    end if;
    ids_n := ids_n || to_jsonb(nid);
  end loop;

  -- Pedidos de la tienda (pago de prueba o en recepción). No suman clases.
  for x in select * from jsonb_array_elements(coalesce(p->'payments', '[]')) loop
    insert into payments (center_id, profile_id, concept, amount, method)
    values (me.center_id, me.id, left(x->>'concept', 200), (x->>'amount')::numeric, left(coalesce(x->>'method', ''), 100))
    returning id into nid;
    ids_p := ids_p || to_jsonb(nid);
  end loop;

  if adm then
    for x in select * from jsonb_array_elements(coalesce(p->'access', '[]')) loop
      insert into access_logs (center_id, profile_id, ok, title, manual)
      values (me.center_id, nullif(x->>'uid', '')::uuid, (x->>'ok')::boolean, left(x->>'title', 300), coalesce((x->>'manual')::boolean, false))
      returning id into nid;
      ids_a := ids_a || to_jsonb(nid);
    end loop;
    for x in select * from jsonb_array_elements(coalesce(p->'attended', '[]')) loop
      update bookings b set attended = true from classes k
       where b.class_id = (x->>'cls')::uuid and b.profile_id = (x->>'uid')::uuid and k.id = b.class_id and k.center_id = me.center_id;
    end loop;
  end if;

  update messages set read = true where id in (select (v #>> '{}')::bigint from jsonb_array_elements(coalesce(p->'read_msgs', '[]')) v)
    and center_id = me.center_id and (case when adm then not from_center else thread = me.id and from_center end);
  update notifs set read = true where id in (select (v #>> '{}')::bigint from jsonb_array_elements(coalesce(p->'read_notifs', '[]')) v)
    and center_id = me.center_id and (case when adm then to_admin else profile_id = me.id end);

  -- Fichas: cada socio la suya; recepción, las de su centro.
  for k, x in select * from jsonb_each(coalesce(p->'fichas', '{}')) loop
    uid := k::uuid;
    if not (uid = me.id or adm) then raise exception 'FORBIDDEN'; end if;
    update profiles set ficha = x - '_credits' - '_cuenta' - '_subs',
      email = case when x ? 'email' then lower(coalesce(x->>'email', '')) else email end
     where id = uid and center_id = me.center_id and role = 'socio';
  end loop;

  if p ? 'wallet' then update profiles set wallet = p->'wallet' where id = me.id; end if;
  if p ? 'subs' then update profiles set subs = case when jsonb_typeof(p->'subs') = 'null' then null else p->'subs' end where id = me.id; end if;

  return jsonb_build_object('msgs', ids_m, 'notifs', ids_n, 'payments', ids_p, 'access', ids_a);
end $$;

-- ---------- solo recepción ----------
create or replace function require_admin() returns profiles
language plpgsql stable security definer set search_path = public as $$
declare p profiles;
begin
  p := me_profile();
  if p.id is null or p.role <> 'admin' then raise exception 'FORBIDDEN'; end if;
  return p;
end $$;

-- Alta en recepción: crea la ficha sin cuenta; cuando el cliente se registre con ese email, se enlaza.
create or replace function admin_create_client(p_ficha jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare a profiles; pid uuid;
begin
  a := require_admin();
  insert into profiles (center_id, email, ficha) values (a.center_id, lower(coalesce(p_ficha->>'email', '')), p_ficha) returning id into pid;
  return pid;
end $$;

create or replace function admin_add_credits(p_uid uuid, p_n int, p_amount numeric, p_method text, p_concept text) returns int
language plpgsql security definer set search_path = public as $$
declare a profiles; n int;
begin
  a := require_admin();
  update profiles set credits = greatest(0, credits + p_n) where id = p_uid and center_id = a.center_id returning credits into n;
  if n is null then raise exception 'NOT_FOUND'; end if;
  if p_amount > 0 then insert into payments (center_id, profile_id, concept, amount, method) values (a.center_id, p_uid, p_concept, p_amount, p_method); end if;
  if p_n > 0 then perform notify_user(a.center_id, p_uid, 'Recepción ha añadido ' || p_n || ' a tu bono. Ya tienes ' || n || '.'); end if;
  return n;
end $$;

-- Baja y anonimización: cancela sus reservas (pasando la plaza a la lista de espera), borra mensajes y avisos
-- y desvincula la cuenta. La ficha anonimizada la guarda la app con push().
create or replace function admin_baja(p_uid uuid) returns void
language plpgsql security definer set search_path = public as $$
declare a profiles; b record;
begin
  a := require_admin();
  if not exists (select 1 from profiles where id = p_uid and center_id = a.center_id and role = 'socio') then raise exception 'NOT_FOUND'; end if;
  for b in select bk.class_id, bk.status from bookings bk join classes k on k.id = bk.class_id where bk.profile_id = p_uid and k.starts_at > now() loop
    delete from bookings where class_id = b.class_id and profile_id = p_uid;
    if b.status = 'booked' then perform promote(b.class_id); end if;
  end loop;
  delete from messages where thread = p_uid;
  delete from notifs where profile_id = p_uid;
  update profiles set auth_id = null, email = '', credits = 0, wallet = '{"cards":[],"iban":null}', subs = null where id = p_uid;
end $$;

-- Ajustes del centro y plantilla semanal. Las clases futuras sin reservas se regeneran; a las demás se les ajusta el cupo.
create or replace function save_config(p_name text, p_cfg jsonb, p_week jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare a profiles;
begin
  a := require_admin();
  update centers set name = coalesce(nullif(p_name, ''), name), cfg = p_cfg, week = p_week where id = a.center_id;
  delete from classes k where k.center_id = a.center_id and k.starts_at > now()
    and not exists (select 1 from bookings b where b.class_id = k.id);
  perform ensure_classes(a.center_id);
  update classes k set cap = coalesce((select (e->>4)::int from jsonb_array_elements(p_week -> (extract(dow from k.date)::int)::text) e
                                        where e->>0 = k.time and e->>1 = k.type limit 1), k.cap)
   where k.center_id = a.center_id and k.starts_at > now();
end $$;

-- Solo las funciones públicas de la app se pueden llamar desde fuera.
do $$ declare f text; begin
  foreach f in array array['me_profile()','ensure_classes(text)','notify_user(text,uuid,text)','promote(uuid)','require_admin()','handle_new_user()'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  foreach f in array array['hydrate()','book_class(uuid)','cancel_booking(uuid)','buy_plan(text,text)','push(jsonb)',
                           'admin_create_client(jsonb)','admin_add_credits(uuid,int,numeric,text,text)','admin_baja(uuid)','save_config(text,jsonb,jsonb)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- ---------- el centro ----------
insert into centers (id, name, cfg) values ('alento', 'Alento', '{"cap":8,"wait":2,"cancel":12,"unit":"clase","sector":"pilates"}')
on conflict (id) do nothing;

-- DESPUÉS de crear tu cuenta en la app, conviértete en recepción cambiando el email y ejecutando solo esta línea:
-- update profiles set role = 'admin' where lower(email) = lower('TU_EMAIL@ejemplo.com');
