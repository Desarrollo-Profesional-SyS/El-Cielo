# Sistema de leads, embudo y reservaciones · El Cielo Adventures

Reemplaza el Excel "Embudo y Registro Leads" por una base de datos con reglas
y una aplicación para el equipo. Esta carpeta contiene la **fase 1**: el modelo
de datos, el motor del embudo, la migración de los datos actuales y un prototipo
navegable de la pantalla principal.

```
sistema/
├── README.md                 este documento
├── db/
│   ├── schema.sql            tablas, funciones (motor de embudo) y vistas
│   ├── pruebas.sql           pruebas del motor; corren y se revierten solas
│   ├── cargar_csv.sql        carga en la base lo que genera la migración
│   └── supabase_rls.sql      permisos: solo el equipo con sesión iniciada
├── migracion/
│   ├── limpiar_excel.py      lee el Excel, limpia y genera CSV + reporte
│   └── salida/               (ignorada por git: trae teléfonos de clientes)
└── prototipo/
    └── index.html            demo de la "lista de hoy" con datos ficticios
```

## Qué llevaba el Excel y a dónde va

| Hojas del Excel | En el sistema |
|---|---|
| Registro leads | `leads` (uno por celular) + `seguimientos` (historial) |
| Embudo Nuevo, Embudo San José, Embudo Gómez F, Cancelar 2 | `pasos_embudo` (plantillas y reglas, editables) |
| Feedback Diario de Leads | vista `v_semana`, se calcula sola |
| Reservaciones | `reservaciones`, `pagos`, `gastos_reserva`, `checklist_reserva` |
| Reservaciones Eventos, Eventos | `eventos`, `evento_tareas` (proceso por fases), `inscripciones`, `pagos`, `gastos_evento` |
| Cabañas, Marzo | `cabanas`, vista `v_ocupacion` |
| Hoja 7 (metas SMART) | `metas`, vista `v_mes` |
| Plan Trabajo | pendiente (fase 4, checklist diario) |

## Cómo funciona el motor del embudo

Cada renglón de `pasos_embudo` sabe cuatro cosas: el mensaje que se manda, cuántos
días esperar antes de volver a revisar, a qué paso ir si el lead contesta y a qué
paso ir si no contesta. La regla `2|3` significa "2 si va a Gómez Farías, 3 si va
a San José". Los pasos se editan como datos, sin tocar código.

| Paso | Mensaje | Espera | Contesta → | No contesta → |
|---|---|---:|---|---|
| 1 | Mensaje inicial | 1 día | 2 ó 3 según destino | 2.1 |
| 2 | Info Gómez Farías | 1 | 5 | 2.1 |
| 3 | Info San José | 1 | 6 | 2.1 |
| 4 | Preguntar personas y fecha | 1 | 5 ó 6 | 2.1 |
| 5 | Cotización Gómez Farías | 1 | 7 | 3.1 |
| 6 | Cotización San José | 1 | 7 | 3.1 |
| 7 | Recomendación de apartar | 1 | 8 | 4.1 |
| 8 | Métodos de pago | 1 | 9 | 4.1 |
| 9 | Instrucciones de llegada | — | cierra como **reservó** | |
| 2.1 | ¿Todavía te interesa? | 1 | 5 ó 6 | 3.1 |
| 3.1 | Contenido de valor | 2 | 8 | 4.1 |
| 4.1 | Leña + bicicletas | 3 | 8 | 5.1 |
| 5.1 | Oferta 10 % | 3 | 8 | 6.1 |
| 6.1 | Despedida | — | cierra como **cancelado** | |

Las funciones que usa la aplicación:

| Función | Qué hace |
|---|---|
| `registrar_lead(celular, destino, nombre, origen, personas, noches, mes, comentarios, usuario)` | Crea el lead en el paso 1 para hoy. Si el celular ya existía, lo reactiva o anota que volvió a escribir. Normaliza el celular (+52, espacios, guiones). |
| `avanzar_lead(id)` | "Ya mandé el mensaje del paso actual": programa la siguiente revisión. |
| `avanzar_lead(id, true)` / `avanzar_lead(id, false)` | Contestó / no contestó: mueve al siguiente paso, registra el envío del nuevo mensaje y calcula la próxima fecha. Si el paso es final, cierra el lead. |
| `mover_lead(id, codigo)` | Mover a mano a cualquier paso, o reactivar uno cerrado. |
| `cerrar_lead(id, estado)` | Cancelar o archivar sin pasar por el embudo. |
| `convertir_lead_en_reserva(id, cabana, llegada, salida, total, anticipo)` | Crea la reservación con su checklist de 12 tareas, registra el anticipo y cierra el lead como reservó. Rechaza traslapes de cabaña. |
| `registrar_pago_reserva(reserva, monto)` | Registra un pago; si completa el total, la reservación pasa a liquidada. |

