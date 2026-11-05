-- Журнал событий задачи: что пишется, кем и что его нельзя подделать.
begin;
\ir _fixtures.psql

select plan(14);

-- Создание -------------------------------------------------------------------
select pg_temp.act_as('owner');
select results_eq(
  $$ select event, from_status::text, to_status::text, actor_id
       from public.task_history where task_id = pg_temp.fx('task_e1') $$,
  $$ values ('created', null::text, 'new', '00000000-0000-4000-a000-000000000001'::uuid) $$,
  'создание задачи пишет событие created с переходом «— → Новая» от постановщика'
);

-- Смена статуса --------------------------------------------------------------
select pg_temp.act_as('executor1');
select public.change_task_status(pg_temp.fx('task_e1'), 'in_progress', 'Начинаю с утра');
select public.change_task_status(pg_temp.fx('task_e1'), 'review');
select pg_temp.act_as('manager');
select public.change_task_status(pg_temp.fx('task_e1'), 'rework', 'Не докрашен угол');

select pg_temp.act_as('owner');
select results_eq(
  $$ select actor_id, from_status::text, to_status::text, comment
       from public.task_history
      where task_id = pg_temp.fx('task_e1') and event = 'status_changed'
      order by id $$,
  $$ values
       ('00000000-0000-4000-a000-000000000002'::uuid, 'new',         'in_progress', 'Начинаю с утра'),
       ('00000000-0000-4000-a000-000000000002'::uuid, 'in_progress', 'review',      null),
       ('00000000-0000-4000-a000-000000000001'::uuid, 'review',      'rework',      'Не докрашен угол') $$,
  'каждая смена статуса пишет автора, статусы «из» и «в» и комментарий; порядок по id совпадает с хронологией'
);

select ok(
  (select bool_and(created_at is not null) from public.task_history where task_id = pg_temp.fx('task_e1')),
  'время каждого события ставит база'
);

-- Правка полей ----------------------------------------------------------------
select pg_temp.act_as('manager');
update public.tasks
   set title = 'Покраска стен и потолка', description = 'Два слоя'
 where id = pg_temp.fx('task_e1');

select pg_temp.act_as('owner');
select results_eq(
  $$ select event, changes
       from public.task_history
      where task_id = pg_temp.fx('task_e1') and event = 'updated' $$,
  $$ values ('updated', '{"title": {"old": "Задача исполнителя 1", "new": "Покраска стен и потолка"},
                          "description": {"old": "Покраска стен", "new": "Два слоя"}}'::jsonb) $$,
  'правка полей пишет событие updated с «было и стало» только по изменённым полям'
);

-- Пустое обновление ничего не пишет.
select pg_temp.act_as('manager');
update public.tasks set title = title where id = pg_temp.fx('task_e1');
select pg_temp.act_as('owner');
select is(
  (select count(*)::int from public.task_history where task_id = pg_temp.fx('task_e1') and event = 'updated'),
  1,
  'обновление без изменений в историю не попадает'
);

-- Архив ------------------------------------------------------------------------
select pg_temp.act_as('manager');
select public.archive_task(pg_temp.fx('task_e2'));
select pg_temp.act_as('owner');
select results_eq(
  $$ select event, actor_id from public.task_history
      where task_id = pg_temp.fx('task_e2') order by id desc limit 1 $$,
  $$ values ('archived', '00000000-0000-4000-a000-000000000001'::uuid) $$,
  'архивация пишет событие archived от постановщика'
);

-- Подделка истории клиентом ------------------------------------------------------
select pg_temp.act_as('executor1');
select throws_ok(
  $$ insert into public.task_history (task_id, actor_id, event, to_status)
     values (pg_temp.fx('task_e1'), '00000000-0000-4000-a000-000000000001', 'status_changed', 'accepted') $$,
  '42501', null,
  'вставка в историю от клиента отклоняется'
);
select throws_ok(
  $$ update public.task_history set comment = 'исправлено' where task_id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'изменение истории от клиента отклоняется'
);
select throws_ok(
  $$ delete from public.task_history where task_id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'удаление истории от клиента отклоняется'
);

-- Подделка истории владельцем и служебным ключом ----------------------------------
select pg_temp.act_as('owner');
select throws_ok(
  $$ update public.task_history set comment = 'исправлено' where task_id = pg_temp.fx('task_e1') $$,
  '42501', 'Журнал задачи только на добавление: изменять и удалять записи нельзя',
  'UPDATE истории отклоняется даже от владельца таблиц'
);
select throws_ok(
  $$ delete from public.task_history where task_id = pg_temp.fx('task_e1') $$,
  '42501', 'Журнал задачи только на добавление: изменять и удалять записи нельзя',
  'DELETE истории отклоняется даже от владельца таблиц'
);
select throws_ok(
  $$ truncate public.task_history cascade $$,
  '42501', 'Журнал задачи только на добавление: изменять и удалять записи нельзя',
  'TRUNCATE истории отклоняется даже от владельца таблиц'
);

select pg_temp.act_as('service');
select throws_ok(
  $$ delete from public.task_history where task_id = pg_temp.fx('task_e1') $$,
  '42501', null,
  'служебный ключ тоже не удаляет историю'
);

-- Задачу с историей не удалить даже владельцу: внешний ключ RESTRICT.
select pg_temp.act_as('owner');
select throws_ok(
  $$ delete from public.tasks where id = pg_temp.fx('task_e1') $$,
  '23503', null,
  'задачу с историей нельзя удалить даже владельцу таблиц'
);

select * from finish();
rollback;
