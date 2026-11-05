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
