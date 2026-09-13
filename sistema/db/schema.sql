-- =============================================================================
-- El Cielo Adventures · Sistema de leads, embudo, reservaciones y eventos
-- Esquema para PostgreSQL 14+ (probado en 16; pensado para Supabase).
-- Ejecutar una sola vez en una base vacía:  psql "$DATABASE_URL" -f schema.sql
-- Después: cargar los pasos del embudo (migracion/salida/seed_pasos_embudo.sql)
-- y, si aplica, los datos del Excel con cargar_csv.sql.
-- =============================================================================

create extension if not exists pgcrypto;   -- gen_random_uuid()

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
create type destino_t as enum ('San José', 'Gómez Farías', 'Camping', 'Tours', 'Evento', 'Sin definir');
create type estado_lead_t as enum ('activo', 'reservo', 'cancelado', 'archivado');
create type origen_t as enum ('Anuncio Meta', 'Facebook / Instagram', 'Sitio web', 'Google', 'Recomendación', 'Airbnb', 'Otro');
create type canal_t as enum ('whatsapp', 'llamada', 'messenger', 'presencial', 'otro');
create type tipo_seguimiento_t as enum ('envio', 'respuesta', 'nota', 'cambio', 'migracion');
create type estado_reserva_t as enum ('apartada', 'liquidada', 'completada', 'cancelada');
create type tipo_pago_t as enum ('anticipo', 'liquidacion', 'transporte', 'evento', 'otro');
create type momento_t as enum ('antes', 'durante', 'despues');

-- -----------------------------------------------------------------------------
-- Catálogos
-- -----------------------------------------------------------------------------
create table cabanas (
  id            serial primary key,
  nombre        text not null unique,
  ubicacion     destino_t not null,
  capacidad     int,
  precio_base   numeric(10,2),
  activa        boolean not null default true
);

-- El embudo vuelto datos: cada paso sabe qué mensaje lleva, cuánto esperar y a
-- dónde mover al lead según conteste o no. "A|B" = A si va a Gómez Farías, B si
-- va a San José. Se edita desde la aplicación sin tocar código.
create table pasos_embudo (
  codigo                    text primary key,
  nombre                    text not null,
  plantilla                 text,
  dias_espera               int not null default 1 check (dias_espera >= 0),
  dias_habiles              boolean not null default false,
  siguiente_si_contesta     text,
  siguiente_si_no_contesta  text,
  es_final                  boolean not null default false,
  cierra_como               estado_lead_t,
  orden                     int not null default 0,
  activo                    boolean not null default true,
  check (not es_final or cierra_como is not null)
);

create table checklist_catalogo (
  id      serial primary key,
  momento momento_t not null,
  tarea   text not null,
  orden   int not null default 0,
  activo  boolean not null default true
);

-- -----------------------------------------------------------------------------
-- Leads y seguimiento
-- -----------------------------------------------------------------------------
create table leads (
  id               uuid primary key default gen_random_uuid(),
  lada_pais        text not null default '52',
  celular          text not null check (celular ~ '^[0-9]{10}$'),
  nombre           text,
  destino          destino_t not null default 'Sin definir',
  interes_tours    boolean not null default false,
  mes_viaje        text,
  personas         int,
  noches           int,
  monto_cotizado   numeric(10,2),
  origen           origen_t not null default 'Otro',
  paso_actual      text references pasos_embudo (codigo),
  paso_original    text,                       -- código que traía en el Excel
  fecha_paso       date,                       -- último cambio de paso
  proxima_fecha    date,                       -- cuándo toca la siguiente acción
  enviado          boolean not null default false,  -- ¿ya se mandó el mensaje del paso actual?
  estado           estado_lead_t not null default 'activo',
  comentarios      text,
  atiende          text,                       -- quién lo lleva
  referencia_excel text,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now(),
  unique (lada_pais, celular),
  check (estado <> 'activo' or paso_actual is not null)
);
create index leads_pendientes_idx on leads (proxima_fecha) where estado = 'activo';
create index leads_destino_idx on leads (destino, estado);

