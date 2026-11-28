-- Виток 3.0: ВСЕ SQL-миграции в одном файле (заменяет supabase-v18 ... v25).
-- Как запускать: Supabase -> SQL Editor -> New query -> вставить весь файл -> Run.
-- Можно запускать повторно, ничего не сломается.
-- Единственное условие: таблица profiles уже должна существовать (её создаёт старый supabase-v17.sql).


-- ===== 1. Друзья и сводка прогресса (v18) =====

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

-- ===== 2. Время сервера против накрутки искр (v19) =====

create or replace function public.server_time()
returns timestamptz language sql stable as $$ select now() $$;
grant execute on function public.server_time() to anon, authenticated;

-- ===== 3. Админка, подарки искр, удаление аккаунта (v20) =====

-- Админ определяется по auth.users и только с ПОДТВЕРЖДЁННОЙ почтой (иначе можно зарегистрироваться на чужой адрес без подтверждения).
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists(select 1 from auth.users u where u.id = auth.uid() and lower(u.email) = 'danildengin874@gmail.com' and u.email_confirmed_at is not null)
$$;
grant execute on function public.is_admin() to anon, authenticated;

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
  -- подарки и награды сезона не должны давать очки в рейтинге сезона
  if s > 0 then
    update public.vitok_guard set season_skip = season_skip + s where user_id = auth.uid() and profile = 'main';
  end if;
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

-- ===== 4. Колонки профиля: премиум, стикер, эффекты, тема, соцсети (v21, v22, v25) =====

alter table public.profiles add column if not exists sticker text;
alter table public.profiles add column if not exists premium_until timestamptz;

alter table public.profiles add column if not exists fx jsonb;
alter table public.profiles add column if not exists theme jsonb;
alter table public.profiles add column if not exists socials jsonb;

-- ===== 5. Охранник профиля: премиум, ник до 16/20 знаков, стикер-картинка, fx, тема (v21-v24) =====

create or replace function public.profiles_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  adm boolean := public.is_admin();
  prem boolean;
  maxlen int;
begin
  if coalesce(auth.role(), '') in ('', 'service_role') then
    return new;
  end if;

  if coalesce(current_setting('vitok.bypass', true), '') <> '1' then
    if tg_op = 'INSERT' then
      new.premium_until := null;
    else
      new.premium_until := old.premium_until;
    end if;
  end if;

  if adm and auth.uid() = new.user_id then
    new.premium_until := '2100-01-01';
  end if;

  prem := adm or (new.premium_until is not null and new.premium_until > now());

  maxlen := 16;
  if prem then
    maxlen := 20;
  end if;

  if new.username is not null and length(new.username) > maxlen then
    if tg_op = 'INSERT' then
      raise exception 'nick_too_long';
    elsif new.username is distinct from old.username then
      raise exception 'nick_too_long';
    end if;
  end if;

  -- Ник (и дополнительные ники) должен содержать хотя бы одну букву: только из цифр/подчёркиваний нельзя.
  if new.username is not null and (tg_op = 'INSERT' or new.username is distinct from old.username) and new.username !~ '[A-Za-z]' then
    raise exception 'nick_digits';
  end if;
  if new.alt_usernames is not null and (tg_op = 'INSERT' or new.alt_usernames is distinct from old.alt_usernames) then
    if exists (select 1 from unnest(string_to_array(trim(new.alt_usernames), ' ')) as a(x) where x <> '' and x !~ '[A-Za-z]') then
      raise exception 'nick_digits';
    end if;
  end if;

  if new.sticker is not null then
    if not prem then
      new.sticker := null;
    elsif new.sticker ~ '^data:image/(jpeg|png|webp);base64,' then
      if length(new.sticker) > 80000 then
        new.sticker := null;
      end if;
    else
      new.sticker := null;
    end if;
  end if;

  if new.fx is not null then
    if (not prem) or jsonb_typeof(new.fx) <> 'object' or length(new.fx::text) > 600 then
      new.fx := null;
    end if;
  end if;

  if new.theme is not null then
    if jsonb_typeof(new.theme) <> 'object' or length(new.theme::text) > 1500 then
      new.theme := null;
    end if;
  end if;

  return new;
end
$$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard before insert or update on public.profiles
  for each row execute function public.profiles_guard();

-- ===== 6. Охранник соцсетей (v25) =====

create or replace function public.profiles_socials_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.socials is not null then
    if jsonb_typeof(new.socials) <> 'object' or length(new.socials::text) > 900 then
      new.socials := null;
    end if;
  end if;
  return new;
