-- =============================================================================
-- Pruebas del motor de embudo. Corren dentro de una transacción que se
-- revierte al final: no dejan datos. Requieren schema.sql y el seed de pasos.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f pruebas.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

do $$
declare l leads; r reservaciones; n int; ev_id int; ins_id bigint; cab int; pub_id bigint; tar_id bigint;
begin
  -- Registrar un lead nuevo: queda en paso 1, para hoy, sin enviar.
  l := registrar_lead('834 000 0001', 'San José', 'Prueba Uno', 'Anuncio Meta', 4, 1, 'Octubre');
  assert l.paso_actual = '1' and l.proxima_fecha = current_date and l.enviado = false, 'lead nuevo en paso 1 para hoy';

  -- El mismo celular con otro formato no se duplica.
  l := registrar_lead('+52 1 834 000 0001');
  select count(*) into n from leads where celular = '8340000001';
  assert n = 1, 'no duplica celulares';

  -- Se manda el mensaje del paso 1: la siguiente revisión es mañana.
  l := avanzar_lead(l.id, null, 'enviado en prueba');
  assert l.enviado and l.proxima_fecha = current_date + 1, 'espera un día tras enviar';

  -- Cadena feliz para San José: 1 -> 3 -> 6 -> 7 -> 8 -> 9 (reservó).
  l := avanzar_lead(l.id, true);  assert l.paso_actual = '3', 'contestó en 1 va a 3 (San José), fue ' || l.paso_actual;
  l := avanzar_lead(l.id, false); assert l.paso_actual = '2.1', 'no contestó en 3 va a 2.1';
  l := avanzar_lead(l.id, true);  assert l.paso_actual = '6', 'contestó en 2.1 va a 6 (San José)';
  l := avanzar_lead(l.id, true);  assert l.paso_actual = '7';
  l := avanzar_lead(l.id, true);  assert l.paso_actual = '8';
  l := avanzar_lead(l.id, true);
  assert l.paso_actual = '9' and l.estado = 'reservo' and l.proxima_fecha is null, 'el paso 9 cierra como reservó';
  select count(*) into n from seguimientos where lead_id = l.id;
  assert n >= 9, 'quedó historial';

  -- Un lead que ya reservó no se puede avanzar.
  begin
    perform avanzar_lead(l.id, true);
    raise exception 'debió rechazar avanzar un lead cerrado';
  exception when raise_exception then
    if sqlerrm = 'debió rechazar avanzar un lead cerrado' then raise; end if;
  end;

  -- Cadena de no respuesta para Gómez Farías: termina cancelado.
  l := registrar_lead('834 000 0002', 'Gómez Farías');
  l := avanzar_lead(l.id, null);
  l := avanzar_lead(l.id, true);  assert l.paso_actual = '2', 'Gómez Farías va a 2';
  l := avanzar_lead(l.id, false); assert l.paso_actual = '2.1';
  l := avanzar_lead(l.id, false); assert l.paso_actual = '3.1';
  assert l.proxima_fecha = current_date + 2, 'contenido de valor espera 2 días';
  l := avanzar_lead(l.id, false); assert l.paso_actual = '4.1';
  l := avanzar_lead(l.id, false); assert l.paso_actual = '5.1';
  l := avanzar_lead(l.id, false);
  assert l.paso_actual = '6.1' and l.estado = 'cancelado', 'la cadena de no respuesta termina cancelada';

  -- Un cancelado que vuelve a escribir se reactiva en el paso 1.
  l := registrar_lead('834 000 0002');
  assert l.estado = 'activo' and l.paso_actual = '1' and l.enviado = false, 'reactivación';

  -- Días hábiles.
  assert sumar_dias(date '2026-09-11', 3, true) = date '2026-09-16', 'viernes + 3 hábiles = miércoles';
  assert sumar_dias(date '2026-09-11', 3, false) = date '2026-09-14', 'viernes + 3 naturales = lunes';

  -- Reservación desde un lead: checklist, pago y cierre del lead.
  l := registrar_lead('834 000 0003', 'San José', 'Prueba Tres');
  r := convertir_lead_en_reserva(l.id, (select id from cabanas where nombre = 'Cabaña San José'),
                                 date '2026-10-10', date '2026-10-11', 8299, 4150);
  assert (select estado from leads where id = l.id) = 'reservo', 'el lead queda como reservó';
  assert (select count(*) from checklist_reserva where reservacion_id = r.id) = 12, 'checklist de 12 tareas';
  assert (select pagado from v_reserva_resumen where id = r.id) = 4150, 'anticipo registrado';
  assert (select saldo from v_reserva_resumen where id = r.id) = 4149, 'saldo pendiente';
  perform registrar_pago_reserva(r.id, 4149);
  assert (select estado from reservaciones where id = r.id) = 'liquidada', 'se liquida al completar el pago';

  -- Traslape: la misma cabaña no se puede reservar dos veces en la misma noche.
  begin
    insert into reservaciones (cabana_id, nombre, fecha_llegada, fecha_salida, total)
    values (r.cabana_id, 'Choque', date '2026-10-10', date '2026-10-12', 1);
    raise exception 'debió rechazar el traslape';
  exception when exclusion_violation then
    null;
  end;
  -- Pero sí puede entrar alguien el día que sale el anterior.
  insert into reservaciones (cabana_id, nombre, fecha_llegada, fecha_salida, total)
  values (r.cabana_id, 'Siguiente huésped', date '2026-10-11', date '2026-10-12', 1);
  assert cabana_disponible(r.cabana_id, date '2026-10-12', date '2026-10-13'), 'libre después';
  assert not cabana_disponible(r.cabana_id, date '2026-10-09', date '2026-10-11'), 'ocupada esa noche';

  -- Lista de hoy: solo activos con fecha vencida.
  l := registrar_lead('834 000 0004', 'Gómez Farías');
  assert exists (select 1 from v_lista_hoy where id = l.id and si_contesta = '2' and si_no_contesta = '2.1'), 'aparece en la lista de hoy con sus siguientes pasos';
  l := avanzar_lead(l.id, null);
  assert not exists (select 1 from v_lista_hoy where id = l.id), 'ya no aparece hasta mañana';

  -- Evento: nace con su proceso completo y recorre las fechas si cambia la fecha.
  insert into eventos (nombre, fecha, lugar, precio_publico, costo, cupo)
  values ('Prueba de yoga', current_date + 30, 'San José', 2500, 900, 15) returning id into ev_id;
  assert (select count(*) from evento_tareas where evento_id = ev_id) = (select count(*) from evento_tareas_catalogo where activo),
         'el evento nace con todas las tareas del catálogo';
  assert (select fecha_limite from evento_tareas where evento_id = ev_id and tarea like 'Definir fecha%') = current_date,
         'la primera tarea vence hoy (30 días antes)';
  update eventos set fecha = current_date + 40 where id = ev_id;
  assert (select fecha_limite from evento_tareas where evento_id = ev_id and tarea like 'Definir fecha%') = current_date + 10,
         'las fechas límite se recorren con el evento';
  insert into inscripciones (evento_id, nombre, celular, precio) values (ev_id, 'Inscrita Uno', '8340000009', 2500) returning id into ins_id;
  perform registrar_pago_inscripcion(ins_id, 500);
  insert into gastos_evento (evento_id, concepto, monto) values (ev_id, 'Instructora', 2000);
  assert (select cobrado from v_evento_resumen where id = ev_id) = 500, 'cobrado del evento';
  assert (select gastos from v_evento_resumen where id = ev_id) = 2900, 'gastos = 2000 fijos + 900 por inscrito';
  assert (select estado_pago from v_inscripcion_resumen where id = ins_id) = 'anticipo', 'inscripción con anticipo';
  assert (select tareas_pendientes from v_evento_resumen where id = ev_id) = (select count(*) from evento_tareas_catalogo where activo);

  -- Cotizador: temporada, noches y personas extra.
  select id into cab from cabanas where nombre = 'Cabaña San José';
  assert factor_temporada(date '2026-07-15') = 1.1, 'julio cae en temporada de verano';
  assert factor_temporada(date '2026-12-28') = 1.2, 'la temporada navideña cruza el año';
  assert factor_temporada(date '2026-02-10') = 1, 'febrero no tiene factor';
  assert cotizar_hospedaje(cab, date '2026-02-10', date '2026-02-12', 6) = 8299 * 2, 'dos noches sin extras';
  assert cotizar_hospedaje(cab, date '2026-02-10', date '2026-02-12', 8) = 8299 * 2 + 2 * 600 * 2, 'dos personas extra por noche';
  assert cotizar_hospedaje(cab, date '2026-07-10', date '2026-07-11', 6) = round(8299 * 1.1), 'verano sube 10 %';

  -- Calendario: un bloqueo ocupa la cabaña aunque no haya reservación.
  insert into bloqueos (cabana_id, desde, hasta, motivo) values (cab, date '2026-02-20', date '2026-02-22', 'Mantenimiento');
  assert not cabana_disponible(cab, date '2026-02-21', date '2026-02-23'), 'el bloqueo ocupa la cabaña';
  assert cabana_disponible(cab, date '2026-02-22', date '2026-02-24'), 'libre al terminar el bloqueo';
  assert (select count(*) from v_calendario where tipo = 'bloqueo') >= 1, 'el bloqueo sale en el calendario';
  assert (select count(*) from disponibilidad(date '2026-02-20', date '2026-02-21') where not libre) = 2,
         'la disponibilidad del sitio marca ocupados los dos días del bloqueo';

  -- Plan del día: rutina, publicación y tarea de evento vencida, con evidencia.
  insert into publicaciones (fecha, tipo, tema) values (current_date, 'Post', 'Prueba de publicación') returning id into pub_id;
  update evento_tareas set fecha_limite = current_date - 2 where evento_id = ev_id and tarea like 'Definir fecha%' returning id into tar_id;
  assert (select count(*) from plan_del_dia(current_date) where grupo = 'Rutina diaria') =
         (select count(*) from rutina_tareas where activa and dia is null), 'la rutina diaria completa sale en el plan';
  assert exists (select 1 from plan_del_dia(current_date) where clave = 'p-' || pub_id), 'la publicación del día sale en el plan';
  assert exists (select 1 from plan_del_dia(current_date) where clave = 'e-' || tar_id and limite < current_date), 'la tarea vencida se arrastra a hoy';

  perform marcar_plan(current_date, 'p-' || pub_id, true, 'Andrés', 'Publicado a las 9:05');
  assert (select estado from publicaciones where id = pub_id) = 'publicada', 'marcar el plan publica la publicación';
  perform marcar_plan(current_date, 'e-' || tar_id, true, 'Andrés');
  assert (select hecho from evento_tareas where id = tar_id), 'marcar el plan cierra la tarea del evento';
  assert (select hecho_por from plan_del_dia(current_date) where clave = 'p-' || pub_id) = 'Andrés', 'queda quién la hizo';
  assert (select con_evidencia from v_plan_cumplimiento where fecha = current_date) = 1, 'se contabiliza la evidencia';
  perform marcar_plan(current_date, 'p-' || pub_id, false, 'Andrés');
  assert (select estado from publicaciones where id = pub_id) = 'pendiente', 'desmarcar regresa la publicación a pendiente';

  -- Metas: un mes y un trimestre sobre el mismo indicador.
  insert into metas (objetivo, indicador, periodo, desde, valor_meta) values
    ('Prueba', 'reservas', 'trimestre', date '2026-10-01', 30),
    ('Prueba', 'reservas', 'mes', date '2026-10-01', 8),
    ('Prueba', 'reservas', 'mes', date '2026-11-01', 10),
    ('Prueba', 'reservas', 'mes', date '2026-12-01', 12);
  assert fin_periodo(date '2026-10-01', 'trimestre') = date '2027-01-01', 'el trimestre termina tres meses después';
  assert fin_periodo(date '2026-10-01', 'mes') = date '2026-11-01', 'el mes termina un mes después';
  assert (select suma_mensuales from v_metas where periodo = 'trimestre' and indicador = 'reservas' and desde = date '2026-10-01') = 30,
         'los meses del trimestre suman lo mismo que el compromiso';
  assert (select trimestre from v_metas where periodo = 'mes' and desde = date '2026-11-01' and objetivo = 'Prueba') = '2026-T4',
         'noviembre cae en el cuarto trimestre';
  select avance into n from v_metas where periodo = 'mes' and indicador = 'reservas' and desde = date '2026-10-01' and objetivo = 'Prueba';
  insert into reservaciones (cabana_id, nombre, fecha_llegada, fecha_salida, total)
  values (r.cabana_id, 'Meta de octubre', date '2026-10-05', date '2026-10-07', 5000);
  assert (select avance from v_metas where periodo = 'mes' and indicador = 'reservas' and desde = date '2026-10-01' and objetivo = 'Prueba') = n + 1,
         'la reservación de octubre suma a la meta mensual';
  assert (select avance from v_metas where periodo = 'trimestre' and indicador = 'reservas' and desde = date '2026-10-01' and objetivo = 'Prueba')
       >= (select avance from v_metas where periodo = 'mes' and indicador = 'reservas' and desde = date '2026-10-01' and objetivo = 'Prueba'),
         'el trimestre incluye lo del mes';
  assert (select avance from v_metas where periodo = 'mes' and indicador = 'reservas' and desde = date '2026-11-01' and objetivo = 'Prueba') = 0,
         'pero no cuenta en noviembre';
  assert (select meses_con_meta from v_metas_trimestre where trimestre = '2026-T4' and indicador = 'reservas') = 3,
         'el trimestre tiene sus tres meses desglosados';

  raise notice 'Todas las pruebas pasaron';
end $$;

rollback;
