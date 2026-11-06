-- Ручная установка базы: вставить целиком в Supabase → SQL Editor → Run.
-- Перед запуском создайте в Authentication → Users трёх пользователей
-- (manager@example.com, executor1@example.com, executor2@example.com) с галочкой Auto Confirm.
-- Файл собран командой npm run setup:sql из supabase/migrations — не редактировать вручную.

begin;

-- ===== 20261105150000_uuid_v7.sql =====
-- Генератор идентификаторов UUID v7 (RFC 9562) для всех таблиц приложения.
--
-- Зачем v7, а не случайный v4: первые 48 бит — время создания в миллисекундах.
-- Новые строки ложатся в конец индекса первичного ключа (меньше разбиений страниц
-- и раздувания индекса), а сортировка по id совпадает с хронологией, что удобно
-- для журнала событий задачи.
--
-- Где работает: в PostgreSQL 18+ есть встроенная pg_catalog.uuidv7(), и миграция
-- просто оборачивает её. Supabase на момент написания работает на PostgreSQL 17
-- (CLI 3.0.0 не принимает db.major_version = 18), поэтому применяется своя
-- реализация на plpgsql. При переходе проекта на 18 достаточно повторить эту
-- миграцию (или создать новую с тем же телом) — имя функции и все DEFAULT в
-- таблицах останутся прежними.
--
-- Идентификаторы пользователей выдаёт Supabase Auth (UUID v4), их не трогаем.

do $migration$
begin
  if current_setting('server_version_num')::int >= 180000 then
    -- Встроенная функция сама гарантирует рост значений внутри одного соединения,
    -- даже если несколько id выдаются в одну миллисекунду.
    execute $fn$
      create or replace function public.uuid_generate_v7()
      returns uuid
      language sql
      volatile
      parallel safe
      set search_path = ''
      as 'select pg_catalog.uuidv7()'
    $fn$;
  else
    execute $fn$
      create or replace function public.uuid_generate_v7()
      returns uuid
      language plpgsql
      volatile
      parallel safe
      set search_path = ''
      as $body$
      declare
        -- Время берём из clock_timestamp(), а не now(): now() одинаково для всей
        -- транзакции, и все id одной транзакции получили бы одну метку.
        v_us  bigint  := (extract(epoch from clock_timestamp()) * 1000000)::bigint;
        v_ms  bigint  := v_us / 1000;
        -- Доли миллисекунды (0..999 мкс) растягиваем на 12 бит поля rand_a
        -- (метод 3 из RFC 9562, так же делает PostgreSQL 18). Благодаря этому
        -- id, выданные в одну миллисекунду, тоже идут по возрастанию с точностью
        -- до микросекунды.
        v_sub int     := ((v_us % 1000) * 4096 / 1000)::int;
        -- Остальные 62 бита берём из случайного v4: у него уже выставлен
        -- вариант 10 (RFC 4122/9562), остаётся только заменить время и версию.
        v_b   bytea   := uuid_send(gen_random_uuid());
      begin
        -- Байты 0..5: 48 бит миллисекунд Unix-времени (int8send даёт 8 байт,
        -- старшие 2 отбрасываем).
        v_b := overlay(v_b placing substring(int8send(v_ms) from 3) from 1 for 6);
        -- Байт 6: старшая тетрада = версия 7 (0111), младшая = старшие 4 бита долей.
        v_b := set_byte(v_b, 6, 112 | (v_sub >> 8));
        -- Байт 7: младшие 8 бит долей миллисекунды.
        v_b := set_byte(v_b, 7, v_sub & 255);
        return encode(v_b, 'hex')::uuid;
      end
      $body$
    $fn$;
  end if;
end
$migration$;

comment on function public.uuid_generate_v7() is
  'UUID v7: 48 бит времени в мс + 12 бит долей мс + случайная часть. На PG18+ обёртка над uuidv7().';

-- ===== 20261105150100_schema.sql =====
-- Схема данных мини-CRM: профили, объекты (стройки), задачи, правила переходов
-- статусов и журнал событий задачи.
--
-- Общие принципы, на которые опираются следующие миграции:
--   * все свои ключи генерирует база (UUID v7), клиент id не передаёт;
--   * автора и время ставит база (DEFAULT здесь, принудительно — в триггерах);
--   * удаления нет: объекты и задачи уходят в архив (archived_at / archived_by);
--   * внешние ключи с ON DELETE RESTRICT: строку с зависимостями не удалить
--     даже администратору, пока не удалены зависимые, а историю удалить нельзя.

-- Роли приложения. Это не роли PostgreSQL: все вошедшие пользователи работают
-- под ролью authenticated, а роль приложения читается из profiles.
create type public.app_role as enum ('manager', 'executor');