end
$$;

drop trigger if exists profiles_socials_guard on public.profiles;
create trigger profiles_socials_guard before insert or update on public.profiles
  for each row execute function public.profiles_socials_guard();

-- ===== 7. Выдача премиума админом (v21) =====

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

-- ===== 8. Защита от накрутки искр (v26) =====
-- Искры считаются в приложении, поэтому сервер не верит присланному числу, а проверяет его:
--   1) «Запас прироста»: искры могут расти не быстрее RATE в секунду (запас копится, максимум CAP).
--   2) Потраченное (spent) только растёт: «вернуть» потраченные искры нельзя.
--   3) Всё лишнее срезается, а не отклоняется, поэтому честный пользователь ничего не ломает.
--   4) Рейтинг друзей: искры, серия и минуты в сводке профиля ограничиваются серверными данными.
--   5) Премиум за искры покупается по серверному балансу, а не по сводке, которую можно подделать.
-- Настройка: меняй rate / cap / first_cap в vitok_data_guard() ниже и запускай файл ещё раз.

create table if not exists public.vitok_guard(
  user_id uuid not null,
  profile text not null,
  earned numeric not null default 0,
  spent numeric not null default 0,
  budget numeric not null default 0,
  clamped numeric not null default 0,
  last_clamp timestamptz,
  season_skip numeric not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, profile)
);
alter table public.vitok_guard add column if not exists season_skip numeric not null default 0;
alter table public.vitok_guard enable row level security;
revoke all on public.vitok_guard from anon, authenticated;

create or replace function public.vitok_data_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rate      constant numeric := 0.025;  -- искр в секунду (около 2160 в сутки, честный максимум с премиумом и ускорителем заметно ниже)
  cap       constant numeric := 4000;   -- максимум накопленного запаса (хватает на достижения и подарки)
  first_cap constant numeric := 4000;   -- сколько можно загрузить при самой первой синхронизации (прогресс, набранный без аккаунта)
  g public.vitok_guard%rowtype;
  od jsonb;
  ne numeric; ns numeric; inc numeric; allowed numeric; cut numeric := 0;
  first boolean := false; sk numeric;
begin
  if coalesce(auth.role(), '') in ('', 'service_role') then
    return new;
  end if;
  if new.data is null or jsonb_typeof(new.data) <> 'object' then
    raise exception 'bad_data';
  end if;

  ne := greatest(case when jsonb_typeof(new.data->'earned') = 'number' then floor((new.data->>'earned')::numeric) else 0 end, 0);
  ns := greatest(case when jsonb_typeof(new.data->'spent')  = 'number' then floor((new.data->>'spent')::numeric)  else 0 end, 0);

  select * into g from public.vitok_guard where user_id = new.user_id and profile = new.profile for update;
  if not found then
    -- Старый пользователь (данные уже в облаке): за основу берём то, что там лежит. Новый: стартуем с нуля.
    select data into od from public.vitok_data where user_id = new.user_id and profile = new.profile;
    g.user_id := new.user_id; g.profile := new.profile;
    g.clamped := 0; g.last_clamp := null; g.updated_at := now();
    if od is not null then
      g.earned := greatest(case when jsonb_typeof(od->'earned') = 'number' then floor((od->>'earned')::numeric) else 0 end, 0);
      g.spent  := greatest(case when jsonb_typeof(od->'spent')  = 'number' then floor((od->>'spent')::numeric)  else 0 end, 0);
      g.budget := cap;
    else
      g.earned := 0; g.spent := 0; g.budget := first_cap;
      first := true;  -- самая первая загрузка не считается в очки сезона
    end if;
    g.season_skip := 0;
    insert into public.vitok_guard(user_id, profile, earned, spent, budget, clamped, last_clamp, updated_at)
      values (g.user_id, g.profile, g.earned, g.spent, g.budget, 0, null, g.updated_at)
      on conflict (user_id, profile) do nothing;
  end if;

  g.budget := least(cap, g.budget + greatest(0, extract(epoch from (now() - g.updated_at))) * rate);

  inc := ne - g.earned;
  if inc > 0 then
    allowed := floor(g.budget);
    if inc > allowed then cut := inc - allowed; inc := allowed; end if;
    g.budget := g.budget - inc;
  elsif inc < 0 then
    -- откат (человек снял отметку): запас возвращается, итог не меняется
    g.budget := least(cap, g.budget - inc);
  end if;
  g.earned := g.earned + inc;

  -- очки сезона = заработанные за месяц искры, уже прошедшие проверку выше (подарки не считаются)
  if inc <> 0 and not first and new.profile = 'main' then
    sk := least(g.season_skip, greatest(inc, 0));
    g.season_skip := g.season_skip - sk;
    insert into public.season_scores(season, user_id, score)
      values (public.season_key(), new.user_id, greatest(inc - sk, 0))
      on conflict (season, user_id) do update
        set score = greatest(0, public.season_scores.score + (inc - sk));
  end if;

  -- потрачено: только вверх и не больше заработанного
  ns := greatest(g.spent, least(greatest(ns, g.spent), g.earned));
  g.spent := ns;

  new.data := jsonb_set(jsonb_set(new.data, '{earned}', to_jsonb(g.earned)), '{spent}', to_jsonb(g.spent));

  update public.vitok_guard
     set earned = g.earned, spent = g.spent, budget = g.budget, season_skip = g.season_skip,
         clamped = clamped + cut,
         last_clamp = case when cut > 0 then now() else last_clamp end,
         updated_at = now()
   where user_id = new.user_id and profile = new.profile;
  return new;
