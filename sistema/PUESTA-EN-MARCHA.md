# Cómo poner el sistema a trabajar de verdad

Guía para pasar del prototipo (datos en el navegador, nombres inventados) al
sistema real: una base de datos compartida donde el equipo captura desde su
celular y nada se pierde.

---

## Lo que necesito de ti

Solo tres cosas dependen de ti. El resto lo hago yo.

### 1. Una cuenta de Supabase

Supabase es donde va a vivir la base de datos. Es el motor PostgreSQL para el
que ya está escrito y probado todo el esquema de `db/schema.sql`.

1. Entra a supabase.com y crea una cuenta con el correo de la empresa, no con
   uno personal. El día que alguien se vaya, la cuenta se queda.
2. Crea un proyecto. Ponle `el-cielo-adventures`.
3. Elige la región más cercana: `East US (North Virginia)` o `US West`.
4. Guarda la contraseña de la base de datos que te pida. No se puede recuperar,
   solo reiniciar.
5. Cuando termine de crearse, ve a **Project Settings → Database** y cópiame la
   cadena que dice **Connection string → URI**. Se ve así:
   `postgresql://postgres:[TU-CONTRASEÑA]@db.xxxxx.supabase.co:5432/postgres`
6. Ve a **Project Settings → API** y cópiame dos datos: **Project URL** y la
   llave **anon public**.

Con eso cargo tus datos reales y conecto la aplicación.

> La llave `anon public` es pública a propósito: va en el código del navegador.
> Lo que protege los datos son las políticas de acceso de `db/supabase_rls.sql`,
> que solo dejan entrar a quien inició sesión. La llave `service_role` **nunca**
> se comparte ni se usa en el navegador.

### 2. Decidir dónde vive el panel

Dos opciones, las dos usan el hosting que ya pagas:

| Opción | Dirección | Qué implica |
|---|---|---|
| Subcarpeta | elcielotamaulipas.org/panel | Nada nuevo que configurar, se publica con el mismo deploy |
| Subdominio | panel.elcielotamaulipas.org | Se crea en hPanel de Hostinger en cinco minutos, se ve más profesional |

Mi recomendación es el subdominio: deja claro que es la herramienta interna y no
se mezcla con el sitio de clientes.

### 3. Los correos del equipo

Dime el correo de cada persona que va a usarlo y qué debe poder hacer:

| Nombre | Correo | Qué necesita |
|---|---|---|
| (ejemplo) Andrés | andres@… | Atender leads, cotizar, registrar reservaciones |
| (ejemplo) Yussef | yussef@… | Todo, más editar precios y ver las finanzas |

Con eso configuro quién ve teléfonos completos, quién edita precios y plantillas,
y quién puede borrar.

---

## Lo que hago yo

1. **Crear la base** con los cuatro scripts que ya están probados.
2. **Cargar tus datos reales**: los leads, reservaciones, eventos y pagos que
   salieron del Excel, ya limpios.
3. **Conectar la aplicación a la base.** Es el trabajo grueso: hoy el prototipo
   guarda en el navegador, y hay que cambiarlo para que lea y escriba en
   Supabase, con sesión iniciada y datos compartidos entre todos.
4. **Publicarlo** en el hosting con el deploy automático que ya existe.
5. **Dejarte un respaldo automático** de la base y la forma de exportar todo a
   Excel cuando quieras.

---

## Cuánto cuesta

| Concepto | Costo |
|---|---|
| Supabase, plan gratuito | Sin costo |
| Supabase, plan Pro cuando lo necesiten | Alrededor de 25 dólares al mes |
| Hosting Hostinger | Ya lo pagas |
| Subdominio | Sin costo, va incluido |

El plan gratuito aguanta de sobra: tus 1,634 leads con todo su historial ocupan
una fracción de lo que incluye. El salto a Pro tiene sentido más adelante, sobre
todo por los respaldos diarios automáticos.

Aparte, si después conectamos la API de WhatsApp, Meta cobra por conversación.
Eso se decide cuando lleguemos ahí; confirma precios y condiciones vigentes con
Meta antes de comprometerte.

---

## Qué pasa con el Excel mientras tanto

Sigan usándolo hasta que les avise que el sistema está listo. El día del cambio:

1. Vuelvo a correr la migración con el Excel más reciente, para no perder lo que
   capturaron en el tiempo intermedio.
2. Cargo todo a la base.
3. Ese día el equipo deja de capturar en el Excel y empieza en el sistema.
4. El Excel se queda como respaldo histórico, en solo lectura.

No hay periodo de capturar en los dos lados. Eso siempre termina en datos que no
coinciden.

---

## Antes de arrancar, confirma esto con el equipo

Son los supuestos que tomé al limpiar el Excel. Si alguno está mal, se corrige
en minutos ahora y en horas después.

1. El paso `5.1` del registro viejo significaba **cancelado**.
2. Los pasos `6` y `7` significaban **cotización enviada** y **forma de pago
   enviada**.
3. El paso 4.1, leña y bicicletas, no tiene texto en la hoja. Hay que escribirlo.
4. Las cabañas anotadas como Yussef, Oliver y Cristal se dieron de alta como
   cabañas propias. Si son de terceros, se marcan distinto.
5. Las metas cargadas son de septiembre a diciembre de 2026. Confirmen las
   cifras del trimestre con Dirección.
6. Los precios del cotizador salen del Excel para cabañas. Transporte y
   actividades son de ejemplo y hay que poner los reales.

---

## Después de la primera semana en uso

Cosas que conviene decidir cuando ya lo estén usando, no antes:

- Conectar la API de WhatsApp para que los mensajes entrantes creen el lead solos.
- Publicar el calendario de disponibilidad en el sitio.
- Sincronizar con Airbnb por iCal para no dobletear reservas.
- El aviso diario al grupo con la lista de hoy.

Están descritas en el README, en la lista de propuestas.