comment on type public.app_role is 'manager — постановщик, executor — исполнитель';

-- Статусы задачи. Порядок значений совпадает с жизненным циклом.
-- Подписи на русском живут во фронтенде (src/lib/labels.ts).
create type public.task_status as enum ('new', 'in_progress', 'review', 'accepted', 'rework');

comment on type public.task_status is
  'new — Новая, in_progress — В работе, review — На проверке, accepted — Принята, rework — На доработке';

-- Профиль пользователя: имя и роль. id совпадает с auth.users.id.
-- Через API профиль не создать и не изменить (нет прав), его заводит
-- администратор: scripts/seed.ts служебным ключом или вручную в Supabase.
create table public.profiles (
  id         uuid primary key references auth.users (id) on delete restrict,
  full_name  text not null check (length(trim(full_name)) > 0),
  role       public.app_role not null,
  created_at timestamptz not null default now()
);

comment on table public.profiles is 'Имя и роль пользователя. Одна роль на пользователя (решение 6).';

-- Объект — место работ (стройка, квартира, цех), к которому привязаны задачи.
create table public.objects (
  id          uuid primary key default public.uuid_generate_v7(),
  name        text not null check (length(trim(name)) > 0),
  address     text not null default '',
  created_by  uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  created_at  timestamptz not null default now(),
  archived_at timestamptz,
  archived_by uuid references public.profiles (id) on delete restrict,
  -- Архивная отметка ставится целиком: либо оба поля пустые, либо оба заполнены.
  constraint objects_archive_pair check ((archived_at is null) = (archived_by is null))
);

comment on table public.objects is 'Объекты работ. Удаления нет, только архив через archive_object().';

create table public.tasks (
  id          uuid primary key default public.uuid_generate_v7(),
  object_id   uuid not null references public.objects (id) on delete restrict,
  title       text not null check (length(trim(title)) > 0),
  description text not null default '',
  -- Исполнитель обязателен (решение 1); что это именно исполнитель, проверяет триггер.
  assignee_id uuid not null references public.profiles (id) on delete restrict,
  status      public.task_status not null default 'new',
  author_id   uuid not null default auth.uid() references public.profiles (id) on delete restrict,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  archived_at timestamptz,
  archived_by uuid references public.profiles (id) on delete restrict,
  constraint tasks_archive_pair check ((archived_at is null) = (archived_by is null))
);

comment on table public.tasks is
  'Задачи. Статус меняется только через change_task_status(), удаления нет — archive_task().';

-- Таблица разрешённых переходов. По ней одновременно:
--   * база проверяет каждую смену статуса (функция и триггер);
--   * фронтенд строит кнопки доступных действий.
-- Правило в одном месте: чтобы добавить переход, достаточно строки здесь.
create table public.task_transitions (
  from_status      public.task_status not null,
  to_status        public.task_status not null,
  actor_role       public.app_role not null,
  requires_comment boolean not null default false,
  primary key (from_status, to_status),
  constraint task_transitions_not_self check (from_status <> to_status)
);

comment on table public.task_transitions is
  'Разрешённые переходы статусов: кто может и нужен ли комментарий. Меняется только миграцией.';

insert into public.task_transitions (from_status, to_status, actor_role, requires_comment) values
  ('new',         'in_progress', 'executor', false),  -- исполнитель взял в работу
  ('in_progress', 'review',      'executor', false),  -- исполнитель сдал на проверку
  ('review',      'accepted',    'manager',  false),  -- постановщик принял
  ('review',      'rework',      'manager',  true),   -- постановщик вернул, причина обязательна
  ('rework',      'in_progress', 'executor', false);  -- исполнитель снова взял в работу

-- Журнал событий задачи. Пишут только триггеры базы; изменить или удалить
-- запись нельзя никому (см. миграцию с триггерами).
create table public.task_history (
  id          uuid primary key default public.uuid_generate_v7(),
  task_id     uuid not null references public.tasks (id) on delete restrict,
  actor_id    uuid not null references public.profiles (id) on delete restrict,
  event       text not null check (event in ('created', 'updated', 'status_changed', 'archived')),
  from_status public.task_status,
  to_status   public.task_status,
  comment     text,
  -- Для события updated: {"title": {"old": "…", "new": "…"}, …}
  changes     jsonb,
  created_at  timestamptz not null default now(),
  -- Смена статуса всегда записывается с конечным статусом; создание — с «— → Новая».
  constraint task_history_status_event check (
    event not in ('created', 'status_changed') or to_status is not null
  )
);

comment on table public.task_history is
  'Журнал событий задачи только на добавление: создание, правка полей, смена статуса, архив.';

