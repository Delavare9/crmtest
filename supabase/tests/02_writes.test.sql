-- Запись: создание, правка, удаление и архив. Каждая проверка — попытка,
-- которую интерфейс не даёт сделать, а база должна отклонить сама.
begin;
\ir _fixtures.psql

select plan(28);

-- Права как они выданы ---------------------------------------------------------
-- Структурная проверка: если кто-то расширит права на колонки, тест упадёт,
-- даже если триггер ещё удерживает правило (второй замок не должен быть последним).
select pg_temp.act_as('owner');

select set_eq(
  $$ select table_name::text, column_name::text, privilege_type::text
       from information_schema.column_privileges
      where table_schema = 'public'
        and grantee in ('anon', 'authenticated')
        and privilege_type <> 'SELECT' $$,
  $$ values ('objects', 'name',        'INSERT'), ('objects', 'address',     'INSERT'),
            ('objects', 'name',        'UPDATE'), ('objects', 'address',     'UPDATE'),
            ('tasks',   'object_id',   'INSERT'), ('tasks',   'title',       'INSERT'),
            ('tasks',   'description', 'INSERT'), ('tasks',   'assignee_id', 'INSERT'),
            ('tasks',   'title',       'UPDATE'), ('tasks',   'description', 'UPDATE'),
            ('tasks',   'assignee_id', 'UPDATE') $$,
  'клиенту на запись выданы ровно эти колонки: без id, статуса, автора, дат и архива'
);

select is_empty(
  $$ select table_name, privilege_type
       from information_schema.role_table_grants
      where table_schema = 'public'
        and grantee in ('anon', 'authenticated')
        and (grantee = 'anon' or privilege_type <> 'SELECT') $$,
  'на уровне таблиц у клиента только SELECT для вошедших; у анонима ничего, DELETE и TRUNCATE нет ни у кого'
);

-- Исполнитель ничего не создаёт и не правит ----------------------------------
select pg_temp.act_as('executor1');

select throws_ok(
  $$ insert into public.objects (name, address) values ('Свой объект', '') $$,
  '42501', null,
  'исполнитель не может создать объект'
);
select throws_ok(
  $$ insert into public.tasks (object_id, title, assignee_id)
     values (pg_temp.fx('object_a'), 'Сам себе задача', '00000000-0000-4000-a000-000000000002') $$,
  '42501', null,
  'исполнитель не может создать задачу'
);

-- UPDATE под RLS: строка не попадает под политику обновления, база молча
-- меняет 0 строк. Проверяем, что название не изменилось.
update public.tasks set title = 'Переименовал' where id = pg_temp.fx('task_e1');
select pg_temp.act_as('owner');
select is(
  (select title from public.tasks where id = pg_temp.fx('task_e1')),
  'Задача исполнителя 1',
  'исполнитель не может изменить название своей задачи'
);

-- Колонки, на которые нет прав --------------------------------------------------
select pg_temp.act_as('manager');

select throws_ok(
  $$ update public.tasks set status = 'accepted' where id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'прямое изменение status отклоняется правами на колонку'
);
select throws_ok(
  $$ update public.tasks set author_id = '00000000-0000-4000-a000-000000000004' where id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'изменение author_id отклоняется'
);
select throws_ok(
  $$ update public.tasks set id = gen_random_uuid() where id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'изменение id отклоняется'
);
select throws_ok(
  $$ update public.tasks set archived_at = now() where id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'изменение archived_at напрямую отклоняется'
);
select throws_ok(
  $$ update public.tasks set object_id = pg_temp.fx('object_b') where id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'перенос задачи в другой объект отклоняется'
);
select throws_ok(
  $$ insert into public.tasks (id, object_id, title, assignee_id)
     values (gen_random_uuid(), pg_temp.fx('object_a'), 'С чужим id', '00000000-0000-4000-a000-000000000002') $$,
  '42501', null,
  'клиент не может передать свой id при создании'
);
select throws_ok(
  $$ insert into public.tasks (object_id, title, assignee_id, status)
     values (pg_temp.fx('object_a'), 'Сразу принятая', '00000000-0000-4000-a000-000000000002', 'accepted') $$,
  '42501', null,
  'клиент не может создать задачу сразу в нужном статусе'
);

-- Даже владелец таблиц не создаст задачу «от чужого имени»: триггер ставит
-- автора из сессии, а без пользователя действие запрещено.
select pg_temp.act_as('service');
select throws_ok(
  $$ insert into public.tasks (object_id, title, assignee_id)
     values (pg_temp.fx('object_a'), 'Служебным ключом', '00000000-0000-4000-a000-000000000002') $$,
  '42501', 'Действие доступно только вошедшему пользователю',
  'служебный ключ без пользователя не создаёт задачу: автор неизвестен'
);

