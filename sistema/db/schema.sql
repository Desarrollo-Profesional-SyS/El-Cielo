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

-- =============================================================================
-- Proceso de un evento: tareas por fase con fecha límite y responsable,
-- gastos y resumen financiero. Cada evento nace con el proceso completo.
-- =============================================================================
create type fase_evento_t as enum ('planeacion', 'difusion', 'inscripciones', 'logistica', 'evento', 'cierre');

create table evento_tareas_catalogo (
  id          serial primary key,
  fase        fase_evento_t not null,
  tarea       text not null,
  dias_antes  int not null default 0,     -- negativo = días después del evento
  responsable text,
  orden       int not null default 0,
  activo      boolean not null default true
);

create table evento_tareas (
  id            bigserial primary key,
  evento_id     int not null references eventos (id) on delete cascade,
  fase          fase_evento_t not null,
  tarea         text not null,
  dias_antes    int not null default 0,
  fecha_limite  date,
  responsable   text,
  hecho         boolean not null default false,
  hecho_en      timestamptz,
  hecho_por     text,
  orden         int not null default 0
);
create index evento_tareas_evento_idx on evento_tareas (evento_id, hecho, fecha_limite);

create table gastos_evento (
  id         bigserial primary key,
  evento_id  int not null references eventos (id) on delete cascade,
  concepto   text not null,
  monto      numeric(10,2) not null check (monto >= 0),
  fecha      date not null default current_date
);

-- Al crear un evento se le cuelga el proceso completo con fechas límite.
create or replace function eventos_proceso() returns trigger language plpgsql as $$
begin
  insert into evento_tareas (evento_id, fase, tarea, dias_antes, fecha_limite, responsable, orden)
  select new.id, c.fase, c.tarea, c.dias_antes, new.fecha - c.dias_antes, c.responsable, c.orden
  from evento_tareas_catalogo c where c.activo;
  return new;
end $$;
create trigger eventos_proceso after insert on eventos for each row execute function eventos_proceso();

-- Si cambia la fecha del evento, se recorren las fechas límite de lo pendiente.
create or replace function eventos_recalcular_limites() returns trigger language plpgsql as $$
begin
  if new.fecha is distinct from old.fecha then
    update evento_tareas set fecha_limite = new.fecha - dias_antes where evento_id = new.id and not hecho;
  end if;
  return new;
end $$;
create trigger eventos_recalcular_limites after update of fecha on eventos
  for each row execute function eventos_recalcular_limites();

create or replace function registrar_pago_inscripcion(p_inscripcion bigint, p_monto numeric, p_metodo text default null,
                                                      p_cuenta text default null, p_nota text default null)
returns pagos language sql as $$
  insert into pagos (inscripcion_id, monto, tipo, metodo, cuenta, nota)
  values (p_inscripcion, p_monto, 'evento', p_metodo, p_cuenta, p_nota) returning *;
$$;

-- Evento con inscritos, cobrado, gastos, ganancia y tareas pendientes o vencidas.
create view v_evento_resumen as
select e.*,
       coalesce(i.inscritos, 0) as inscritos,
       coalesce(i.esperado, 0) as esperado,
       coalesce(pg.cobrado, 0) as cobrado,
       coalesce(g.gastos, 0) + coalesce(e.costo, 0) * coalesce(i.inscritos, 0) as gastos,
       coalesce(pg.cobrado, 0) - (coalesce(g.gastos, 0) + coalesce(e.costo, 0) * coalesce(i.inscritos, 0)) as ganancia,
       coalesce(t.pendientes, 0) as tareas_pendientes,
       coalesce(t.vencidas, 0) as tareas_vencidas
from eventos e
left join (select evento_id, count(*) as inscritos, sum(precio) as esperado from inscripciones group by 1) i on i.evento_id = e.id
left join (select ins.evento_id, sum(p.monto) as cobrado from pagos p join inscripciones ins on ins.id = p.inscripcion_id group by 1) pg
       on pg.evento_id = e.id
