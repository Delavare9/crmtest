-- Идентификаторы: все свои ключи — UUID v7 с правильной версией, вариантом
-- и временем; созданное позже имеет больший id.
begin;
\ir _fixtures.psql

select plan(8);

select pg_temp.act_as('owner');

select has_function('public', 'uuid_generate_v7', 'генератор UUID v7 установлен');

-- Версия и вариант по RFC 9562: старшая тетрада байта 6 = 7,
-- старшие два бита байта 8 = 10.
select is(
  (select array_agg(distinct uuid_extract_version(id)) from (
     select id from public.objects
     union all select id from public.tasks
     union all select id from public.task_history) s),
  array[7::smallint],
  'id объектов, задач и истории имеют версию 7'
);

select ok(
  (select bool_and(get_byte(uuid_send(id), 8) >> 6 = 2) from (
     select id from public.objects
     union all select id from public.tasks
     union all select id from public.task_history) s),
  'у всех id корректный вариант (биты 10)'
);

-- Первые 48 бит — миллисекунды Unix-времени. Сверяем с часами базы.
select ok(
  abs(
    (('x' || substr(replace(public.uuid_generate_v7()::text, '-', ''), 1, 12))::bit(48)::bigint)
    - (extract(epoch from clock_timestamp()) * 1000)::bigint
  ) < 1000,
  'метка времени в id совпадает с текущим временем с точностью до секунды'
);

-- Порядок: задача, созданная позже, получает больший id.
select pg_temp.act_as('manager');
with t as (
  insert into public.tasks (object_id, title, assignee_id)
  values (pg_temp.fx('object_a'), 'Первая', '00000000-0000-4000-a000-000000000002') returning id)
insert into fx select 'first', id from t;
with t as (
  insert into public.tasks (object_id, title, assignee_id)
  values (pg_temp.fx('object_a'), 'Вторая', '00000000-0000-4000-a000-000000000002') returning id)
insert into fx select 'second', id from t;

select ok(
  pg_temp.fx('second') > pg_temp.fx('first'),
  'id задачи, созданной позже, больше id предыдущей'
);

select pg_temp.act_as('owner');

-- Монотонность внутри одной миллисекунды обеспечивают 12 бит долей миллисекунды.
select ok(
  (select bool_and(prev < id) from (
     select id, lag(id) over (order by n) as prev
       from (select n, public.uuid_generate_v7() as id from generate_series(1, 5000) n) g
   ) s where prev is not null),
  '5000 id подряд строго возрастают'
);

select is(
  (select count(distinct public.uuid_generate_v7())::int from generate_series(1, 10000)),
  10000,
  '10 000 id без повторов'
);

-- Клиент id не задаёт: поле id не выдано в правах на вставку (см. 02_writes),
-- а триггер перезаписывает id даже у владельца.
select pg_temp.act_as('manager');
reset role;
with t as (
  insert into public.objects (id, name) values ('00000000-0000-4000-8000-00000000abcd', 'Подставной id')
  returning id)
insert into fx select 'forced', id from t;
select ok(
  uuid_extract_version(pg_temp.fx('forced')) = 7
    and pg_temp.fx('forced') <> '00000000-0000-4000-8000-00000000abcd',
  'переданный вручную id заменяется на сгенерированный базой'
);

select * from finish();
rollback;
