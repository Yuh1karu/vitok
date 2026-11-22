-- Виток 2.0. Выполни целиком в Supabase: SQL Editor -> New query -> Run. Можно запускать повторно.
-- Даёт: удаление аккаунта, админку (объявления, подарки искр, удаление пользователей).

create or replace function public.is_admin() returns boolean
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email',''))='danildengin874@gmail.com' $$;

-- Объявления для всех
create table if not exists public.announcements(id bigserial primary key, text text not null, created_at timestamptz default now());
alter table public.announcements enable row level security;
grant select on public.announcements to authenticated;
grant insert, delete on public.announcements to authenticated;
grant usage, select on sequence public.announcements_id_seq to authenticated;
drop policy if exists ann_read on public.announcements;
create policy ann_read on public.announcements for select to authenticated using (true);
drop policy if exists ann_admin on public.announcements;
create policy ann_admin on public.announcements for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- Подарки искр
create table if not exists public.gifts(id bigserial primary key, user_id uuid not null, amount int not null check (amount between 1 and 1000), note text, claimed boolean not null default false, created_at timestamptz default now());
alter table public.gifts enable row level security;
grant select, insert on public.gifts to authenticated;
grant usage, select on sequence public.gifts_id_seq to authenticated;
drop policy if exists gifts_read on public.gifts;
create policy gifts_read on public.gifts for select to authenticated using (user_id = auth.uid() or public.is_admin());
drop policy if exists gifts_admin_ins on public.gifts;
create policy gifts_admin_ins on public.gifts for insert to authenticated with check (public.is_admin());

create or replace function public.claim_gifts() returns int
language plpgsql security definer set search_path = public as $$
declare s int;
begin
  if auth.uid() is null then return 0; end if;
  with c as (update public.gifts set claimed = true where user_id = auth.uid() and not claimed returning amount)
  select coalesce(sum(amount),0) into s from c;
  return s;
end $$;
revoke all on function public.claim_gifts() from public, anon;
grant execute on function public.claim_gifts() to authenticated;

-- Полное удаление пользователя
create or replace function public._wipe_user(uid uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
declare r record;
begin
  for r in select c.table_name from information_schema.columns c
    join information_schema.tables t on t.table_schema = c.table_schema and t.table_name = c.table_name
    where c.table_schema = 'public' and c.column_name = 'user_id' and t.table_type = 'BASE TABLE'
  loop
    execute format('delete from public.%I where user_id = $1', r.table_name) using uid;
  end loop;
  delete from public.friendships where friend_id = uid;
  delete from auth.users where id = uid;
end $$;
revoke all on function public._wipe_user(uuid) from public, anon, authenticated;

create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  perform public._wipe_user(auth.uid());
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

create or replace function public.admin_delete_user(uid uuid) returns void
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  perform public._wipe_user(uid);
end $$;
revoke all on function public.admin_delete_user(uuid) from public, anon;
grant execute on function public.admin_delete_user(uuid) to authenticated;