create table seguimientos (
  id        bigserial primary key,
  lead_id   uuid not null references leads (id) on delete cascade,
  fecha     timestamptz not null default now(),
  tipo      tipo_seguimiento_t not null default 'nota',
  paso      text references pasos_embudo (codigo),
  contesto  boolean,
  canal     canal_t not null default 'whatsapp',
  nota      text,
  usuario   text
);
create index seguimientos_lead_idx on seguimientos (lead_id, fecha desc);
create index seguimientos_fecha_idx on seguimientos (fecha);

-- -----------------------------------------------------------------------------
-- Reservaciones
-- -----------------------------------------------------------------------------
create table reservaciones (
  id                uuid primary key default gen_random_uuid(),
  lead_id           uuid references leads (id) on delete set null,
  cabana_id         int references cabanas (id),
  nombre            text not null,
  lada_pais         text not null default '52',
  celular           text check (celular ~ '^[0-9]{10}$'),
  personas          int,
  fecha_llegada     date,
  fecha_salida      date,
  fechas_texto      text,        -- solo para lo migrado sin fecha exacta ("19 y 20")
  hora_llegada      text,
  total             numeric(10,2),
  ocupa_transporte  boolean,
  estado_transporte text,
  limpieza_rapida   boolean,
  dias_limpiar      int,
  estado            estado_reserva_t not null default 'apartada',
  comentarios       text,
  referencia_excel  text,
  creado_en         timestamptz not null default now(),
  check (fecha_salida is null or fecha_llegada is null or fecha_salida >= fecha_llegada)
);
create index reservaciones_fechas_idx on reservaciones (cabana_id, fecha_llegada, fecha_salida);

create table gastos_reserva (
  id              bigserial primary key,
  reservacion_id  uuid not null references reservaciones (id) on delete cascade,
  concepto        text not null,
  monto           numeric(10,2) not null check (monto >= 0),
  fecha           date not null default current_date
);

create table checklist_reserva (
  reservacion_id  uuid not null references reservaciones (id) on delete cascade,
  catalogo_id     int not null references checklist_catalogo (id),
  hecho           boolean not null default false,
  hecho_en        timestamptz,
  hecho_por       text,
  primary key (reservacion_id, catalogo_id)
);

-- -----------------------------------------------------------------------------
-- Eventos
-- -----------------------------------------------------------------------------
create table eventos (
  id                        serial primary key,
  nombre                    text not null unique,
  fecha                     date,
  mes                       text,
  lugar                     destino_t not null default 'San José',
  fecha_publicacion         date,
  incluye                   text,
  costo                     numeric(10,2),
  precio_publico            numeric(10,2),
  cupo                      int,
  respuesta_predeterminada  text,
  notas                     text,
  estado                    text not null default 'planeado'
                            check (estado in ('idea', 'planeado', 'publicado', 'realizado', 'cancelado'))
);

create table inscripciones (
  id                bigserial primary key,
  evento_id         int not null references eventos (id) on delete cascade,
  lead_id           uuid references leads (id) on delete set null,
  nombre            text not null,
  lada_pais         text not null default '52',
  celular           text check (celular ~ '^[0-9]{10}$'),
  precio            numeric(10,2) not null default 0,   -- lo que debe pagar en total
  fecha_inscripcion date not null default current_date,
  alojamiento       text,
  paga_alojamiento  boolean,
  monto_alojamiento numeric(10,2),
  cuenta            text,                               -- a qué cuenta pagó
  comentarios       text,
  referencia_excel  text
);

-- -----------------------------------------------------------------------------
-- Pagos (de reservaciones o de inscripciones a eventos)
-- -----------------------------------------------------------------------------
create table pagos (
  id              bigserial primary key,
  reservacion_id  uuid references reservaciones (id) on delete cascade,
  inscripcion_id  bigint references inscripciones (id) on delete cascade,
  fecha           date not null default current_date,
  monto           numeric(10,2) not null check (monto > 0),
  tipo            tipo_pago_t not null default 'anticipo',
  metodo          text,
  cuenta          text,
  nota            text,
  check ((reservacion_id is null) <> (inscripcion_id is null))
);
create index pagos_reserva_idx on pagos (reservacion_id);
create index pagos_inscripcion_idx on pagos (inscripcion_id);

