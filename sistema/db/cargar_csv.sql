-- =============================================================================
-- Carga en la base los CSV que genera migracion/limpiar_excel.py.
-- Correr DESDE la carpeta sistema/migracion (las rutas son relativas a ella):
--   cd sistema/migracion
--   python3 limpiar_excel.py "ruta/al/Excel.xlsx"
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../db/cargar_csv.sql
-- Todo va en una transacción: si algo falla, no queda nada a medias.
-- =============================================================================
\set ON_ERROR_STOP on
begin;

-- Las reservaciones del Excel pueden traslaparse (varias cabañas anotadas con el
-- mismo nombre); durante la carga no se valida el traslape.
select set_config('app.migracion', 'on', true);

-- Pasos del embudo (plantillas y reglas)
\i salida/seed_pasos_embudo.sql

-- Cabañas
create temp table st_cabanas (nombre text, ubicacion text, capacidad int, precio_base numeric) on commit drop;
\copy st_cabanas from 'salida/cabanas.csv' with (format csv, header true, null '')
insert into cabanas (nombre, ubicacion, capacidad, precio_base)
select nombre, ubicacion::destino_t, capacidad, precio_base from st_cabanas
on conflict (nombre) do nothing;

-- Leads
create temp table st_leads (
  lada_pais text, celular text, nombre text, destino text, interes_tours boolean, mes_viaje text,
  personas int, noches int, monto_cotizado numeric, paso_actual text, paso_original text,
  fecha_paso date, proxima_fecha date, estado text, enviado boolean, comentarios text,
  creado_en date, fila_origen text) on commit drop;
\copy st_leads from 'salida/leads.csv' with (format csv, header true, null '')
insert into leads (lada_pais, celular, nombre, destino, interes_tours, mes_viaje, personas, noches, monto_cotizado,
                   paso_actual, paso_original, fecha_paso, proxima_fecha, estado, enviado, comentarios,
                   referencia_excel, creado_en)
select lada_pais, celular, nullif(nombre, ''), destino::destino_t, coalesce(interes_tours, false), nullif(mes_viaje, ''),
       personas, noches, monto_cotizado, nullif(paso_actual, ''), nullif(paso_original, ''), fecha_paso, proxima_fecha,
       estado::estado_lead_t, coalesce(enviado, true), nullif(comentarios, ''), fila_origen,
       coalesce(creado_en::timestamptz, now())
from st_leads
on conflict (lada_pais, celular) do nothing;

-- Historial (una entrada por fila original del Excel)
create temp table st_seg (lada_pais text, celular text, fecha date, paso text, paso_original text, contesto boolean, nota text) on commit drop;
\copy st_seg from 'salida/seguimientos.csv' with (format csv, header true, null '')
insert into seguimientos (lead_id, fecha, tipo, paso, contesto, nota)
select l.id, s.fecha::timestamptz, 'migracion', nullif(s.paso, ''), s.contesto, s.nota
from st_seg s
join leads l on l.lada_pais = s.lada_pais and l.celular = s.celular;

-- Reservaciones
create temp table st_res (
  fila_origen text, nombre text, lada_pais text, celular text, personas int, cabana text, ubicacion text,
  fecha_llegada date, fecha_salida date, fechas_texto text, mes text, total numeric, anticipo numeric,
  fecha_anticipo date, liquidada boolean, fecha_liquidacion date, hora_llegada text, ocupa_transporte boolean,
  estado_transporte text, limpieza_rapida boolean, dias_limpiar int, estado text, comentarios text) on commit drop;
\copy st_res from 'salida/reservaciones.csv' with (format csv, header true, null '')
insert into reservaciones (lead_id, cabana_id, nombre, lada_pais, celular, personas, fecha_llegada, fecha_salida,
                           fechas_texto, hora_llegada, total, ocupa_transporte, estado_transporte, limpieza_rapida,
                           dias_limpiar, estado, comentarios, referencia_excel, creado_en)
