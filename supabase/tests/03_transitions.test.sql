-- Переходы статусов: все пять разрешённых проходят у нужной роли, все
-- остальные пары «из → в» отклоняются у обеих ролей.
begin;
\ir _fixtures.psql

select plan(20);

-- Полный цикл с возвратом на доработку ------------------------------------------
select pg_temp.act_as('executor1');
select results_eq(
  $$ select status::text from public.change_task_status(pg_temp.fx('task_e1'), 'in_progress') $$,
  array['in_progress'],
  'исполнитель: Новая → В работе'
);
select results_eq(
  $$ select status::text from public.change_task_status(pg_temp.fx('task_e1'), 'review') $$,
  array['review'],
  'исполнитель: В работе → На проверке'
);

select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e1'), 'accepted') $$,
  '42501', 'Переход review → accepted запрещён',
  'исполнитель не может сам принять свою работу'
);

select pg_temp.act_as('manager');
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e1'), 'rework') $$,
  '23514', 'Для этого перехода нужен комментарий',
  'возврат на доработку без комментария отклоняется'
);
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e1'), 'rework', '   ') $$,
  '23514', 'Для этого перехода нужен комментарий',
  'комментарий из одних пробелов не считается'
);
select results_eq(
  $$ select status::text from public.change_task_status(pg_temp.fx('task_e1'), 'rework', 'Не докрашен угол') $$,
  array['rework'],
  'постановщик: На проверке → На доработке с комментарием'
);

select pg_temp.act_as('executor1');
select results_eq(
  $$ select status::text from public.change_task_status(pg_temp.fx('task_e1'), 'in_progress') $$,
  array['in_progress'],
  'исполнитель: На доработке → В работе'
);
select public.change_task_status(pg_temp.fx('task_e1'), 'review');

select pg_temp.act_as('manager');
select results_eq(
  $$ select status::text from public.change_task_status(pg_temp.fx('task_e1'), 'accepted') $$,
  array['accepted'],
  'постановщик: На проверке → Принята'
);

-- Перебор всех запрещённых пар -------------------------------------------------
-- Для каждой пары статусов, которой нет в task_transitions для данной роли,
-- ставим задачу в исходный статус в обход правил (только для теста — как
-- владелец таблиц с отключённым триггером) и пробуем перейти.
select pg_temp.act_as('owner');
create temp table forbidden_results (actor text, from_s text, to_s text, sqlstate text) on commit drop;

do $$
declare
  v_from public.task_status;
  v_to   public.task_status;
  v_who  text;
  v_role public.app_role;
  v_task uuid := pg_temp.fx('task_e2');
  v_state text;
begin
  foreach v_who in array array['manager', 'executor2'] loop
    v_role := case v_who when 'manager' then 'manager' else 'executor' end;
    foreach v_from in array enum_range(null::public.task_status) loop
      foreach v_to in array enum_range(null::public.task_status) loop
        continue when exists (select 1 from public.task_transitions t
                               where t.from_status = v_from and t.to_status = v_to
                                 and t.actor_role = v_role);
        -- Ставим исходный статус в обход правил: только в тесте и только владельцем.
        perform pg_temp.act_as('owner');
        alter table public.tasks disable trigger tasks_before_update;
        alter table public.tasks disable trigger tasks_log_update;
        update public.tasks set status = v_from where id = v_task;
        alter table public.tasks enable trigger tasks_before_update;
        alter table public.tasks enable trigger tasks_log_update;

        perform pg_temp.act_as(v_who);
        v_state := 'ok';
        begin
          perform public.change_task_status(v_task, v_to, 'комментарий для проверки');
        exception when others then
          v_state := sqlstate;
        end;
        perform pg_temp.act_as('owner');
        insert into forbidden_results values (v_who, v_from::text, v_to::text, v_state);
      end loop;
    end loop;
  end loop;
end
$$;

select is(
  (select count(*)::int from forbidden_results),
  45,
  'перебраны все 50 пар статусов для двух ролей за вычетом 5 разрешённых'
);
select is_empty(
  $$ select * from forbidden_results where sqlstate = 'ok' $$,
  'ни один запрещённый переход не прошёл'
);
select is_empty(
  $$ select * from forbidden_results where sqlstate <> '42501' $$,
  'каждый запрещённый переход отклонён с кодом «нет прав»'
);

-- Возвращаем задаче исполнителя 2 нормальный статус для следующих проверок.
alter table public.tasks disable trigger tasks_before_update;
alter table public.tasks disable trigger tasks_log_update;
update public.tasks set status = 'new' where id = pg_temp.fx('task_e2');
alter table public.tasks enable trigger tasks_before_update;
alter table public.tasks enable trigger tasks_log_update;

-- Конкретные запрещённые переходы из ТЗ -------------------------------------------
select pg_temp.act_as('executor2');
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e2'), 'accepted') $$,
  '42501', 'Переход new → accepted запрещён',
  'Новая → Принята отклоняется'
);
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e2'), 'review') $$,
  '42501', 'Переход new → review запрещён',
  'нельзя перескочить через «В работе»'
);

-- Чужая задача неотличима от несуществующей ---------------------------------------
select pg_temp.act_as('executor1');
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e2'), 'in_progress') $$,
  'P0002', 'Задача не найдена',
  'чужой исполнитель не может взять задачу: «задача не найдена»'
);
select throws_ok(
  $$ select public.change_task_status(gen_random_uuid(), 'in_progress') $$,
  'P0002', 'Задача не найдена',
  'несуществующая задача даёт тот же ответ, что и чужая'
);

-- Архивная задача --------------------------------------------------------------
select pg_temp.act_as('manager');
select public.archive_task(pg_temp.fx('task_e2b'));
select pg_temp.act_as('executor2');
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e2b'), 'in_progress') $$,
  'P0002', 'Задача не найдена',
  'переход в архивной задаче отклоняется'
);

-- Обход функции ----------------------------------------------------------------
select pg_temp.act_as('owner');
select throws_ok(
  $$ update public.tasks set status = 'in_progress' where id = pg_temp.fx('task_e2') $$,
  '42501', null,
  'прямой UPDATE статуса от владельца таблиц в обход функции отклоняется триггером'
);

select pg_temp.act_as('service');
select throws_ok(
  $$ update public.tasks set status = 'in_progress' where id = pg_temp.fx('task_e2') $$,
  '42501', null,
  'служебный ключ тоже не меняет статус напрямую'
);

-- Самый строгий случай: владелец таблиц, сессия исполнителя 2, его задача,
-- переход «Новая → В работе» разрешён. Не хватает только вызова через функцию —
-- и этого достаточно для отказа.
select pg_temp.act_as('executor2');
reset role;
select throws_ok(
  $$ update public.tasks set status = 'in_progress' where id = pg_temp.fx('task_e2') $$,
  '42501', 'Статус меняется только через change_task_status()',
  'даже допустимый переход не проходит прямым UPDATE без функции'
);

-- Без входа и без профиля ----------------------------------------------------------
select pg_temp.act_as('anon');
select throws_ok(
  $$ select public.change_task_status(pg_temp.fx('task_e2'), 'in_progress') $$,
  '42501', null,
  'аноним не может вызвать функцию смены статуса'
);

select * from finish();
rollback;