left join (select evento_id, sum(monto) as gastos from gastos_evento group by 1) g on g.evento_id = e.id
left join (select evento_id, count(*) filter (where not hecho) as pendientes,
                  count(*) filter (where not hecho and fecha_limite < current_date) as vencidas
           from evento_tareas group by 1) t on t.evento_id = e.id;

insert into evento_tareas_catalogo (fase, tarea, dias_antes, responsable, orden) values
  ('planeacion',    'Definir fecha, lugar y cupo', 30, 'Dirección', 1),
  ('planeacion',    'Definir precio, costo por persona y punto de equilibrio', 30, 'Dirección', 2),
  ('planeacion',    'Confirmar guía o instructor', 28, 'Dirección', 3),
  ('planeacion',    'Confirmar transporte 4x4', 25, 'Transporte', 4),
  ('planeacion',    'Tramitar permisos (acampar, acceso a la reserva)', 25, 'Operación', 5),
  ('planeacion',    'Armar itinerario, plan de pagos y política de no reembolso', 24, 'Ventas', 6),
  ('difusion',      'Diseñar imagen y texto del evento', 21, 'Marketing', 7),
  ('difusion',      'Preparar la respuesta predeterminada de WhatsApp', 21, 'Ventas', 8),
  ('difusion',      'Publicar en Facebook e Instagram', 20, 'Marketing', 9),
  ('difusion',      'Compartir en la comunidad de WhatsApp', 20, 'Ventas', 10),
  ('difusion',      'Lanzar anuncio en Meta', 18, 'Marketing', 11),
  ('inscripciones', 'Registrar inscritos y cobrar anticipo', 14, 'Ventas', 12),
  ('inscripciones', 'Cobrar liquidación a todos (dos semanas antes)', 14, 'Ventas', 13),
  ('inscripciones', 'Confirmar alojamiento de cada inscrito', 10, 'Ventas', 14),
  ('inscripciones', 'Cerrar la lista final de asistentes', 7, 'Ventas', 15),
  ('logistica',     'Comprar comida, snacks y utensilios', 3, 'Operación', 16),
  ('logistica',     'Preparar el material del taller', 3, 'Operación', 17),
  ('logistica',     'Resolver baños, fogata y bolsas de basura', 2, 'Operación', 18),
  ('logistica',     'Enviar instrucciones a los inscritos: hora, punto de salida, qué llevar', 2, 'Ventas', 19),
  ('evento',        'Pasar lista y cobrar pendientes', 0, 'Ventas', 20),
  ('evento',        'Tomar fotos y video', 0, 'Marketing', 21),
  ('cierre',        'Limpiar el lugar', -1, 'Operación', 22),
  ('cierre',        'Pedir reseñas a los asistentes', -1, 'Ventas', 23),
  ('cierre',        'Publicar fotos y agradecer', -2, 'Marketing', 24),
  ('cierre',        'Cerrar cuentas: ingresos, gastos y ganancia', -3, 'Dirección', 25),
  ('cierre',        'Anotar aprendizajes para el próximo evento', -3, 'Dirección', 26);

-- =============================================================================
-- Cotizador: catálogo de tarifas, temporadas y servicios
-- =============================================================================
alter table cabanas add column if not exists personas_incluidas int not null default 2;
alter table cabanas add column if not exists extra_persona numeric(10,2) not null default 0;
alter table cabanas add column if not exists capacidad int;

create table temporadas (
  id     serial primary key,
  nombre text not null,
  desde  text not null check (desde ~ '^\d{2}-\d{2}$'),   -- MM-DD
  hasta  text not null check (hasta ~ '^\d{2}-\d{2}$'),   -- puede cruzar el año (12-15 a 01-06)
  factor numeric(4,2) not null default 1 check (factor > 0),
  activa boolean not null default true
);

create type tipo_servicio_t as enum ('transporte', 'actividad');
create type cobro_t as enum ('viaje', 'persona', 'grupo');

create table servicios (
  id     serial primary key,
  tipo   tipo_servicio_t not null,
  nombre text not null,
  precio numeric(10,2) not null default 0 check (precio >= 0),
  cobro  cobro_t not null default 'persona',
  activo boolean not null default true
);