select l.id, c.id, s.nombre, coalesce(s.lada_pais, '52'), nullif(s.celular, ''), s.personas, s.fecha_llegada, s.fecha_salida,
       nullif(s.fechas_texto, ''), nullif(s.hora_llegada, ''), s.total, s.ocupa_transporte, nullif(s.estado_transporte, ''),
       s.limpieza_rapida, s.dias_limpiar, s.estado::estado_reserva_t, nullif(s.comentarios, ''), s.fila_origen,
       coalesce(s.fecha_anticipo, s.fecha_llegada, current_date)::timestamptz
from st_res s
left join cabanas c on c.nombre = s.cabana
left join leads l on l.lada_pais = coalesce(s.lada_pais, '52') and l.celular = s.celular;

-- Pagos de reservaciones: anticipo y, si consta que liquidó, el resto
insert into pagos (reservacion_id, fecha, monto, tipo, nota)
select r.id, coalesce(s.fecha_anticipo, r.fecha_llegada, current_date), s.anticipo, 'anticipo', 'Migrado del Excel'
from st_res s join reservaciones r on r.referencia_excel = s.fila_origen
where s.anticipo > 0;
insert into pagos (reservacion_id, fecha, monto, tipo, nota)
select r.id, coalesce(s.fecha_liquidacion, r.fecha_llegada, current_date), s.total - coalesce(s.anticipo, 0), 'liquidacion', 'Migrado del Excel'
from st_res s join reservaciones r on r.referencia_excel = s.fila_origen
where s.liquidada and s.total - coalesce(s.anticipo, 0) > 0;

-- Gastos por reservación
create temp table st_gas (fila_origen text, concepto text, monto numeric) on commit drop;
\copy st_gas from 'salida/gastos_reserva.csv' with (format csv, header true, null '')
insert into gastos_reserva (reservacion_id, concepto, monto, fecha)
select r.id, g.concepto, g.monto, coalesce(r.fecha_llegada, current_date)
from st_gas g join reservaciones r on r.referencia_excel = g.fila_origen;

-- Eventos e inscripciones
create temp table st_ev (nombre text, mes text, fecha date, lugar text, fecha_publicacion date, incluye text,
                         costo numeric, precio_publico numeric, respuesta_predeterminada text, extra text) on commit drop;
\copy st_ev from 'salida/eventos.csv' with (format csv, header true, null '')
insert into eventos (nombre, mes, fecha, lugar, fecha_publicacion, incluye, costo, precio_publico, respuesta_predeterminada, notas, estado)
select nombre, nullif(mes, ''), fecha, lugar::destino_t, fecha_publicacion, nullif(incluye, ''), costo, precio_publico,
       nullif(respuesta_predeterminada, ''), nullif(extra, ''),
       case when fecha < current_date then 'realizado' else 'planeado' end
from st_ev
on conflict (nombre) do nothing;

create temp table st_ins (fila_origen text, evento text, nombre text, lada_pais text, celular text, precio numeric,
                          monto_pagado numeric, fecha_inscripcion date, alojamiento text, paga_alojamiento boolean,
                          monto_alojamiento numeric, cuenta text, comentarios text) on commit drop;
\copy st_ins from 'salida/inscripciones.csv' with (format csv, header true, null '')
insert into inscripciones (evento_id, lead_id, nombre, lada_pais, celular, precio, fecha_inscripcion, alojamiento,
                           paga_alojamiento, monto_alojamiento, cuenta, comentarios, referencia_excel)
select e.id, l.id, s.nombre, coalesce(s.lada_pais, '52'), nullif(s.celular, ''), coalesce(s.precio, 0),
       coalesce(s.fecha_inscripcion, current_date), nullif(s.alojamiento, ''), s.paga_alojamiento, s.monto_alojamiento,
       nullif(s.cuenta, ''), nullif(s.comentarios, ''), s.fila_origen