-- Исполнитель открывает «Мои задачи»: ищем его активные задачи.
create index tasks_assignee_active_idx on public.tasks (assignee_id) where archived_at is null;
-- Карточка объекта и проверка «нет активных задач» перед архивом.
create index tasks_object_idx on public.tasks (object_id);
-- История задачи в хронологическом порядке: UUID v7 сортируется по времени.
create index task_history_task_idx on public.task_history (task_id, id);
-- Внешние ключи на профили, чтобы проверки ссылочной целостности не сканировали таблицы.
create index tasks_author_idx on public.tasks (author_id);
create index objects_created_by_idx on public.objects (created_by);
create index task_history_actor_idx on public.task_history (actor_id);
-- archived_by заполнен только у архивных строк, поэтому индекс частичный и маленький.
create index tasks_archived_by_idx on public.tasks (archived_by) where archived_by is not null;
create index objects_archived_by_idx on public.objects (archived_by) where archived_by is not null;

-- ===== 20261105150200_helpers.sql =====
-- Вспомогательные функции для политик RLS, триггеров и RPC.
--
-- Служебные функции живут в схеме private: она не входит в api.schemas
-- (supabase/config.toml), поэтому их нельзя вызвать через REST /rpc.
-- В public остаётся только то, что клиенту действительно нужно вызывать.

create schema if not exists private;

-- Никто, кроме владельца, не может обращаться к объектам схемы private напрямую.
-- Триггеры и функции с SECURITY DEFINER работают от владельца, им это не мешает.
revoke all on schema private from public, anon, authenticated;

-- Роль приложения текущего пользователя (или NULL для анонима и для запросов
-- служебным ключом, у которых нет пользователя).
--
-- SECURITY DEFINER нужен, чтобы читать profiles в обход RLS: иначе политика
-- profiles_read, которая сама зовёт эту функцию, зациклилась бы на себе.
-- STABLE + обёртка (select …) в политиках дают одно вычисление на запрос,
-- а не на каждую строку.
create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = auth.uid()
$$;

comment on function public.current_app_role() is
  'Роль вошедшего пользователя из profiles; NULL, если пользователя нет или у него нет профиля.';

-- Роль произвольного пользователя. Нужна триггерам, чтобы проверить, что
-- исполнителем назначают именно исполнителя. Клиенту не выдаётся: по ней можно
-- было бы перебором узнать роли чужих пользователей.
create or replace function private.role_of(p_user_id uuid)
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = p_user_id
$$;

-- Общая проверка для всех изменяющих действий: есть вошедший пользователь
-- и у него заведён профиль. Возвращает его роль, чтобы не читать её дважды.
-- Запросы служебным ключом (service_role) пользователя не имеют и сюда не проходят:
-- так история всегда знает, кто совершил действие.
create or replace function private.require_actor()
returns public.app_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
begin
  if auth.uid() is null then
    raise exception 'Действие доступно только вошедшему пользователю'
      using errcode = '42501';
  end if;

  v_role := private.role_of(auth.uid());
  if v_role is null then
    raise exception 'У пользователя нет профиля, обратитесь к администратору'
      using errcode = '42501';
  end if;

  return v_role;
end
$$;

-- ===== 20261105150300_triggers.sql =====
-- Триггеры: база сама ставит автора, даты и статус, проверяет правила изменения
-- и пишет журнал событий. Права на колонки (миграция rls_grants) не дают клиенту
-- даже отправить запрещённые поля, а триггеры закрывают то же самое ещё раз —
-- на случай ошибки в правах и для запросов от владельца таблиц.
--
-- Все функции триггеров — SECURITY DEFINER с пустым search_path: они
-- выполняются от владельца (иначе клиент не прошёл бы в схему private
-- и не смог бы писать в журнал), а кто совершает действие, определяют
-- по auth.uid() — идентификатору из JWT текущего запроса.
--
-- Коды ошибок, которые разбирает фронтенд (src/lib/errors.ts):
--   42501 — нет прав на действие;
--   55000 — действие недоступно в текущем состоянии (архив, статус);
--   23514 — данные не прошли проверку (комментарий, роль исполнителя).

-------------------------------------------------------------------------------
-- Объекты
-------------------------------------------------------------------------------

-- Перед созданием объекта: создавать может только постановщик, служебные поля
-- заполняет база, что бы ни прислал клиент.
create or replace function private.objects_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.require_actor() <> 'manager' then
    raise exception 'Создавать объекты может только постановщик' using errcode = '42501';
  end if;

  new.id          := public.uuid_generate_v7();
  new.created_by  := auth.uid();
  new.created_at  := now();
  new.archived_at := null;
  new.archived_by := null;
  return new;