create table cotizaciones (
  id         bigserial primary key,
  lead_id    uuid references leads (id) on delete set null,
  cabana_id  int references cabanas (id),
  llegada    date not null,
  salida     date not null check (salida > llegada),
  personas   int not null check (personas > 0),
  descuento  numeric(5,2) not null default 0,
  total      numeric(10,2) not null,
  anticipo   numeric(10,2) not null,
  mensaje    text,
  creada_en  timestamptz not null default now(),
  creada_por text
);

create table cotizacion_servicios (
  cotizacion_id bigint not null references cotizaciones (id) on delete cascade,
  servicio_id   int not null references servicios (id),
  monto         numeric(10,2) not null,
  primary key (cotizacion_id, servicio_id)
);

-- Factor de temporada para una fecha (1 si no cae en ninguna).
create or replace function factor_temporada(p_fecha date)
returns numeric language sql stable as $$
  select coalesce(max(t.factor), 1) from temporadas t
  where t.activa and (
    case when t.desde <= t.hasta
      then to_char(p_fecha, 'MM-DD') between t.desde and t.hasta
      else to_char(p_fecha, 'MM-DD') >= t.desde or to_char(p_fecha, 'MM-DD') <= t.hasta
    end)
$$;

-- Hospedaje de una estancia: noches, personas extra y temporada de la llegada.
create or replace function cotizar_hospedaje(p_cabana int, p_llegada date, p_salida date, p_personas int)
returns numeric language sql stable as $$
  select round((c.precio_base * (p_salida - p_llegada)
    + greatest(0, p_personas - c.personas_incluidas) * c.extra_persona * (p_salida - p_llegada))
    * factor_temporada(p_llegada))
  from cabanas c where c.id = p_cabana
$$;

-- =============================================================================
-- Calendario: bloqueos, actividades agendadas y publicaciones
-- =============================================================================
create table bloqueos (
  id        bigserial primary key,
  cabana_id int not null references cabanas (id) on delete cascade,
  desde     date not null,
  hasta     date not null check (hasta > desde),
  motivo    text not null default 'Mantenimiento',
  nota      text,
  creado_en timestamptz not null default now()
);
create index bloqueos_idx on bloqueos (cabana_id, desde, hasta);

alter table reservaciones add column if not exists origen text not null default 'Embudo';

create table agenda_actividades (
  id          bigserial primary key,
  fecha       date not null,
  hora        time,
  servicio_id int references servicios (id),
  nombre      text not null,
  personas    int not null default 1 check (personas > 0),
  para        text,
  lead_id     uuid references leads (id) on delete set null,
  nota        text
);
create index agenda_fecha_idx on agenda_actividades (fecha);

create table publicaciones (
  id        bigserial primary key,
  fecha     date not null,
  tipo      text not null default 'Post' check (tipo in ('Post', 'Reel', 'Historia', 'Mensaje')),
  tema      text not null,
  canal     text not null default 'Facebook / Instagram',
  evento_id int references eventos (id) on delete set null,
  estado    text not null default 'pendiente' check (estado in ('pendiente', 'publicada')),
  liga      text,
  unique (fecha, tema)
);
create index publicaciones_fecha_idx on publicaciones (fecha, estado);

-- Disponibilidad: ahora también respeta los bloqueos de mantenimiento.
create or replace function cabana_disponible(p_cabana int, p_llegada date, p_salida date, p_excluir uuid default null)
returns boolean language sql stable as $$
  select not exists (
    select 1 from reservaciones r
    where r.cabana_id = p_cabana and r.estado <> 'cancelada'
      and r.fecha_llegada is not null and r.fecha_salida is not null
      and (p_excluir is null or r.id <> p_excluir)
      and daterange(r.fecha_llegada, r.fecha_salida, '[)') && daterange(p_llegada, p_salida, '[)')
  ) and not exists (
    select 1 from bloqueos b
    where b.cabana_id = p_cabana
      and daterange(b.desde, b.hasta, '[)') && daterange(p_llegada, p_salida, '[)')
  )
$$;

