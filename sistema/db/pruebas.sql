-- =============================================================================
-- Pruebas del motor de embudo. Corren dentro de una transacción que se
-- revierte al final: no dejan datos. Requieren schema.sql y el seed de pasos.
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f pruebas.sql
-- =============================================================================
\set ON_ERROR_STOP on
begin;

do $$
declare l leads; r reservaciones; n int;
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

  raise notice 'Todas las pruebas pasaron';
end $$;

rollback;