end
$$;

create trigger objects_before_insert
  before insert on public.objects
  for each row execute function private.objects_before_insert();

-- Перед изменением объекта: менять можно только название и адрес и только
-- у объекта не в архиве; архивная отметка ставится один раз и навсегда.
create or replace function private.objects_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role public.app_role := private.require_actor();
begin
  if v_role <> 'manager' then
    raise exception 'Изменять объекты может только постановщик' using errcode = '42501';
  end if;

  if new.id <> old.id or new.created_by <> old.created_by or new.created_at <> old.created_at then
    raise exception 'Нельзя менять идентификатор, автора и дату создания объекта'
      using errcode = '42501';
  end if;

  if old.archived_at is not null then
    raise exception 'Объект в архиве и не изменяется' using errcode = '55000';
  end if;

  -- Архивация: отметку ставит база, кем и когда — берётся из сессии.
  if new.archived_at is not null then
    new.archived_at := now();
    new.archived_by := auth.uid();
  else
    new.archived_by := null;
  end if;

  return new;
end
$$;

create trigger objects_before_update
  before update on public.objects
  for each row execute function private.objects_before_update();

-------------------------------------------------------------------------------
-- Задачи: проверки перед записью
-------------------------------------------------------------------------------

-- Перед созданием задачи. Триггер блокирует строку объекта (FOR SHARE)
-- и читает роль исполнителя — на то и другое у клиента прав нет.
create or replace function private.tasks_before_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if private.require_actor() <> 'manager' then
    raise exception 'Создавать задачи может только постановщик' using errcode = '42501';
  end if;

  -- Служебные поля ставит база (решение 11). Статус всегда «Новая»:
  -- создание — это переход «— → Новая», он пишется в историю отдельным событием.
  new.id          := public.uuid_generate_v7();
  new.author_id   := auth.uid();
  new.status      := 'new';
  new.created_at  := now();
  new.updated_at  := now();
  new.archived_at := null;
  new.archived_by := null;

  if private.role_of(new.assignee_id) is distinct from 'executor' then
    raise exception 'Исполнителем можно назначить только пользователя с ролью «исполнитель»'
      using errcode = '23514';
  end if;

  -- FOR SHARE держит объект до конца транзакции. Если параллельно идёт
  -- archive_object() (она берёт FOR UPDATE), одна из транзакций дождётся другой:
  -- либо задача не создастся в уже архивном объекте, либо архивация увидит
  -- новую активную задачу и откажет.
  perform 1
     from public.objects o
    where o.id = new.object_id
      and o.archived_at is null
      for share;
  if not found then
    raise exception 'Объект не найден или находится в архиве' using errcode = '55000';
  end if;

  return new;
end
$$;

create trigger tasks_before_insert
  before insert on public.tasks
  for each row execute function private.tasks_before_insert();

-- Перед изменением задачи. Разбирает, что именно меняется, и пропускает
-- только одно из трёх действий за раз:
--   1) правка полей постановщиком в статусах «Новая» и «На доработке»;
--   2) смена статуса — только из change_task_status() и только по task_transitions;
--   3) архивация постановщиком.
-- Проверка перехода дублирует функцию намеренно: так недопустимый переход
-- не пройдёт и при прямом UPDATE от владельца таблиц.
create or replace function private.tasks_before_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role           public.app_role;
  v_rule           public.task_transitions;
  v_fields_changed boolean;
  v_status_changed boolean;
  v_archiving      boolean;
