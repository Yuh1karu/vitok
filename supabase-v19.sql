-- Виток 1.9. Выполни целиком в Supabase: SQL Editor -> New query -> Run.
-- Можно запускать повторно. Даёт приложению время сервера, чтобы смена времени на телефоне не давала искры.
create or replace function public.server_time()
returns timestamptz language sql stable as $$ select now() $$;
grant execute on function public.server_time() to anon, authenticated;
