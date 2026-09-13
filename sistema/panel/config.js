// Configuración de la conexión con Supabase.
// Estos dos datos son públicos a propósito: viajan dentro del navegador de cada
// usuario. Lo que protege la información son las políticas de acceso de
// db/supabase_rls.sql, que solo dejan leer y escribir a quien inició sesión.
// NUNCA poner aquí la llave service_role, una que empiece con sb_secret_, ni la
// contraseña de la base de datos.
window.CONFIG = {
  url: 'https://melklsbhzzhbidjrchwy.supabase.co',
  key: 'sb_publishable_Cg6CGpxP8nLyDrY8js8lqQ_5vQ_SpV5',
  proyecto: 'El Cielo Adventures'
};