-- Qué hay cada día: alimenta el calendario del equipo y el del sitio.
create view v_calendario as
select r.fecha_llegada as desde, r.fecha_salida as hasta, 'reserva'::text as tipo, r.cabana_id,
       coalesce(r.nombre, '') || ' · ' || r.origen as titulo, r.id::text as ref
from reservaciones r where r.estado <> 'cancelada' and r.fecha_llegada is not null and r.fecha_salida is not null
union all
select b.desde, b.hasta, 'bloqueo', b.cabana_id, b.motivo, b.id::text from bloqueos b
union all
select e.fecha, e.fecha + 1, 'evento', null, e.nombre, e.id::text from eventos e where e.estado <> 'cancelado' and e.fecha is not null
union all
select a.fecha, a.fecha + 1, 'actividad', null, coalesce(to_char(a.hora, 'HH24:MI') || ' ', '') || a.nombre, a.id::text from agenda_actividades a
union all
select p.fecha, p.fecha + 1, 'publicacion', null, p.tipo || ': ' || p.tema, p.id::text from publicaciones p;

-- Disponibilidad por cabaña y día, para publicar en el sitio (sin nombres ni montos).
create or replace function disponibilidad(p_desde date, p_hasta date)
returns table (dia date, cabana_id int, cabana text, libre boolean) language sql stable as $$
  select d::date, c.id, c.nombre, cabana_disponible(c.id, d::date, d::date + 1)
  from generate_series(p_desde, p_hasta, interval '1 day') d
  cross join cabanas c where c.activa
$$;

-- =============================================================================
-- Plan de trabajo diario: rutina, bitácora y evidencia
-- =============================================================================
create table rutina_tareas (
  id      serial primary key,
  tarea   text not null,
  dia     int check (dia between 0 and 6),   -- null = todos los días; 0 domingo … 6 sábado
  orden   int not null default 0,
  activa  boolean not null default true
);

create table plan_dia (
  fecha            date not null,
  clave            text not null,            -- r-<rutina_id> | p-<publicacion_id> | e-<evento_tarea_id>
  hecho            boolean not null default false,
  hecho_en         timestamptz,
  hecho_por        text,
  evidencia_texto  text,
  evidencia_url    text,
  primary key (fecha, clave)
);

-- Lo que toca hoy: rutina del día, publicaciones programadas y tareas de eventos
-- que vencen o vienen vencidas, con su marca y evidencia si ya se hizo.
create or replace function plan_del_dia(p_fecha date)
returns table (clave text, grupo text, tarea text, responsable text, limite date,
               hecho boolean, hecho_en timestamptz, hecho_por text, evidencia_texto text, evidencia_url text)
language sql stable as $$
  with items as (
    select 'r-' || r.id as clave,
           case when r.dia is null then 'Rutina diaria' else 'Cada ' || lower(to_char(p_fecha, 'TMday')) end as grupo,
           r.tarea, null::text as responsable, p_fecha as limite, r.orden
    from rutina_tareas r
    where r.activa and (r.dia is null or r.dia = extract(dow from p_fecha))
    union all
    select 'p-' || p.id, 'Publicaciones del día', p.tipo || ': ' || p.tema || ' · ' || p.canal, null, p.fecha, 100
    from publicaciones p where p.fecha = p_fecha
    union all
    select 'e-' || t.id, 'Tareas de eventos', t.tarea || ' · ' || e.nombre, t.responsable, t.fecha_limite, 200
    from evento_tareas t join eventos e on e.id = t.evento_id
    where e.estado not in ('realizado', 'cancelado')
      and (case when p_fecha = current_date then (not t.hecho and t.fecha_limite <= p_fecha) else t.fecha_limite = p_fecha end)
  )
  select i.clave, i.grupo, i.tarea, i.responsable, i.limite,
         coalesce(d.hecho, false), d.hecho_en, d.hecho_por, d.evidencia_texto, d.evidencia_url
  from items i left join plan_dia d on d.fecha = p_fecha and d.clave = i.clave
  order by i.orden, i.tarea
$$;

-- Marca una tarea del plan y propaga el estado a su origen (publicación o tarea de evento).
create or replace function marcar_plan(p_fecha date, p_clave text, p_hecho boolean,
                                       p_usuario text default null, p_evidencia text default null, p_url text default null)
