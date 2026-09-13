-- =============================================================================
-- Seguridad para Supabase: solo el equipo (usuarios con sesión iniciada) puede
-- leer y escribir; la clave pública "anon" no ve nada.
-- Correr después de schema.sql, SOLO en Supabase (usa el rol "authenticated").
-- Para invitar a alguien del equipo: Authentication -> Users -> Invite user.
-- =============================================================================
do $$
declare t text;
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    raise exception 'Este script es solo para Supabase: falta el rol "authenticated". En una base local, sáltalo.';
  end if;
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists equipo_lee on public.%I', t);
    execute format('drop policy if exists equipo_escribe on public.%I', t);
    execute format('create policy equipo_lee on public.%I for select to authenticated using (true)', t);
    execute format('create policy equipo_escribe on public.%I for all to authenticated using (true) with check (true)', t);
  end loop;
end $$;

revoke all on all tables in schema public from anon;
revoke all on all functions in schema public from anon;
grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

-- Comprobación: cuántas tablas quedaron protegidas
select count(*) filter (where rowsecurity) as tablas_protegidas, count(*) as tablas_totales
from pg_tables t join pg_class c on c.relname = t.tablename
where t.schemaname = 'public';
