-- Виток 2.3. Выполни целиком в Supabase: SQL Editor -> New query -> Run. Можно запускать повторно.
-- Премиум: стикер у ника и значок. Всё проверяется на сервере, подделать через приложение нельзя.

alter table public.profiles add column if not exists sticker text;
alter table public.profiles add column if not exists premium_until timestamptz;

-- Охранник профиля: клиент не может сам себе выдать премиум и не может поставить стикер без премиума
create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare adm boolean := lower(coalesce(auth.jwt()->>'email','')) = 'danildengin874@gmail.com';
begin
  if coalesce(auth.role(), '') in ('', 'service_role') then return new; end if;  -- SQL Editor / сервер
  if coalesce(current_setting('vitok.bypass', true), '') <> '1' then
    if tg_op = 'INSERT' then new.premium_until := null; else new.premium_until := old.premium_until; end if;
  end if;
  if adm and auth.uid() = new.user_id then new.premium_until := '2100-01-01'; end if;
  if new.sticker is not null and (
       length(new.sticker) > 80000
       or new.sticker !~ '^data:image/(jpeg|png|webp);base64,'
       or not (adm or (new.premium_until is not null and new.premium_until > now()))
     ) then
    new.sticker := null;
  end if;
  return new;
end $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- Выдача и снятие премиума (только админ). days <= 0 снимает.
create or replace function public.admin_set_premium(uid uuid, days int) returns timestamptz
language plpgsql security definer set search_path = public as $$
declare r timestamptz;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  perform set_config('vitok.bypass', '1', true);
  if days <= 0 then
    update public.profiles set premium_until = null, sticker = null where user_id = uid returning premium_until into r;
  else
    update public.profiles
      set premium_until = greatest(coalesce(premium_until, now()), now()) + make_interval(days => days)
      where user_id = uid returning premium_until into r;
  end if;
  return r;
end $$;
revoke all on function public.admin_set_premium(uuid, int) from public, anon;
grant execute on function public.admin_set_premium(uuid, int) to authenticated;

-- Админу премиум навсегда
update public.profiles set premium_until = '2100-01-01'
where user_id in (select id from auth.users where lower(email) = 'danildengin874@gmail.com');