end
$$;

drop trigger if exists vitok_data_guard on public.vitok_data;
create trigger vitok_data_guard before insert or update on public.vitok_data
  for each row execute function public.vitok_data_guard();

-- Те, кто уже есть в облаке, получают исходную точку (то, что у них сейчас лежит) и полный запас прироста.
insert into public.vitok_guard(user_id, profile, earned, spent, budget)
select d.user_id, d.profile,
       greatest(case when jsonb_typeof(d.data->'earned') = 'number' then floor((d.data->>'earned')::numeric) else 0 end, 0),
       greatest(case when jsonb_typeof(d.data->'spent')  = 'number' then floor((d.data->>'spent')::numeric)  else 0 end, 0),
       4000
  from public.vitok_data d
on conflict (user_id, profile) do nothing;

-- Сводка профиля (её видят друзья): искры не больше серверного баланса, минуты не больше 24 ч в день, серия растёт не быстрее 1 в сутки.
create or replace function public.profiles_stats_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  bal numeric; sp numeric; st numeric; allow numeric; arr jsonb;
begin
  if coalesce(auth.role(), '') in ('', 'service_role') then
    return new;
  end if;
  if new.stats is null then
    return new;
  end if;
  if jsonb_typeof(new.stats) <> 'object' or length(new.stats::text) > 6000 then
    new.stats := null;
    return new;
  end if;

  if new.stats ? 'spark' then
    select g.earned - g.spent into bal from public.vitok_guard g where g.user_id = new.user_id and g.profile = 'main';
    bal := greatest(coalesce(bal, 0), 0);
    sp := case when jsonb_typeof(new.stats->'spark') = 'number' then (new.stats->>'spark')::numeric else 0 end;
    new.stats := jsonb_set(new.stats, '{spark}', to_jsonb(least(greatest(sp, 0), bal)));
  end if;

  if new.stats ? 'streak' then
    st := case when jsonb_typeof(new.stats->'streak') = 'number' then (new.stats->>'streak')::numeric else 0 end;
    if tg_op = 'UPDATE' and old.stats is not null
       and jsonb_typeof(old.stats->'sts') = 'number' and jsonb_typeof(old.stats->'streak') = 'number' then
      allow := (old.stats->>'streak')::numeric + floor((extract(epoch from now()) - (old.stats->>'sts')::numeric) / 86400) + 1;
    else
      allow := 365;  -- первая публикация: серию, набранную без аккаунта, не проверить
    end if;
    new.stats := jsonb_set(new.stats, '{streak}', to_jsonb(greatest(0, least(st, allow))));
  end if;

  if jsonb_typeof(new.stats->'wk') = 'array' then
    select coalesce(jsonb_agg(
             least(greatest(case when jsonb_typeof(t.e) = 'number' then (t.e #>> '{}')::numeric else 0 end, 0), 1440)
             order by t.o), '[]'::jsonb)
      into arr
      from jsonb_array_elements(new.stats->'wk') with ordinality as t(e, o)
     where t.o <= 7;
    new.stats := jsonb_set(new.stats, '{wk}', arr);
  end if;

  new.stats := new.stats || jsonb_build_object('sts', extract(epoch from now()));
  return new;
end
$$;

drop trigger if exists profiles_stats_guard on public.profiles;
create trigger profiles_stats_guard before insert or update on public.profiles
  for each row execute function public.profiles_stats_guard();

-- Покупка премиума за 10000 искр: +30 дней (можно продлевать, но не дальше чем на год вперёд).
-- Баланс берётся с сервера (vitok_guard), списание делается тут же, поэтому подделанная сводка не поможет.
create or replace function public.buy_premium_sparks() returns timestamptz
language plpgsql security definer set search_path = public as $$
declare
  price int := 10000;
  g public.vitok_guard%rowtype;
  r timestamptz;
begin
  if auth.uid() is null then raise exception 'auth'; end if;
  select * into g from public.vitok_guard where user_id = auth.uid() and profile = 'main' for update;
  if not found or g.earned - g.spent < price then raise exception 'not_enough'; end if;
  if (select premium_until from public.profiles where user_id = auth.uid()) > now() + interval '335 days' then
    raise exception 'too_far';
  end if;
  perform set_config('vitok.bypass', '1', true);
  update public.profiles
     set premium_until = greatest(coalesce(premium_until, now()), now()) + interval '30 days'
   where user_id = auth.uid()
   returning premium_until into r;
  if not found then raise exception 'no_profile'; end if;
  -- списание: триггер vitok_data_guard примет рост spent (баланс уже проверен выше)
  update public.vitok_data
     set data = jsonb_set(data, '{spent}', to_jsonb(g.spent + price))
   where user_id = auth.uid() and profile = 'main';
  return r;
end $$;
revoke all on function public.buy_premium_sparks() from public, anon;
grant execute on function public.buy_premium_sparks() to authenticated;

-- ===== 9. Инструменты админа против накрутки (v26) =====

-- Кого сервер уже ловил на накрутке (срезанные искры) и у кого заработано слишком много для возраста аккаунта.
create or replace function public.admin_suspects()
returns table(uid uuid, nick text, earned_total numeric, spent_total numeric, clamped_total numeric, last_clamp_at timestamptz, age_days numeric)
language plpgsql security definer set search_path = public, auth as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  return query
    select g.user_id, p.username, g.earned, g.spent, g.clamped, g.last_clamp,
           round((extract(epoch from (now() - u.created_at)) / 86400)::numeric, 1)
      from public.vitok_guard g
      left join public.profiles p on p.user_id = g.user_id
      left join auth.users u on u.id = g.user_id
     where g.profile = 'main'
       and (g.clamped > 0 or g.earned > 2500 * greatest(1, extract(epoch from (now() - u.created_at)) / 86400))
     order by g.clamped desc, g.earned desc
     limit 50;
end $$;
revoke all on function public.admin_suspects() from public, anon;
grant execute on function public.admin_suspects() to authenticated;

-- Обнулить искры нарушителя (to_earned = сколько оставить заработанным; запас прироста тоже обнуляется).
create or replace function public.admin_reset_sparks(target uuid, to_earned int default 0)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  insert into public.vitok_guard(user_id, profile, earned, spent, budget)
    values (target, 'main', greatest(to_earned, 0), 0, 0)
    on conflict (user_id, profile) do update
      set earned = greatest(to_earned, 0), spent = 0, budget = 0, updated_at = now();
  update public.vitok_data
     set data = jsonb_set(jsonb_set(data, '{earned}', to_jsonb(greatest(to_earned, 0))), '{spent}', to_jsonb(0))
   where user_id = target and profile = 'main';
end $$;
revoke all on function public.admin_reset_sparks(uuid, int) from public, anon;
grant execute on function public.admin_reset_sparks(uuid, int) to authenticated;

-- ===== 10. Защита от спама и перегрузки (v27) =====
-- Это защита на уровне базы: лимиты на запись и размеры данных.
-- От настоящего DDoS (поток запросов из сети) она не спасёт: для этого включи защиту в самом Supabase
-- (Authentication -> Rate Limits и CAPTCHA при регистрации) и поставь сайт за Cloudflare.

create table if not exists public.rate_hits(
  key text not null,
  bucket bigint not null,
  n int not null default 0,
  at timestamptz not null default now(),
  primary key (key, bucket)
);
alter table public.rate_hits enable row level security;
revoke all on public.rate_hits from anon, authenticated;

-- Считает обращения за окно win секунд и бросает rate_limited, если их больше lim.
create or replace function public.rl_hit(k text, lim int, win int) returns void
language plpgsql security definer set search_path = public as $$
declare b bigint := floor(extract(epoch from now()) / win); c int;
begin
  insert into public.rate_hits(key, bucket, n) values (k, b, 1)
  on conflict (key, bucket) do update set n = public.rate_hits.n + 1
  returning n into c;
  if c > lim then raise exception 'rate_limited'; end if;
  if random() < 0.01 then
    delete from public.rate_hits where at < now() - interval '2 hours';
  end if;
end $$;
revoke all on function public.rl_hit(text, int, int) from public, anon, authenticated;

-- Заявки в друзья: до 20 в час, до 50 ждущих ответа, до 300 друзей.
create or replace function public.rl_friendships() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(auth.role(), '') in ('', 'service_role') or auth.uid() is null then return new; end if;
  perform public.rl_hit('fr:' || auth.uid(), 20, 3600);
  select count(*) into n from public.friendships where user_id = auth.uid() and status = 'pending';
  if n >= 50 then raise exception 'too_many_requests'; end if;
  select count(*) into n from public.friendships where (user_id = auth.uid() or friend_id = auth.uid()) and status = 'accepted';
  if n >= 300 then raise exception 'too_many_friends'; end if;
  return new;
end $$;
drop trigger if exists rl_friendships on public.friendships;
create trigger rl_friendships before insert on public.friendships
  for each row execute function public.rl_friendships();

-- Сохранение прогресса: до 120 записей в минуту и не больше 2 МБ.
create or replace function public.rl_data() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') in ('', 'service_role') or auth.uid() is null then return new; end if;
  perform public.rl_hit('d:' || auth.uid(), 120, 60);
  if length(new.data::text) > 2000000 then raise exception 'too_big'; end if;
  return new;
end $$;
drop trigger if exists rl_data on public.vitok_data;
create trigger rl_data before insert or update on public.vitok_data
  for each row execute function public.rl_data();

-- Профиль: до 120 изменений в минуту, размеры картинок и текстов ограничены.
create or replace function public.rl_profiles() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if coalesce(auth.role(), '') in ('', 'service_role') or auth.uid() is null then return new; end if;
  perform public.rl_hit('p:' || auth.uid(), 120, 60);
  if length(coalesce(new.avatar, '')) > 400000 or length(coalesce(new.banner, '')) > 800000
     or length(coalesce(new.bio, '')) > 400 or length(coalesce(new.name, '')) > 80 then
    raise exception 'too_big';
  end if;
  return new;
end $$;
drop trigger if exists rl_profiles on public.profiles;
create trigger rl_profiles before insert or update on public.profiles
  for each row execute function public.rl_profiles();

-- ===== 11. Сезоны с рейтингом (v27) =====
-- Сезон = календарный месяц по Москве. Очки = искры, заработанные за месяц (уже проверены защитой из раздела 8).
-- В конце месяца: 1 место +1000 искр и 7 дней премиума, 2 место +700 и 3 дня, 3 место +500 и 1 день,
-- места 4-10 +250, остальные, у кого от 1000 очков, +50. Награду каждый забирает сам один раз.

create table if not exists public.season_scores(
  season text not null,
  user_id uuid not null,
  score numeric not null default 0,
  primary key (season, user_id)
);
create index if not exists season_scores_top on public.season_scores(season, score desc);
alter table public.season_scores enable row level security;
revoke all on public.season_scores from anon, authenticated;

create table if not exists public.season_rewards(
  season text not null,
  user_id uuid not null,
  place int not null,
  amount int not null,
  premium_days int not null default 0,
  claimed_at timestamptz not null default now(),
  primary key (season, user_id)
);
alter table public.season_rewards enable row level security;
revoke all on public.season_rewards from anon, authenticated;

create or replace function public.season_key(t timestamptz default now()) returns text
language sql stable as $$ select to_char(t at time zone 'Europe/Moscow', 'YYYY-MM') $$;

create or replace function public.season_key_prev() returns text
language sql stable as $$ select to_char((now() at time zone 'Europe/Moscow') - interval '1 month', 'YYYY-MM') $$;

create or replace function public.season_reward(p int, sc numeric) returns jsonb
language sql immutable as $$
  select case
    when sc is null or sc < 1000 then null
    when p = 1 then jsonb_build_object('amount', 1000, 'days', 7)
    when p = 2 then jsonb_build_object('amount', 700, 'days', 3)
    when p = 3 then jsonb_build_object('amount', 500, 'days', 1)
    when p <= 10 then jsonb_build_object('amount', 250, 'days', 0)
    else jsonb_build_object('amount', 50, 'days', 0)
  end
$$;

-- Всё для экрана сезона одним запросом: топ, моё место, награда за прошлый сезон.
create or replace function public.season_info(lim int default 10) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  cur text := public.season_key();
  prv text := public.season_key_prev();
  v_top jsonb; v_score numeric; v_place int; v_total int;
  v_pscore numeric; v_pplace int; v_claimed boolean; v_ends timestamptz;
begin
  if auth.uid() is null then raise exception 'auth'; end if;
  perform public.rl_hit('se:' || auth.uid(), 40, 60);
  lim := least(greatest(coalesce(lim, 10), 1), 50);

  select coalesce(jsonb_agg(jsonb_build_object('place', t.pl, 'uid', t.uid, 'score', t.sc) order by t.pl, t.uid), '[]'::jsonb)
    into v_top
    from (select r.uid, r.sc, r.pl from (
            select s.user_id as uid, s.score as sc, rank() over (order by s.score desc)::int as pl
              from public.season_scores s
              join public.profiles p on p.user_id = s.user_id and p.username is not null
             where s.season = cur and s.score > 0) r
           order by r.pl limit lim) t;

  select x.sc, x.pl into v_score, v_place from (
    select s.user_id as uid, s.score as sc, rank() over (order by s.score desc)::int as pl
      from public.season_scores s
      join public.profiles p on p.user_id = s.user_id and p.username is not null
     where s.season = cur and s.score > 0) x
   where x.uid = auth.uid();

  select count(*) into v_total from public.season_scores s
    join public.profiles p on p.user_id = s.user_id and p.username is not null
   where s.season = cur and s.score > 0;

  select x.sc, x.pl into v_pscore, v_pplace from (
    select s.user_id as uid, s.score as sc, rank() over (order by s.score desc)::int as pl
      from public.season_scores s
      join public.profiles p on p.user_id = s.user_id and p.username is not null
     where s.season = prv and s.score > 0) x
   where x.uid = auth.uid();

  v_claimed := exists(select 1 from public.season_rewards r where r.season = prv and r.user_id = auth.uid());
  v_ends := (date_trunc('month', now() at time zone 'Europe/Moscow') + interval '1 month') at time zone 'Europe/Moscow';

  return jsonb_build_object(
    'season', cur, 'ends_at', v_ends, 'top', v_top, 'total', v_total,
    'me', case when v_score is null then null else jsonb_build_object('score', v_score, 'place', v_place) end,
    'prev', case when v_pscore is null then null else jsonb_build_object(
              'season', prv, 'score', v_pscore, 'place', v_pplace, 'claimed', v_claimed,
              'reward', public.season_reward(v_pplace, v_pscore)) end
  );
end $$;
revoke all on function public.season_info(int) from public, anon;
grant execute on function public.season_info(int) to authenticated;

-- Забрать награду за прошлый сезон (один раз). Искры приходят подарком, их забирает claim_gifts.
create or replace function public.season_claim() returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  prv text := public.season_key_prev();
  v_score numeric; v_place int; rw jsonb; v_amount int; v_days int;
begin
  if auth.uid() is null then raise exception 'auth'; end if;
  perform public.rl_hit('sc:' || auth.uid(), 5, 60);

  select x.sc, x.pl into v_score, v_place from (
    select s.user_id as uid, s.score as sc, rank() over (order by s.score desc)::int as pl
      from public.season_scores s
      join public.profiles p on p.user_id = s.user_id and p.username is not null
     where s.season = prv and s.score > 0) x
   where x.uid = auth.uid();

  rw := public.season_reward(v_place, v_score);
  if rw is null then raise exception 'no_reward'; end if;
  v_amount := (rw->>'amount')::int;
  v_days := (rw->>'days')::int;

  begin
    insert into public.season_rewards(season, user_id, place, amount, premium_days)
      values (prv, auth.uid(), v_place, v_amount, v_days);
  exception when unique_violation then
    raise exception 'already_claimed';
  end;

  insert into public.gifts(user_id, amount, note)
    values (auth.uid(), v_amount, 'Награда сезона ' || prv || ', место ' || v_place);

  if v_days > 0 then
    perform set_config('vitok.bypass', '1', true);
    update public.profiles
       set premium_until = greatest(coalesce(premium_until, now()), now()) + make_interval(days => v_days)
     where user_id = auth.uid();
  end if;

  return jsonb_build_object('place', v_place, 'amount', v_amount, 'days', v_days);
end $$;
revoke all on function public.season_claim() from public, anon;
grant execute on function public.season_claim() to authenticated;