from st_ins s
join eventos e on e.nombre = s.evento
left join leads l on l.celular = s.celular and l.lada_pais = coalesce(s.lada_pais, '52');
insert into pagos (inscripcion_id, fecha, monto, tipo, cuenta, nota)
select i.id, i.fecha_inscripcion, s.monto_pagado, 'evento', i.cuenta, 'Migrado del Excel'
from st_ins s
join inscripciones i on i.referencia_excel = s.fila_origen
where s.monto_pagado > 0;

-- Los eventos ya realizados no necesitan tareas pendientes.
update evento_tareas t set hecho = true, hecho_en = now(), hecho_por = 'migración'
from eventos e where e.id = t.evento_id and e.estado = 'realizado';

-- Las estancias que ya pasaron no necesitan checklist pendiente.
update checklist_reserva set hecho = true, hecho_en = now(), hecho_por = 'migración'
where reservacion_id in (select id from reservaciones where estado = 'completada' and referencia_excel is not null);

-- Metas de la hoja "Hoja 7": el compromiso del trimestre y su desglose mensual
-- (ajusta el año y las cifras con Dirección antes de usarlas en serio)
insert into metas (objetivo, indicador, periodo, desde, valor_meta) values
  ('Generar ingresos sostenibles mediante hospedaje y experiencias turísticas', 'reservas', 'trimestre', date '2026-10-01', 30),
  ('Posicionar Glamping El Cielo Adventures como referente turístico de El Cielo', 'resenas', 'trimestre', date '2026-10-01', 60),
  ('Realizar mínimo una experiencia o evento mensual en El Cielo', 'eventos', 'trimestre', date '2026-10-01', 3),
  ('Generar ingresos sostenibles mediante hospedaje y experiencias turísticas', 'reservas', 'mes', date '2026-09-01', 6),
  ('Generar ingresos sostenibles mediante hospedaje y experiencias turísticas', 'reservas', 'mes', date '2026-10-01', 8),
  ('Generar ingresos sostenibles mediante hospedaje y experiencias turísticas', 'reservas', 'mes', date '2026-11-01', 10),
  ('Generar ingresos sostenibles mediante hospedaje y experiencias turísticas', 'reservas', 'mes', date '2026-12-01', 12),
  ('Posicionar Glamping El Cielo Adventures como referente turístico de El Cielo', 'resenas', 'mes', date '2026-09-01', 10),
  ('Posicionar Glamping El Cielo Adventures como referente turístico de El Cielo', 'resenas', 'mes', date '2026-10-01', 15),
  ('Posicionar Glamping El Cielo Adventures como referente turístico de El Cielo', 'resenas', 'mes', date '2026-11-01', 20),
  ('Posicionar Glamping El Cielo Adventures como referente turístico de El Cielo', 'resenas', 'mes', date '2026-12-01', 25),
  ('Realizar mínimo una experiencia o evento mensual en El Cielo', 'eventos', 'mes', date '2026-09-01', 1),
  ('Realizar mínimo una experiencia o evento mensual en El Cielo', 'eventos', 'mes', date '2026-10-01', 1),
  ('Realizar mínimo una experiencia o evento mensual en El Cielo', 'eventos', 'mes', date '2026-11-01', 1),
  ('Realizar mínimo una experiencia o evento mensual en El Cielo', 'eventos', 'mes', date '2026-12-01', 1)
on conflict (indicador, periodo, desde) do nothing;

commit;

select 'leads' as tabla, count(*) from leads
union all select 'seguimientos', count(*) from seguimientos
union all select 'reservaciones', count(*) from reservaciones
union all select 'pagos', count(*) from pagos
union all select 'gastos_reserva', count(*) from gastos_reserva
union all select 'eventos', count(*) from eventos
union all select 'inscripciones', count(*) from inscripciones
union all select 'pasos_embudo', count(*) from pasos_embudo;