-- Создание задачи: автор, статус и даты ставит база ---------------------------
select pg_temp.act_as('manager');
with t as (
  insert into public.tasks (object_id, title, assignee_id)
  values (pg_temp.fx('object_a'), 'Новая от постановщика', '00000000-0000-4000-a000-000000000002')
  returning id)
insert into fx select 'task_new', id from t;

select pg_temp.act_as('owner');
select results_eq(
  $$ select author_id, status::text, created_at = now()
       from public.tasks where id = pg_temp.fx('task_new') $$,
  $$ values ('00000000-0000-4000-a000-000000000001'::uuid, 'new', true) $$,
  'при создании база ставит автора из сессии, статус «Новая» и время транзакции'
);

-- Исполнитель обязательно с ролью «исполнитель» --------------------------------
select pg_temp.act_as('manager');
select throws_ok(
  $$ insert into public.tasks (object_id, title, assignee_id)
     values (pg_temp.fx('object_a'), 'На постановщика', '00000000-0000-4000-a000-000000000004') $$,
  '23514', null,
  'нельзя назначить исполнителем постановщика'
);
select throws_ok(
  $$ update public.tasks set assignee_id = '00000000-0000-4000-a000-000000000001'
      where id = pg_temp.fx('task_e1') $$,
  '23514', null,
  'нельзя переназначить задачу на постановщика'
);
select throws_ok(
  $$ insert into public.tasks (object_id, title, assignee_id)
     values (pg_temp.fx('object_a'), 'Без исполнителя', null) $$,
  '23514', null,
  'исполнитель обязателен: без него задача не создаётся'
);

-- Правка только в «Новая» и «На доработке» -------------------------------------
select lives_ok(
  $$ update public.tasks set title = 'Покраска стен, 2 слоя' where id = pg_temp.fx('task_e1') $$,
  'постановщик правит задачу в статусе «Новая»'
);

select pg_temp.act_as('executor1');
select lives_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e1'), 'in_progress') $$,
  'исполнитель берёт задачу в работу'
);

select pg_temp.act_as('manager');
select throws_ok(
  $$ update public.tasks set title = 'Поздняя правка' where id = pg_temp.fx('task_e1') $$,
  '55000', null,
  'постановщик не может править задачу в статусе «В работе»'
);

select pg_temp.act_as('executor1');
select public.change_task_status(pg_temp.fx('task_e1'), 'review');
select pg_temp.act_as('manager');
select throws_ok(
  $$ update public.tasks set description = 'Поздняя правка' where id = pg_temp.fx('task_e1') $$,
  '55000', null,
  'постановщик не может править задачу в статусе «На проверке»'
);

select public.change_task_status(pg_temp.fx('task_e1'), 'accepted');
select throws_ok(
  $$ update public.tasks set title = 'Правка принятой' where id = pg_temp.fx('task_e1') $$,
  '55000', null,
  'принятая задача заморожена'
);

-- Удаление запрещено -----------------------------------------------------------
select throws_ok(
  $$ delete from public.tasks where id = pg_temp.fx('task_e2') $$,
  '42501', null,
  'DELETE задачи отклоняется'
);
select throws_ok(
  $$ delete from public.objects where id = pg_temp.fx('object_b') $$,
  '42501', null,
  'DELETE объекта отклоняется'
);

-- Роль себе не поменять --------------------------------------------------------
select pg_temp.act_as('executor1');
select throws_ok(
  $$ update public.profiles set role = 'manager' where id = '00000000-0000-4000-a000-000000000002' $$,
  '42501', null,
  'пользователь не может поменять себе роль'
);
select throws_ok(
  $$ insert into public.profiles (id, full_name, role)
     values ('00000000-0000-4000-a000-000000000005', 'Новый постановщик', 'manager') $$,
  '42501', null,
  'пользователь не может завести себе профиль'
);

-- Архив объекта ----------------------------------------------------------------
select pg_temp.act_as('manager');
select throws_ok(
  $$ select public.archive_object(pg_temp.fx('object_b')) $$,
  '55000', null,
  'объект с активной задачей не архивируется'
);

select public.archive_task(pg_temp.fx('task_e2b'));
select lives_ok(
  $$ select public.archive_object(pg_temp.fx('object_b')) $$,
  'объект архивируется, когда все его задачи в архиве'
);

select * from finish();
rollback;