-- -----------------------------------------------------------------------------
-- Metas SMART (hoja "Hoja 7")
-- -----------------------------------------------------------------------------
create table metas (
  id          serial primary key,
  objetivo    text not null,
  indicador   text not null check (indicador in ('reservas', 'resenas', 'eventos', 'leads', 'ingresos')),
  mes         date not null,          -- primer día del mes
  valor_meta  numeric not null,
  unique (indicador, mes)
);

-- =============================================================================
-- Funciones: el motor del embudo
-- =============================================================================

-- Suma días naturales o hábiles (lunes a viernes).
create or replace function sumar_dias(p_desde date, p_dias int, p_habiles boolean)
returns date language plpgsql immutable as $$
declare d date := p_desde; n int := 0;
begin
  if not p_habiles then
    return p_desde + p_dias;
  end if;
  while n < p_dias loop
    d := d + 1;
    if extract(isodow from d) < 6 then n := n + 1; end if;
  end loop;
  return d;
end $$;

-- Deja un celular en 10 dígitos y devuelve (lada, número). Acepta +52, 521, espacios, guiones.
create or replace function normalizar_celular(p_texto text, out lada_pais text, out celular text)
language plpgsql immutable as $$
declare d text := regexp_replace(coalesce(p_texto, ''), '\D', '', 'g');
begin
  if length(d) = 13 and left(d, 3) = '521' then lada_pais := '52'; celular := substr(d, 4);
  elsif length(d) = 12 and left(d, 2) = '52' then lada_pais := '52'; celular := substr(d, 3);
  elsif length(d) = 11 and left(d, 1) = '1' then lada_pais := '1'; celular := substr(d, 2);
  elsif length(d) = 10 then lada_pais := '52'; celular := d;
  else raise exception 'Celular no válido: %', p_texto using errcode = 'check_violation';
  end if;
end $$;

-- Resuelve la regla "A|B" según el destino del lead.
create or replace function resolver_paso(p_codigo text, p_destino destino_t)
returns text language sql immutable as $$
  select case
    when p_codigo is null then null
    when position('|' in p_codigo) = 0 then p_codigo
    when p_destino = 'San José' then split_part(p_codigo, '|', 2)
    else split_part(p_codigo, '|', 1)
  end
$$;

create or replace function siguiente_paso(p_actual text, p_contesto boolean, p_destino destino_t)
returns text language sql stable as $$
  select resolver_paso(case when p_contesto then siguiente_si_contesta else siguiente_si_no_contesta end, p_destino)
  from pasos_embudo where codigo = p_actual
$$;

-- Registra un lead nuevo en el paso 1 para atenderse hoy. Si el celular ya
-- existe: lo reactiva si estaba archivado o cancelado; si está activo o ya
-- reservó, solo anota que volvió a escribir.
create or replace function registrar_lead(
  p_celular text, p_destino destino_t default 'Sin definir', p_nombre text default null,
  p_origen origen_t default 'Otro', p_personas int default null, p_noches int default null,
  p_mes text default null, p_comentarios text default null, p_usuario text default null)
returns leads language plpgsql as $$
declare tel record; l leads;
begin
  tel := normalizar_celular(p_celular);
  select * into l from leads where lada_pais = tel.lada_pais and celular = tel.celular for update;
  if not found then
    insert into leads (lada_pais, celular, nombre, destino, origen, personas, noches, mes_viaje, comentarios,
                       paso_actual, fecha_paso, proxima_fecha, enviado, estado, atiende)
    values (tel.lada_pais, tel.celular, p_nombre, p_destino, p_origen, p_personas, p_noches, p_mes, p_comentarios,
            '1', current_date, current_date, false, 'activo', p_usuario)
    returning * into l;
    insert into seguimientos (lead_id, tipo, paso, nota, usuario) values (l.id, 'cambio', '1', 'Lead registrado', p_usuario);
    return l;
  end if;
  if l.estado in ('archivado', 'cancelado') then
    update leads set estado = 'activo', paso_actual = '1', fecha_paso = current_date, proxima_fecha = current_date,
      enviado = false, destino = case when p_destino = 'Sin definir' then destino else p_destino end,
      nombre = coalesce(p_nombre, nombre), personas = coalesce(p_personas, personas),
      noches = coalesce(p_noches, noches), mes_viaje = coalesce(p_mes, mes_viaje),
      comentarios = concat_ws(' / ', comentarios, p_comentarios), actualizado_en = now()
    where id = l.id returning * into l;
    insert into seguimientos (lead_id, tipo, paso, nota, usuario) values (l.id, 'cambio', '1', 'Lead reactivado', p_usuario);
  else
    insert into seguimientos (lead_id, tipo, nota, usuario) values (l.id, 'nota', coalesce(p_comentarios, 'Volvió a escribir'), p_usuario);
  end if;
  return l;
