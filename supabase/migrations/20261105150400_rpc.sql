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
