-- Виток 1.8. Выполни целиком в Supabase: SQL Editor -> New query -> Run.
-- Можно запускать повторно. Сначала должен быть выполнен supabase-v17.sql.

-- 1. Сводка прогресса, которую видят друзья
alter table profiles add column if not exists stats jsonb;

-- 2. Друзья
create table if not exists friendships (
  user_id uuid not null,
  friend_id uuid not null,
  status text not null default 'pending',
  created_at timestamptz default now(),
  primary key (user_id, friend_id)
);
alter table friendships enable row level security;
grant select, insert, update, delete on friendships to authenticated;

drop policy if exists "fr select" on friendships;
create policy "fr select" on friendships for select to authenticated
  using (auth.uid() in (user_id, friend_id));
drop policy if exists "fr insert" on friendships;
create policy "fr insert" on friendships for insert to authenticated
  with check (user_id = auth.uid() and friend_id <> auth.uid());
drop policy if exists "fr accept" on friendships;
create policy "fr accept" on friendships for update to authenticated
  using (friend_id = auth.uid()) with check (friend_id = auth.uid());
drop policy if exists "fr delete" on friendships;
create policy "fr delete" on friendships for delete to authenticated
  using (auth.uid() in (user_id, friend_id));