end $$;

-- Acción principal del día a día.
--   avanzar_lead(id)          -> "ya mandé el mensaje del paso actual": programa la siguiente revisión.
--   avanzar_lead(id, true)    -> contestó: pasa al siguiente paso y se le envía ese mensaje ahora.
--   avanzar_lead(id, false)   -> no contestó: pasa al paso de recuperación y se envía ahora.
create or replace function avanzar_lead(p_lead uuid, p_contesto boolean default null,
                                        p_nota text default null, p_usuario text default null)
returns leads language plpgsql as $$
declare l leads; p pasos_embudo; sig text; sp pasos_embudo;
begin
  select * into l from leads where id = p_lead for update;
  if not found then raise exception 'El lead % no existe', p_lead; end if;
  if l.estado <> 'activo' then raise exception 'El lead no está activo (estado: %)', l.estado; end if;
  select * into p from pasos_embudo where codigo = l.paso_actual;

  if p_contesto is null then
    insert into seguimientos (lead_id, tipo, paso, nota, usuario) values (l.id, 'envio', l.paso_actual, p_nota, p_usuario);
    update leads set enviado = true, fecha_paso = current_date,
      proxima_fecha = sumar_dias(current_date, p.dias_espera, p.dias_habiles), actualizado_en = now()
    where id = l.id returning * into l;
    return l;
  end if;

  insert into seguimientos (lead_id, tipo, paso, contesto, nota, usuario)
  values (l.id, 'respuesta', l.paso_actual, p_contesto, p_nota, p_usuario);
  sig := siguiente_paso(l.paso_actual, p_contesto, l.destino);
  if sig is null then
    raise exception 'El paso % no define a dónde ir cuando contesto=%', l.paso_actual, p_contesto;
  end if;
  select * into sp from pasos_embudo where codigo = sig;
  if not found then raise exception 'El paso siguiente % no existe', sig; end if;

  if sp.es_final then
    update leads set paso_actual = sig, fecha_paso = current_date, proxima_fecha = null, enviado = true,
      estado = sp.cierra_como, actualizado_en = now()
    where id = l.id returning * into l;
    insert into seguimientos (lead_id, tipo, paso, nota, usuario)
    values (l.id, 'cambio', sig, 'Cerrado como ' || sp.cierra_como, p_usuario);
  else
    update leads set paso_actual = sig, fecha_paso = current_date, enviado = true,
      proxima_fecha = sumar_dias(current_date, sp.dias_espera, sp.dias_habiles), actualizado_en = now()
    where id = l.id returning * into l;
    insert into seguimientos (lead_id, tipo, paso, usuario) values (l.id, 'envio', sig, p_usuario);
  end if;
  return l;
end $$;

-- Mover a mano a cualquier paso (reactivar, saltar, corregir).
create or replace function mover_lead(p_lead uuid, p_codigo text, p_nota text default null, p_usuario text default null)
returns leads language plpgsql as $$
declare l leads; sp pasos_embudo;
begin
  select * into sp from pasos_embudo where codigo = p_codigo;
  if not found then raise exception 'El paso % no existe', p_codigo; end if;
  update leads set paso_actual = p_codigo, fecha_paso = current_date, enviado = false,
    proxima_fecha = case when sp.es_final then null else current_date end,
    estado = case when sp.es_final then sp.cierra_como else 'activo' end, actualizado_en = now()
  where id = p_lead returning * into l;
  if not found then raise exception 'El lead % no existe', p_lead; end if;
  insert into seguimientos (lead_id, tipo, paso, nota, usuario)
  values (l.id, 'cambio', p_codigo, coalesce(p_nota, 'Movido a mano al paso ' || p_codigo), p_usuario);
  return l;