begin
  -- Эти поля неизменны всегда: объект задачи после создания не переносится (решение 2).
  if new.id <> old.id or new.object_id <> old.object_id
     or new.author_id <> old.author_id or new.created_at <> old.created_at then
    raise exception 'Нельзя менять идентификатор, объект, автора и дату создания задачи'
      using errcode = '42501';
  end if;

  if old.archived_at is not null then
    raise exception 'Задача в архиве и не изменяется' using errcode = '55000';
  end if;

  v_role := private.require_actor();

  v_fields_changed := new.title is distinct from old.title
                   or new.description is distinct from old.description
                   or new.assignee_id is distinct from old.assignee_id;
  v_status_changed := new.status is distinct from old.status;
  v_archiving      := new.archived_at is not null;

  -- Пустое обновление ничего не меняет и в историю не попадает.
  if not (v_fields_changed or v_status_changed or v_archiving) then
    new.updated_at  := old.updated_at;
    new.archived_by := old.archived_by;
    return new;
  end if;

  if (v_fields_changed::int + v_status_changed::int + v_archiving::int) > 1 then
    raise exception 'За одно действие можно либо изменить поля, либо сменить статус, либо архивировать'
      using errcode = '55000';
  end if;

  if v_archiving then
    if v_role <> 'manager' then
      raise exception 'Архивировать задачи может только постановщик' using errcode = '42501';
    end if;
    new.archived_at := now();
    new.archived_by := auth.uid();
  end if;

  if v_status_changed then
    -- Метку ставит только change_task_status() и только для этой задачи.
    -- Прямой UPDATE status (даже от владельца таблиц) её не имеет.
    if current_setting('app.status_change_task', true) is distinct from new.id::text then
      raise exception 'Статус меняется только через change_task_status()' using errcode = '42501';
    end if;

    select * into v_rule
      from public.task_transitions t
     where t.from_status = old.status
       and t.to_status   = new.status
       and t.actor_role  = v_role;
    if not found then
      raise exception 'Переход % → % запрещён', old.status, new.status using errcode = '42501';
    end if;

    if v_role = 'executor' and old.assignee_id <> auth.uid() then
      raise exception 'Задача не найдена' using errcode = 'P0002';
    end if;

    if v_rule.requires_comment
       and coalesce(current_setting('app.transition_comment', true), '') = '' then
      raise exception 'Для этого перехода нужен комментарий' using errcode = '23514';
    end if;
  end if;

  if v_fields_changed then
    if v_role <> 'manager' then
      raise exception 'Менять содержание задачи может только постановщик' using errcode = '42501';
    end if;

    if old.status not in ('new', 'rework') then
      raise exception 'Править задачу можно только в статусах «Новая» и «На доработке»'
        using errcode = '55000';
    end if;

    if new.assignee_id is distinct from old.assignee_id
       and private.role_of(new.assignee_id) is distinct from 'executor' then
      raise exception 'Исполнителем можно назначить только пользователя с ролью «исполнитель»'
        using errcode = '23514';
    end if;
  end if;

  new.updated_at := now();
  return new;
end
$$;

create trigger tasks_before_update
  before update on public.tasks
  for each row execute function private.tasks_before_update();

-------------------------------------------------------------------------------
-- Задачи: журнал событий
-------------------------------------------------------------------------------

-- После создания задачи: событие created, переход «— → Новая».
-- У клиента нет права INSERT в task_history: писать туда может только база.
create or replace function private.tasks_log_insert()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.task_history (task_id, actor_id, event, from_status, to_status)
  values (new.id, new.author_id, 'created', null, new.status);
  return null;
end
$$;

create trigger tasks_log_insert
  after insert on public.tasks
  for each row execute function private.tasks_log_insert();

-- После изменения задачи: одно событие на действие. Автор события — тот,
-- кто вошёл (auth.uid()); клиент подставить другого не может.
create or replace function private.tasks_log_update()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_changes jsonb;
begin
  if new.status is distinct from old.status then
    insert into public.task_history (task_id, actor_id, event, from_status, to_status, comment)
    values (new.id, auth.uid(), 'status_changed', old.status, new.status,
            -- Комментарий передаёт change_task_status() через настройку транзакции.
            nullif(current_setting('app.transition_comment', true), ''));
  end if;

  -- Изменённые поля в виде {"поле": {"old": …, "new": …}}; неизменённые
  -- отбрасываются jsonb_strip_nulls.
  v_changes := jsonb_strip_nulls(jsonb_build_object(
    'title', case when new.title is distinct from old.title
                  then jsonb_build_object('old', old.title, 'new', new.title) end,
    'description', case when new.description is distinct from old.description
                        then jsonb_build_object('old', old.description, 'new', new.description) end,
    'assignee_id', case when new.assignee_id is distinct from old.assignee_id
                        then jsonb_build_object('old', old.assignee_id, 'new', new.assignee_id) end
  ));
  if v_changes <> '{}'::jsonb then
    insert into public.task_history (task_id, actor_id, event, changes)
    values (new.id, auth.uid(), 'updated', v_changes);
  end if;

  if old.archived_at is null and new.archived_at is not null then
    insert into public.task_history (task_id, actor_id, event, from_status, to_status)
    values (new.id, auth.uid(), 'archived', new.status, new.status);
  end if;

  return null;
end
$$;

create trigger tasks_log_update
  after update on public.tasks
  for each row execute function private.tasks_log_update();

-------------------------------------------------------------------------------
-- История: только добавление
-------------------------------------------------------------------------------

-- Отказ на любое изменение или удаление журнала. Срабатывает для всех ролей,
-- включая служебный ключ и владельца таблиц, поэтому подделать историю через
-- API невозможно. Обойти можно только явным отключением триггера
-- суперпользователем, что видно в журнале базы.
create or replace function private.task_history_append_only()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Журнал задачи только на добавление: изменять и удалять записи нельзя'
    using errcode = '42501';
