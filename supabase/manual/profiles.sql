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
