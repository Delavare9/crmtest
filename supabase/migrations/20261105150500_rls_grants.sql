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