end
$$;

create trigger task_history_no_update_delete
  before update or delete on public.task_history
  for each row execute function private.task_history_append_only();

create trigger task_history_no_truncate
  before truncate on public.task_history
  for each statement execute function private.task_history_append_only();

-- Правила переходов меняются только миграцией: через API на них нет прав,
-- а этот триггер не даёт случайно поменять их и из SQL-консоли без миграции
-- (для намеренной правки миграция сначала отключает его:
-- alter table public.task_transitions disable trigger task_transitions_readonly).
-- Добавление строк (новый переход) разрешено — это расширение, а не подмена правил.
create or replace function private.task_transitions_readonly()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  raise exception 'Правила переходов меняются только миграцией' using errcode = '42501';
end
$$;

create trigger task_transitions_readonly
  before update or delete or truncate on public.task_transitions
  for each statement execute function private.task_transitions_readonly();

-- ===== 20261105150400_rpc.sql =====
-- Функции, которые клиент вызывает через REST (/rest/v1/rpc/…): смена статуса
-- и архивация. Это единственные пути к соответствующим изменениям — прав на
-- колонки status и archived_* у клиента нет.
--
-- Все три функции SECURITY DEFINER: они выполняют UPDATE от владельца таблиц,
-- поэтому сами проверяют, кто их вызвал. Триггеры tasks_before_update и
-- objects_before_update после них проверяют то же ещё раз.

-- Смена статуса задачи по правилам из task_transitions.
--
-- Порядок проверок важен:
--   1) строка задачи блокируется FOR UPDATE — два одновременных запроса
--      выполняются по очереди, второй увидит уже новый статус и получит отказ
--      (решение 12);
--   2) чужая или архивная задача для исполнителя неотличима от несуществующей —
--      так по ответу нельзя узнать, что задача с таким id есть;
--   3) только потом ищется правило перехода для роли вызывающего.
create or replace function public.change_task_status(
  p_task_id uuid,
  p_to      public.task_status,
  p_comment text default null
)
returns public.tasks
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role    public.app_role := private.require_actor();
  v_comment text := nullif(trim(coalesce(p_comment, '')), '');
  v_task    public.tasks;
  v_rule    public.task_transitions;
begin
  select * into v_task
    from public.tasks t
   where t.id = p_task_id
     for update;

  if not found
     or v_task.archived_at is not null
     or (v_role = 'executor' and v_task.assignee_id <> auth.uid()) then
    raise exception 'Задача не найдена' using errcode = 'P0002';
  end if;

  select * into v_rule
    from public.task_transitions r
   where r.from_status = v_task.status
     and r.to_status   = p_to
     and r.actor_role  = v_role;
  if not found then
    raise exception 'Переход % → % запрещён', v_task.status, p_to using errcode = '42501';
  end if;

  if v_rule.requires_comment and v_comment is null then
    raise exception 'Для этого перехода нужен комментарий' using errcode = '23514';
  end if;

  if length(v_comment) > 2000 then
    raise exception 'Комментарий длиннее 2000 символов' using errcode = '23514';
  end if;

  -- Метки для триггеров живут только до конца этой транзакции (третий
  -- аргумент true). app.status_change_task разрешает триггеру смену статуса
  -- именно этой задачи, app.transition_comment попадает в историю.
  perform set_config('app.status_change_task', p_task_id::text, true);
  perform set_config('app.transition_comment', coalesce(v_comment, ''), true);

  update public.tasks
     set status = p_to
   where id = p_task_id
  returning * into v_task;

  -- Снимаем метки сразу, чтобы следующий UPDATE в той же транзакции
  -- не прошёл как «смена статуса через функцию».
  perform set_config('app.status_change_task', '', true);
  perform set_config('app.transition_comment', '', true);

  return v_task;
end
$$;

comment on function public.change_task_status(uuid, public.task_status, text) is
  'Единственный путь сменить статус задачи. Правила — в task_transitions.';

-- Мягкое удаление задачи (решение 3): отметка «кто и когда», история остаётся.
create or replace function public.archive_task(p_task_id uuid)
returns public.tasks
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.tasks;
begin
  if private.require_actor() <> 'manager' then
    raise exception 'Архивировать задачи может только постановщик' using errcode = '42501';
  end if;

  select * into v_task from public.tasks t where t.id = p_task_id for update;
  if not found then
    raise exception 'Задача не найдена' using errcode = 'P0002';
  end if;
  if v_task.archived_at is not null then
    raise exception 'Задача уже в архиве' using errcode = '55000';
  end if;

  -- Значения archived_at / archived_by триггер всё равно перезапишет
  -- на now() и auth.uid(); здесь они нужны, чтобы обозначить намерение.
  update public.tasks
     set archived_at = now(), archived_by = auth.uid()
   where id = p_task_id
  returning * into v_task;

  return v_task;