## Cómo funciona el proceso de un evento

Al insertar un evento con fecha, un trigger le cuelga las tareas del catálogo
`evento_tareas_catalogo` con su fecha límite (`fecha del evento - días antes`) y
un responsable sugerido. Si la fecha del evento cambia, las tareas pendientes se
recorren solas. Las fases son planeación, difusión, inscripciones, logística,
día del evento y cierre; el catálogo se edita como datos. La vista
`v_evento_resumen` da inscritos, esperado, cobrado, gastos (fijos más costo por
persona), ganancia y tareas pendientes o vencidas. Los pagos de inscritos se
registran con `registrar_pago_inscripcion`.

Las vistas que alimentan las pantallas: `v_lista_hoy` (a quién le toca mensaje
hoy, con la plantilla y los dos pasos posibles), `v_embudo` (cuántos hay en cada
paso), `v_historial`, `v_reserva_resumen` (pagado, saldo, gastos, ganancia,
checklist pendiente), `v_inscripcion_resumen`, `v_semana` (leads nuevos,
mensajes, cotizaciones, respuestas, reservas por semana), `v_mes` (ingresos y
ganancia por mes contra la meta) y `v_ocupacion` (para el calendario).

## Cómo migrar los datos del Excel

Requiere Python 3 con `openpyxl` (`pip install openpyxl`) y el cliente `psql`.

```bash
cd sistema/migracion
python3 limpiar_excel.py "ruta/Embudo_y_Registro_Leads_El_Cielo_Adventures.xlsx"
# revisa salida/reporte.md: qué se limpió, qué se descartó y qué conviene confirmar

psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../db/schema.sql        # una sola vez, base vacía
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../db/pruebas.sql       # debe decir "Todas las pruebas pasaron"
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../db/cargar_csv.sql    # carga pasos, leads, reservas, eventos
psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f ../db/supabase_rls.sql  # solo en Supabase
```

`DATABASE_URL` es la cadena de conexión de Supabase (Project Settings → Database).
Todo el proceso se probó con PostgreSQL 16 sobre el Excel del 13 de septiembre de 2026.

Lo que hace la limpieza:

- Deja cada celular en 10 dígitos y separa la lada de país (México 52, Estados Unidos 1).
- Une las filas repetidas del mismo celular; la más reciente manda y los comentarios se conservan.
- Normaliza las 25 formas de escribir el destino a San José, Gómez Farías, Camping, Tours o Evento.
- Recupera los pasos que Google Sheets convirtió en fecha (`5.1` guardado como 5 de enero).
- Deriva el estado: reservó, cancelado, archivado (sin movimiento en 30 días) o activo.
- Traduce el paso del embudo anterior al nuevo solo para los leads activos.
- Corrige fechas de salida capturadas con el mes equivocado y deja constancia en comentarios.
- Descarta filas sin celular (nombres en la columna de teléfono) y las lista en el reporte.

## Supuestos que conviene confirmar con el equipo

- El paso `5.1` del registro era "cancelado" en los embudos anteriores; así se migró.
- Los pasos `6` y `7` del registro se leyeron como "cotización enviada" y "forma de pago enviada".
- El paso 4.1 (leña + bicicletas) no tiene texto en la hoja; hay que escribirlo en `pasos_embudo`.
- Las metas SMART se cargaron para septiembre a noviembre de 2026; ajustar si el año es otro.
- Las cabañas anotadas como "Yussef", "Oliver" y "Cristal" se dieron de alta como cabañas
  propias; si son de terceros, marcar `activa = false` o renombrar.

## Arquitectura propuesta

- **Base de datos:** Supabase (PostgreSQL, login, permisos por fila). Este esquema corre tal cual.
- **Aplicación:** frontend estático en este repositorio, en `public_html/panel/`, publicado con el
  mismo deploy por FTP a Hostinger. Habla con Supabase con `supabase-js` desde el navegador; no
  hay servidor propio que mantener.
- **Acceso:** usuarios invitados desde Supabase Authentication; `supabase_rls.sql` deja fuera a
  cualquiera sin sesión.
