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