end
$$;

comment on function public.archive_task(uuid) is 'Архивирует задачу. Только для постановщика.';

-- Мягкое удаление объекта (решение 4): только когда в нём нет активных задач,
-- то есть все задачи приняты или уже в архиве.
create or replace function public.archive_object(p_object_id uuid)
returns public.objects
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_object public.objects;
  v_active int;
begin
  if private.require_actor() <> 'manager' then
    raise exception 'Архивировать объекты может только постановщик' using errcode = '42501';
  end if;

  -- FOR UPDATE конфликтует с FOR SHARE из tasks_before_insert: пока архивация
  -- не завершилась, новую задачу в этот объект не создать, и наоборот.
  select * into v_object from public.objects o where o.id = p_object_id for update;
  if not found then
    raise exception 'Объект не найден' using errcode = 'P0002';
  end if;
  if v_object.archived_at is not null then
    raise exception 'Объект уже в архиве' using errcode = '55000';
  end if;

  select count(*) into v_active
    from public.tasks t
   where t.object_id = p_object_id
     and t.archived_at is null
     and t.status <> 'accepted';
  if v_active > 0 then
    raise exception 'В объекте есть незавершённые задачи (%): примите их или перенесите в архив', v_active
      using errcode = '55000';
  end if;

  update public.objects
     set archived_at = now(), archived_by = auth.uid()
   where id = p_object_id
  returning * into v_object;

  return v_object;
end
$$;

comment on function public.archive_object(uuid) is
  'Архивирует объект, если в нём нет незавершённых задач. Только для постановщика.';

-- ===== 20261105150500_rls_grants.sql =====
-- Права доступа: что клиент вообще может отправить (GRANT на таблицы и колонки)
-- и какие строки он при этом видит и меняет (RLS).
--
-- Клиент (браузер, curl с публичным ключом) работает под ролью anon до входа
-- и authenticated после. Служебная роль service_role используется только
-- scripts/seed.ts на машине администратора; её права здесь не трогаем.

-------------------------------------------------------------------------------
-- 1. Права на таблицы и колонки
-------------------------------------------------------------------------------

-- Supabase по умолчанию выдаёт anon и authenticated все права на новые
-- таблицы и функции схемы public. Забираем всё и выдаём точечно.
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
revoke execute on all functions in schema public from public, anon, authenticated;

-- То же для объектов, которые появятся в будущих миграциях: новая таблица
-- не станет доступной клиенту, пока её явно не откроют.
alter default privileges in schema public revoke all on tables    from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- Чтение: только вошедшим. Какие именно строки — решают политики ниже.
grant select on public.profiles, public.objects, public.tasks,
                public.task_transitions, public.task_history to authenticated;

-- Запись только в перечисленные колонки. id, status, author_id, created_by,
-- даты и архивные поля клиенту не выданы вовсе: запрос с ними отклоняется
-- ещё до RLS и триггеров с ошибкой 42501 permission denied.
grant insert (name, address) on public.objects to authenticated;
grant update (name, address) on public.objects to authenticated;
grant insert (object_id, title, description, assignee_id) on public.tasks to authenticated;
grant update (title, description, assignee_id)            on public.tasks to authenticated;

-- DELETE не выдан ни на одну таблицу: удаление только через архив.
-- profiles, task_transitions, task_history — только чтение.

-- Функции, которые клиент вызывает напрямую или которые нужны при его запросах:
--   uuid_generate_v7 — DEFAULT id при вставке выполняется от имени клиента;
--   current_app_role — вызывается из политик RLS;
--   остальные — RPC для действий.
grant execute on function public.uuid_generate_v7()                                       to authenticated;
grant execute on function public.current_app_role()                                       to authenticated;
grant execute on function public.change_task_status(uuid, public.task_status, text)       to authenticated;
grant execute on function public.archive_task(uuid)                                       to authenticated;
grant execute on function public.archive_object(uuid)                                     to authenticated;

-------------------------------------------------------------------------------
-- 2. Row Level Security
-------------------------------------------------------------------------------

-- FORCE ROW LEVEL SECURITY не включаем: клиент никогда не работает под
-- владельцем таблиц, а функции SECURITY DEFINER намеренно читают данные от
-- его имени (проверка роли, активных задач объекта).
alter table public.profiles         enable row level security;
alter table public.objects          enable row level security;
alter table public.tasks            enable row level security;
alter table public.task_transitions enable row level security;
alter table public.task_history     enable row level security;