end $$;

-- Cerrar un lead sin pasar por el embudo (cancelado o archivado).
create or replace function cerrar_lead(p_lead uuid, p_estado estado_lead_t, p_nota text default null, p_usuario text default null)
returns leads language plpgsql as $$
declare l leads;
begin
  if p_estado = 'activo' then raise exception 'Para reactivar usa mover_lead'; end if;
  update leads set estado = p_estado, proxima_fecha = null, actualizado_en = now()
  where id = p_lead returning * into l;
  if not found then raise exception 'El lead % no existe', p_lead; end if;
  insert into seguimientos (lead_id, tipo, paso, nota, usuario)
  values (l.id, 'cambio', l.paso_actual, coalesce(p_nota, 'Cerrado como ' || p_estado), p_usuario);
  return l;
end $$;

-- ¿Está libre la cabaña en ese rango? La salida de uno y la llegada de otro
-- pueden ser el mismo día (limpieza rápida).
create or replace function cabana_disponible(p_cabana int, p_llegada date, p_salida date, p_excluir uuid default null)
returns boolean language sql stable as $$
  select not exists (
    select 1 from reservaciones r
    where r.cabana_id = p_cabana and r.estado <> 'cancelada'
      and r.fecha_llegada is not null and r.fecha_salida is not null
      and (p_excluir is null or r.id <> p_excluir)
      and daterange(r.fecha_llegada, r.fecha_salida, '[)') && daterange(p_llegada, p_salida, '[)')
  )
$$;

create or replace function reservaciones_sin_traslape() returns trigger language plpgsql as $$
begin
  if current_setting('app.migracion', true) = 'on' then return new; end if;
  if new.cabana_id is null or new.fecha_llegada is null or new.fecha_salida is null or new.estado = 'cancelada' then
    return new;
  end if;
  if not cabana_disponible(new.cabana_id, new.fecha_llegada, new.fecha_salida, new.id) then
    raise exception 'La cabaña ya está reservada entre % y %', new.fecha_llegada, new.fecha_salida
      using errcode = 'exclusion_violation';
  end if;
  return new;
end $$;
create trigger reservaciones_sin_traslape before insert or update on reservaciones
  for each row execute function reservaciones_sin_traslape();

-- Al crear una reservación se le cuelga el checklist de estancia completo.
create or replace function reservaciones_checklist() returns trigger language plpgsql as $$
begin
  insert into checklist_reserva (reservacion_id, catalogo_id)
  select new.id, c.id from checklist_catalogo c where c.activo;
  return new;
end $$;
create trigger reservaciones_checklist after insert on reservaciones
  for each row execute function reservaciones_checklist();

-- Convierte un lead en reservación: crea la reserva, registra el anticipo y
-- cierra el lead como "reservó" (queda en el paso de instrucciones).
create or replace function convertir_lead_en_reserva(
  p_lead uuid, p_cabana int, p_llegada date, p_salida date, p_total numeric,
  p_anticipo numeric default null, p_personas int default null, p_usuario text default null)
returns reservaciones language plpgsql as $$
declare l leads; r reservaciones;
begin
  select * into l from leads where id = p_lead for update;
  if not found then raise exception 'El lead % no existe', p_lead; end if;
  insert into reservaciones (lead_id, cabana_id, nombre, lada_pais, celular, personas, fecha_llegada, fecha_salida, total, estado)
  values (l.id, p_cabana, coalesce(l.nombre, l.celular), l.lada_pais, l.celular, coalesce(p_personas, l.personas),
          p_llegada, p_salida, p_total,
          (case when p_anticipo >= p_total then 'liquidada' else 'apartada' end)::estado_reserva_t)
  returning * into r;
  if p_anticipo > 0 then
    insert into pagos (reservacion_id, monto, tipo, nota) values (r.id, p_anticipo, 'anticipo', 'Registrado al reservar');
  end if;
  update leads set estado = 'reservo', paso_actual = '9', fecha_paso = current_date, proxima_fecha = null,
    enviado = false, monto_cotizado = coalesce(monto_cotizado, p_total), actualizado_en = now()
  where id = l.id;
  insert into seguimientos (lead_id, tipo, paso, nota, usuario)
  values (l.id, 'cambio', '9', 'Reservó: ' || p_llegada || ' al ' || p_salida, p_usuario);
  return r;
