-- Необязательные демо-данные: 3 объекта и задачи во всех статусах.
-- Запускать в SQL Editor после setup.sql, если база нужна не пустой.
--
-- Объекты и задачи создаются так же, как в приложении: от имени постановщика,
-- статусы двигаются от имени исполнителей через change_task_status. Для этого
-- перед каждым шагом подставляется идентификатор нужного человека
-- (request.jwt.claims), как это делает API после входа. История получается настоящей.

do $demo$
declare
  v_manager   uuid;
  v_executor1 uuid;
  v_executor2 uuid;
  v_north     uuid;
  v_office    uuid;
  v_warehouse uuid;
  v_task      uuid;
begin
  select id into v_manager   from auth.users where email = 'manager@example.com';
  select id into v_executor1 from auth.users where email = 'executor1@example.com';
  select id into v_executor2 from auth.users where email = 'executor2@example.com';

  if v_manager is null or v_executor1 is null or v_executor2 is null
     or (select count(*) from public.profiles where id in (v_manager, v_executor1, v_executor2)) < 3 then
    raise exception 'Сначала выполните setup.sql: нет пользователей или профилей';
  end if;

  -- Данные создаются один раз.
  if exists (select 1 from public.objects) then
    raise notice 'Объекты уже есть, демо-данные не создаются';
    return;
  end if;

  -- Дальше всё от имени постановщика, пока не сказано иначе.
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);

  insert into public.objects (name, address) values ('ЖК «Северный», корпус 2', 'г. Казань, ул. Северная, 12') returning id into v_north;
  insert into public.objects (name, address) values ('Офис на Лесной', 'г. Казань, ул. Лесная, 5, этаж 3') returning id into v_office;
  insert into public.objects (name, address) values ('Склад в промзоне', 'г. Казань, Промышленный проезд, 8') returning id into v_warehouse;

  -- Принята: полный путь без возвратов.
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_north, 'Демонтаж перегородок', 'Квартиры 21–24, вывоз мусора', v_executor1) returning id into v_task;
  perform set_config('request.jwt.claims', json_build_object('sub', v_executor1, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'in_progress');
  perform public.change_task_status(v_task, 'review', 'Мусор вывезен, фото в чате');
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'accepted');

  -- На проверке.
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_north, 'Штукатурка стен, 3 этаж', 'Машинная штукатурка, гипс', v_executor1) returning id into v_task;
  perform set_config('request.jwt.claims', json_build_object('sub', v_executor1, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'in_progress');
  perform public.change_task_status(v_task, 'review');
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);

  -- В работе.
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_north, 'Разводка кабеля', 'Квартиры 21–24, по проекту ЭО-2', v_executor2) returning id into v_task;
  perform set_config('request.jwt.claims', json_build_object('sub', v_executor2, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'in_progress', 'Кабель получен на складе');
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);

  -- На доработке: постановщик вернул с причиной.
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_office, 'Покраска потолков', 'Переговорная и опенспейс', v_executor2) returning id into v_task;
  perform set_config('request.jwt.claims', json_build_object('sub', v_executor2, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'in_progress');
  perform public.change_task_status(v_task, 'review');
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'rework', 'Разводы у окна в переговорной, нужен второй слой');

  -- Новая, с правкой описания — в истории будет событие «Изменена».
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_office, 'Установка дверей', '6 дверей', v_executor1) returning id into v_task;
  update public.tasks set description = '6 межкомнатных дверей, фурнитура заказчика' where id = v_task;

  -- Прошла возврат и снова в работе.
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_warehouse, 'Плитка в санузле', 'Санузел персонала, 12 м²', v_executor2) returning id into v_task;
  perform set_config('request.jwt.claims', json_build_object('sub', v_executor2, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'in_progress');
  perform public.change_task_status(v_task, 'review');
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'rework', 'Не выдержан шов у раковины');
  perform set_config('request.jwt.claims', json_build_object('sub', v_executor2, 'role', 'authenticated')::text, true);
  perform public.change_task_status(v_task, 'in_progress', 'Переделываю');
  perform set_config('request.jwt.claims', json_build_object('sub', v_manager, 'role', 'authenticated')::text, true);

  -- В архиве: создана по ошибке.
  insert into public.tasks (object_id, title, description, assignee_id)
  values (v_warehouse, 'Замер помещения', 'Создана по ошибке', v_executor1) returning id into v_task;
  perform public.archive_task(v_task);

  raise notice 'Демо-данные созданы: 3 объекта, 7 задач';
end
$demo$;