- **WhatsApp, etapa 1:** el botón de cada lead abre `wa.me/<lada><celular>?text=<plantilla>` con el
  mensaje del paso ya escrito. No requiere nada de Meta y funciona con el número actual en la
  app de WhatsApp Business.
- **WhatsApp, etapa 2:** API de WhatsApp Cloud para que cada mensaje entrante (incluidos los que
  llegan de los anuncios) cree el lead solo, con el anuncio como origen. Requiere verificar el
  negocio en Meta y confirmar con un proveedor si el número puede convivir en la app y en la API.

## Pantallas

| Pantalla | Vista o función que usa |
|---|---|
| Lista de hoy | `v_lista_hoy`, `avanzar_lead` |
| Registrar lead | `registrar_lead` |
| Ficha del lead | `leads`, `v_historial`, `mover_lead`, `cerrar_lead`, `convertir_lead_en_reserva` |
| Embudo (editar pasos y plantillas) | `pasos_embudo`, `v_embudo` |
| Calendario de ocupación | `v_ocupacion`, `cabana_disponible` |
| Reservación | `v_reserva_resumen`, `checklist_reserva`, `registrar_pago_reserva`, `gastos_reserva` |
| Eventos | `v_evento_resumen`, `evento_tareas`, `v_inscripcion_resumen`, `gastos_evento` |
| Metas | `metas` (avance calculado desde reservaciones, eventos y leads) |
| Tablero | `v_semana`, `v_mes`, `v_embudo`, `metas`, `v_evento_resumen` |

## Fases

1. **Hecho:** modelo de datos, motor de embudo con pruebas, proceso de eventos, migración del Excel, prototipo.
2. Lista de hoy, registro y edición de leads, ficha e historial, tablero básico, login.
3. Calendario, reservaciones con pagos y checklist, gastos y ganancia.
4. Eventos con proceso e inscritos, metas, checklist diario del plan de trabajo, API de WhatsApp.

## Propuestas para que el sistema sea más eficiente

Por orden de impacto sobre la operación diaria:

1. **Captura automática desde WhatsApp.** Con la API de WhatsApp Cloud cada mensaje entrante crea el lead solo, con el anuncio de Meta como origen, y el paso 1 se responde en segundos aunque sea de madrugada.
2. **Aviso diario al equipo.** A las 9:00 llega al grupo la lista de hoy (cuántos leads, cuáles con retraso, tareas de eventos vencidas, anticipos por liquidar). Sustituye los screenshots del plan de trabajo.
3. **Cotizador.** Precio automático por cabaña, personas, noches, temporada, transporte 4x4 y tours; genera el mensaje de cotización con fotos. Elimina errores de monto y acelera el paso 5 y 6.
4. **Plantillas con variables.** `{nombre}`, `{personas}`, `{fecha}`, `{monto}` en cada paso para que el mensaje llegue personalizado sin editarlo a mano.
5. **Calendario de disponibilidad en el sitio** y sincronización con Airbnb por iCal, para evitar dobles reservas y vender sin pedir fechas por chat.
6. **Formulario de reserva en la web** que registre el lead o la reservación directo en la base, con el sitio que ya existe.
7. **Links de pago** (Mercado Pago, Clip o Stripe) en el paso 8 y conciliación automática de anticipos y liquidaciones.
8. **Motivo de cancelación estructurado** (precio, fechas, sin 4x4, distancia, no contestó) para saber por qué se pierden leads y ajustar oferta y anuncios.
9. **Post-estancia automático.** Un día después del check-out: mensaje de agradecimiento, encuesta corta y liga a la reseña de Google; la meta de reseñas se alimenta sola.
10. **Remarketing con la base.** Exportar leads cancelados o archivados como público personalizado de Meta para promociones de temporada, y lista de exhuéspedes para eventos.
11. **Métricas por persona.** Tiempo de primera respuesta, leads atendidos y conversión por quien atiende; turnos y asignación automática de leads nuevos.
12. **Incidencias y mantenimiento por cabaña.** Registrar problemas (plagas, fugas, faltantes), consumibles y leña; el checklist de salida los alimenta.
13. **Reporte semanal automático** por correo o WhatsApp: leads, cotizaciones, conversión, ingresos, avance de metas y eventos.
14. **Roles y permisos.** Quién ve teléfonos completos, quién edita precios y plantillas, quién borra.
15. **Respaldo y exportación** a Excel o Google Sheets con un clic, para quien prefiera analizar ahí.
16. **Plan de trabajo diario** como checklist con evidencia (la hoja Plan Trabajo), ligado a las tareas de eventos y al calendario de publicaciones.