end $$;

-- Registra un pago y actualiza el estado de la reservación si quedó liquidada.
create or replace function registrar_pago_reserva(p_reserva uuid, p_monto numeric, p_tipo tipo_pago_t default 'liquidacion',
                                                  p_metodo text default null, p_cuenta text default null, p_nota text default null)
returns pagos language plpgsql as $$
declare pg pagos; pagado numeric; total numeric;
begin
  insert into pagos (reservacion_id, monto, tipo, metodo, cuenta, nota)
  values (p_reserva, p_monto, p_tipo, p_metodo, p_cuenta, p_nota) returning * into pg;
  select coalesce(sum(monto), 0) into pagado from pagos where reservacion_id = p_reserva and tipo in ('anticipo', 'liquidacion');
  select r.total into total from reservaciones r where r.id = p_reserva;
  if total is not null and pagado >= total then
    update reservaciones set estado = 'liquidada' where id = p_reserva and estado = 'apartada';
  end if;
  return pg;
end $$;

-- =============================================================================
-- Vistas: lo que ven las pantallas
-- =============================================================================

-- Lista de hoy: a quién le toca mensaje, con qué plantilla y a dónde iría.
create view v_lista_hoy as
select l.id, l.nombre, l.lada_pais, l.celular, l.destino, l.interes_tours, l.personas, l.noches, l.mes_viaje,
       l.monto_cotizado, l.origen, l.paso_actual, p.nombre as paso_nombre, p.plantilla, l.enviado,
       l.fecha_paso, l.proxima_fecha, current_date - l.proxima_fecha as dias_retraso,
       resolver_paso(p.siguiente_si_contesta, l.destino) as si_contesta,
       resolver_paso(p.siguiente_si_no_contesta, l.destino) as si_no_contesta,
       l.comentarios, l.atiende
from leads l
join pasos_embudo p on p.codigo = l.paso_actual
where l.estado = 'activo' and l.proxima_fecha <= current_date
order by l.proxima_fecha, p.orden;

-- Cuántos leads hay en cada paso.
create view v_embudo as
select p.codigo, p.nombre, p.orden,
       count(l.id) filter (where l.estado = 'activo') as activos,
       count(l.id) as historico
from pasos_embudo p
left join leads l on l.paso_actual = p.codigo
where p.activo
group by p.codigo, p.nombre, p.orden
order by p.orden;

-- Historial completo de un lead.
create view v_historial as
select s.lead_id, s.fecha, s.tipo, s.paso, p.nombre as paso_nombre, s.contesto, s.canal, s.nota, s.usuario
from seguimientos s left join pasos_embudo p on p.codigo = s.paso
order by s.fecha desc;

-- Reservación con pagos, gastos, ganancia y checklist pendiente.
create view v_reserva_resumen as
select r.*, c.nombre as cabana, c.ubicacion,
       coalesce(pg.pagado, 0) as pagado,
       coalesce(r.total, 0) - coalesce(pg.pagado, 0) as saldo,
       coalesce(g.gastos, 0) as gastos,
       coalesce(r.total, 0) - coalesce(g.gastos, 0) as ganancia,
       coalesce(ch.pendientes, 0) as checklist_pendiente
from reservaciones r
left join cabanas c on c.id = r.cabana_id
left join (select reservacion_id, sum(monto) as pagado from pagos where tipo in ('anticipo', 'liquidacion') group by 1) pg
       on pg.reservacion_id = r.id
left join (select reservacion_id, sum(monto) as gastos from gastos_reserva group by 1) g on g.reservacion_id = r.id
left join (select reservacion_id, count(*) filter (where not hecho) as pendientes from checklist_reserva group by 1) ch
       on ch.reservacion_id = r.id;

-- Inscripción a evento con lo pagado y el saldo.
create view v_inscripcion_resumen as
select i.*, e.nombre as evento, e.fecha as fecha_evento,
       coalesce(pg.pagado, 0) as pagado, i.precio - coalesce(pg.pagado, 0) as saldo,
       case when coalesce(pg.pagado, 0) >= i.precio then 'pagado'
            when coalesce(pg.pagado, 0) > 0 then 'anticipo' else 'pendiente' end as estado_pago