returns plan_dia language plpgsql as $$
declare d plan_dia;
begin
  insert into plan_dia (fecha, clave, hecho, hecho_en, hecho_por, evidencia_texto, evidencia_url)
  values (p_fecha, p_clave, p_hecho, case when p_hecho then now() end, case when p_hecho then p_usuario end, p_evidencia, p_url)
  on conflict (fecha, clave) do update set hecho = excluded.hecho, hecho_en = excluded.hecho_en, hecho_por = excluded.hecho_por,
    evidencia_texto = coalesce(excluded.evidencia_texto, plan_dia.evidencia_texto),
    evidencia_url = coalesce(excluded.evidencia_url, plan_dia.evidencia_url)
  returning * into d;
  if p_clave like 'p-%' then
    update publicaciones set estado = case when p_hecho then 'publicada' else 'pendiente' end
    where id = substring(p_clave from 3)::bigint;
  elsif p_clave like 'e-%' then
    update evento_tareas set hecho = p_hecho, hecho_en = case when p_hecho then now() end, hecho_por = case when p_hecho then p_usuario end
    where id = substring(p_clave from 3)::bigint;
  end if;
  return d;
end $$;

-- Cumplimiento del plan por día, para el tablero.
create view v_plan_cumplimiento as
select d.fecha, count(*) as marcadas, count(*) filter (where d.hecho) as hechas,
       count(*) filter (where d.evidencia_texto is not null or d.evidencia_url is not null) as con_evidencia
from plan_dia d group by d.fecha order by d.fecha desc;

-- -----------------------------------------------------------------------------
-- Datos fijos de las tres pantallas nuevas
-- -----------------------------------------------------------------------------
insert into temporadas (nombre, desde, hasta, factor) values
  ('Semana Santa', '03-28', '04-12', 1.2), ('Verano', '07-01', '08-20', 1.1), ('Navidad y Año Nuevo', '12-15', '01-06', 1.2);

insert into servicios (tipo, nombre, precio, cobro) values
  ('transporte', 'Llegan en su propio 4x4', 0, 'viaje'),
  ('transporte', '4x4 desde Gómez Farías, ida y vuelta', 1500, 'viaje'),
  ('transporte', '4x4 desde Ciudad Mante, ida y vuelta', 2500, 'viaje'),
  ('actividad', 'Paseo a caballo', 350, 'persona'),
  ('actividad', 'Tour a la Cueva del Agua', 250, 'persona'),
  ('actividad', 'Senderismo guiado a Alta Cima', 300, 'persona'),
  ('actividad', 'Avistamiento de aves al amanecer', 400, 'persona'),
  ('actividad', 'Fogata con leña', 200, 'grupo'),
  ('actividad', 'Bicicletas de montaña', 150, 'persona');

insert into rutina_tareas (tarea, dia, orden) values
  ('Mandar los buenos días al grupo', null, 1),
  ('Contestar mensajes de WhatsApp', null, 2),
  ('Registrar los leads nuevos que llegaron', null, 3),
  ('Seguimiento del embudo (lista de hoy)', null, 4),
  ('Contestar mensajes y comentarios de Facebook e Instagram', null, 5),
  ('Barrer y limpieza rápida', null, 6),
  ('Enviar el registro diario de leads al grupo', null, 7),
  ('Limpieza profunda de baños y áreas comunes', 1, 10),
  ('Compartir en la comunidad de WhatsApp', 1, 11),
  ('Revisar anticipos por liquidar de la semana', 4, 12),
  ('Confirmar llegadas del fin de semana', 5, 13),
  ('Compartir fotos de las cabañas en grupos', 6, 14),
  ('Limpiar senderos y zona de entrada', 6, 15),
  ('Junta con Dirección', 6, 16),
  ('Revisar la semana: leads, reservas y pendientes', 0, 17);

update cabanas set personas_incluidas = 6, extra_persona = 600, capacidad = 8 where nombre = 'Cabaña San José';
update cabanas set personas_incluidas = 2, extra_persona = 400, capacidad = 4 where nombre = 'Cabaña Alpina Gómez Farías';
