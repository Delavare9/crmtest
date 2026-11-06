-- Чтение: кто какие строки видит. Проверяется сама база (RLS и права),
-- без интерфейса: так же, как если бы запрос пришёл через REST с токеном.
begin;
\ir _fixtures.psql

select plan(17);

-- Исполнитель 1 -------------------------------------------------------------
select pg_temp.act_as('executor1');

select results_eq(
  $$ select id from public.tasks order by id $$,
  $$ select pg_temp.fx('task_e1') $$,
  'исполнитель видит только свои задачи'
);

select is_empty(
  $$ select 1 from public.tasks where assignee_id = '00000000-0000-4000-a000-000000000003' $$,
  'исполнитель не видит задачи другого исполнителя даже при явном фильтре'
);

select results_eq(
  $$ select id from public.objects order by id $$,
  $$ select pg_temp.fx('object_a') $$,
  'исполнитель видит только объект, где у него есть задача'
);

select is_empty(
  $$ select 1 from public.objects where id = pg_temp.fx('object_b') $$,
  'исполнитель не видит объект, где у него нет задач'
);

-- Ожидаемый набор считается от владельца: в базе могут быть и другие
-- постановщики (демо-данные), их исполнитель тоже должен видеть.
select pg_temp.act_as('owner');
create temp table expected_profiles on commit drop as
  select id from public.profiles
   where id = '00000000-0000-4000-a000-000000000002' or role = 'manager';
grant select on expected_profiles to authenticated;
select pg_temp.act_as('executor1');
select set_eq(
  $$ select id from public.profiles $$,
  $$ select id from expected_profiles $$,
  'исполнитель видит свой профиль и профили постановщиков, но не других исполнителей'
);

select is_empty(
  $$ select 1 from public.task_history where task_id = pg_temp.fx('task_e2') $$,
  'исполнитель не видит историю чужой задачи'
);

select isnt_empty(
  $$ select 1 from public.task_history where task_id = pg_temp.fx('task_e1') $$,
  'исполнитель видит историю своей задачи'
);

select is(
  (select count(*)::int from public.task_transitions),
  5,
  'правила переходов видны вошедшему пользователю (по ним строятся кнопки)'
);

-- Архивная задача пропадает у исполнителя (решение 8) --------------------------
select pg_temp.act_as('manager');
select lives_ok(
  $$ select public.archive_task(pg_temp.fx('task_e1')) $$,
  'постановщик архивирует задачу исполнителя 1'
);

select pg_temp.act_as('executor1');
select is_empty(
  $$ select 1 from public.tasks $$,
  'исполнитель не видит свою задачу после архивации'
);
select is_empty(
  $$ select 1 from public.objects $$,
  'объект без активных задач исполнителя пропадает из его списка'
);

-- Постановщик ----------------------------------------------------------------
select pg_temp.act_as('manager');

-- Считаем только задачи теста: в базе могут лежать демо-данные.
select is(
  (select count(*)::int from public.tasks
    where id in (pg_temp.fx('task_e1'), pg_temp.fx('task_e2'), pg_temp.fx('task_e2b'))),
  3,
  'постановщик видит все задачи, включая архивные'
);
select pg_temp.act_as('owner');
create temp table all_profiles on commit drop as select count(*)::int as n from public.profiles;
grant select on all_profiles to authenticated;
select pg_temp.act_as('manager');
select is(
  (select count(*)::int from public.profiles),
  (select n from all_profiles),
  'постановщик видит все профили'
);

-- Аноним и пользователь без профиля -------------------------------------------
select pg_temp.act_as('anon');

select throws_ok(
  $$ select * from public.tasks $$,
  '42501', null,
  'аноним без входа не читает задачи: прав на таблицу нет'
);
select throws_ok(
  $$ select * from public.profiles $$,
  '42501', null,
  'аноним без входа не читает профили'
);
select throws_ok(
  $$ select * from public.task_history $$,
  '42501', null,
  'аноним без входа не читает историю'
);

select pg_temp.act_as('noprofile');
select is_empty(
  $$ select 1 from public.tasks union all select 1 from public.objects $$,
  'вошедший без профиля не видит ни задач, ни объектов'
);

select * from finish();
rollback;