from inscripciones i
join eventos e on e.id = i.evento_id
left join (select inscripcion_id, sum(monto) as pagado from pagos group by 1) pg on pg.inscripcion_id = i.id;

-- Métricas por semana: reemplaza la hoja "Feedback Diario de Leads".
create view v_semana as
with semanas as (
  select distinct date_trunc('week', x)::date as semana from (
    select creado_en as x from leads
    union all select fecha from seguimientos
    union all select creado_en from reservaciones
  ) t
)
select s.semana,
  (select count(*) from leads l where date_trunc('week', l.creado_en)::date = s.semana) as leads_nuevos,
  (select count(*) from seguimientos g where g.tipo = 'envio' and date_trunc('week', g.fecha)::date = s.semana) as mensajes_enviados,
  (select count(distinct g.lead_id) from seguimientos g
     where g.tipo = 'envio' and g.paso in ('5', '6') and date_trunc('week', g.fecha)::date = s.semana) as cotizaciones_enviadas,
  (select count(*) from seguimientos g where g.tipo = 'respuesta' and g.contesto and date_trunc('week', g.fecha)::date = s.semana) as respuestas,
  (select count(*) from reservaciones r where r.estado <> 'cancelada' and date_trunc('week', r.creado_en)::date = s.semana) as reservas,
  (select coalesce(sum(r.total), 0) from reservaciones r where r.estado <> 'cancelada' and date_trunc('week', r.creado_en)::date = s.semana) as monto_reservado
from semanas s
order by s.semana desc;

-- Ingresos y ganancia por mes de llegada, contra la meta de reservas.
create view v_mes as
select date_trunc('month', r.fecha_llegada)::date as mes,
       count(*) as reservas,
       sum(r.total) as ingresos,
       sum(r.gastos) as gastos,
       sum(r.ganancia) as ganancia,
       max(m.valor_meta) as meta_reservas
from v_reserva_resumen r
left join metas m on m.indicador = 'reservas' and m.mes = date_trunc('month', r.fecha_llegada)::date
where r.estado <> 'cancelada' and r.fecha_llegada is not null
group by 1
order by 1 desc;

-- Ocupación: para pintar el calendario.
create view v_ocupacion as
select r.id, r.cabana_id, c.nombre as cabana, r.nombre as huesped, r.fecha_llegada, r.fecha_salida, r.estado, r.personas
from reservaciones r join cabanas c on c.id = r.cabana_id
where r.estado <> 'cancelada' and r.fecha_llegada is not null
order by r.fecha_llegada;

-- =============================================================================
-- Datos fijos
-- =============================================================================
insert into cabanas (nombre, ubicacion, capacidad, precio_base) values
  ('Cabaña San José', 'San José', 6, 8299),
  ('Cabaña Alpina Gómez Farías', 'Gómez Farías', 4, 2500)
on conflict (nombre) do nothing;

insert into checklist_catalogo (momento, tarea, orden) values
  ('antes',   'Enviar mensaje de bienvenida: agradecer, detalles de check-in, políticas, servicios y actividades', 1),
  ('antes',   'Preparar la cabaña: limpieza profunda, mobiliario, electrodomésticos, sábanas, toallas y productos de higiene', 2),
  ('antes',   'Confirmar servicios adicionales: transporte, tours y actividades que pidió el huésped', 3),
  ('antes',   'Enviar recordatorio de llegada: hora de check-in, políticas y servicios', 4),
  ('durante', 'Verificar check-in: identificación, datos y pago completo', 5),
  ('durante', 'Recibir al huésped: bienvenida, normas y servicios disponibles', 6),
  ('durante', 'Mensaje de cortesía el primer día para verificar que todo esté bien', 7),
  ('durante', 'Atender necesidades y solicitudes del huésped durante la estancia', 8),
  ('despues', 'Mensaje de agradecimiento y solicitud de reseña en Google', 9),
  ('despues', 'Revisar la cabaña después del check-out: faltantes, daños, reabastecer', 10),
  ('despues', 'Registrar el feedback recibido para mejorar el servicio', 11),
  ('despues', 'Limpiar la cabaña para la próxima renta', 12);