-- (select auth.uid()) и (select public.current_app_role()) в скобках —
-- рекомендация Supabase: значение вычисляется один раз на запрос (initPlan),
-- а не для каждой строки таблицы.

-- Профили (решение 7): каждый видит себя и постановщиков (их имена есть
-- в истории), постановщик видит всех. Других исполнителей исполнитель не видит.
create policy profiles_read on public.profiles
  for select to authenticated
  using (
    id = (select auth.uid())
    or role = 'manager'
    or (select public.current_app_role()) = 'manager'
  );

-- Объекты: постановщик видит все, исполнитель — только те, где у него
-- есть задачи не в архиве. Подзапрос к tasks сам проходит через RLS задач.
create policy objects_read on public.objects
  for select to authenticated
  using (
    (select public.current_app_role()) = 'manager'
    or exists (
      select 1
        from public.tasks t
       where t.object_id = objects.id
         and t.assignee_id = (select auth.uid())
         and t.archived_at is null
    )
  );

create policy objects_insert on public.objects
  for insert to authenticated
  with check ((select public.current_app_role()) = 'manager');

-- USING отбирает строки, которые можно менять (не в архиве),
-- WITH CHECK проверяет строку после изменения.
create policy objects_update on public.objects
  for update to authenticated
  using ((select public.current_app_role()) = 'manager' and archived_at is null)
  with check ((select public.current_app_role()) = 'manager');

-- Задачи: постановщик видит все, включая архивные (решение 8 и 14);
-- исполнитель — только свои и не в архиве.
create policy tasks_read on public.tasks
  for select to authenticated
  using (
    (select public.current_app_role()) = 'manager'
    or (assignee_id = (select auth.uid()) and archived_at is null)
  );

create policy tasks_insert on public.tasks
  for insert to authenticated
  with check ((select public.current_app_role()) = 'manager');

create policy tasks_update on public.tasks
  for update to authenticated
  using ((select public.current_app_role()) = 'manager' and archived_at is null)
  with check ((select public.current_app_role()) = 'manager');

-- Правила переходов видят все вошедшие: по ним фронтенд строит кнопки.
create policy transitions_read on public.task_transitions
  for select to authenticated
  using (true);

-- История видна ровно тогда, когда видна сама задача: подзапрос к tasks
-- проходит через RLS задач, поэтому правило не дублируется.
create policy history_read on public.task_history
  for select to authenticated
  using (exists (select 1 from public.tasks t where t.id = task_history.task_id));

-- ===== история миграций =====
create schema if not exists supabase_migrations;
create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);
insert into supabase_migrations.schema_migrations (version, name) values ('20261105150000', 'uuid_v7') on conflict do nothing;
insert into supabase_migrations.schema_migrations (version, name) values ('20261105150100', 'schema') on conflict do nothing;
insert into supabase_migrations.schema_migrations (version, name) values ('20261105150200', 'helpers') on conflict do nothing;
insert into supabase_migrations.schema_migrations (version, name) values ('20261105150300', 'triggers') on conflict do nothing;
insert into supabase_migrations.schema_migrations (version, name) values ('20261105150400', 'rpc') on conflict do nothing;
insert into supabase_migrations.schema_migrations (version, name) values ('20261105150500', 'rls_grants') on conflict do nothing;

-- ===== профили пользователей =====
-- Профили трёх пользователей для ручной установки через SQL Editor.
-- Пользователи должны быть уже созданы в Authentication → Users.
-- Объектов и задач не создаётся: база остаётся пустой, всё заводится в приложении.
-- Имена и роли — выбор владельца, меняются здесь.

do $profiles$
declare
  v_manager   uuid;
  v_executor1 uuid;
  v_executor2 uuid;
begin
  select id into v_manager   from auth.users where email = 'manager@example.com';
  select id into v_executor1 from auth.users where email = 'executor1@example.com';
  select id into v_executor2 from auth.users where email = 'executor2@example.com';

  if v_manager is null or v_executor1 is null or v_executor2 is null then
    raise exception 'Сначала создайте в Authentication → Users трёх пользователей: manager@example.com, executor1@example.com, executor2@example.com';
  end if;

  -- Повторный запуск обновит имена и роли, а не упадёт.
  insert into public.profiles (id, full_name, role) values
    (v_manager,   'Анна Петрова',  'manager'),
    (v_executor1, 'Иван Смирнов',  'executor'),
    (v_executor2, 'Олег Кузнецов', 'executor')
  on conflict (id) do update set full_name = excluded.full_name, role = excluded.role;

  raise notice 'Профили созданы: 1 постановщик, 2 исполнителя. Объектов и задач нет.';
end
$profiles$;

commit;
