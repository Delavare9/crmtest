-- Вспомогательные функции для политик RLS, триггеров и RPC.
--
-- Служебные функции живут в схеме private: она не входит в api.schemas
-- (supabase/config.toml), поэтому их нельзя вызвать через REST /rpc.
-- В public остаётся только то, что клиенту действительно нужно вызывать.

create schema if not exists private;

-- Никто, кроме владельца, не может обращаться к объектам схемы private напрямую.
-- Триггеры и функции с SECURITY DEFINER работают от владельца, им это не мешает.
revoke all on schema private from public, anon, authenticated;

-- Роль приложения текущего пользователя (или NULL для анонима и для запросов
-- служебным ключом, у которых нет пользователя).
--
-- SECURITY DEFINER нужен, чтобы читать profiles в обход RLS: иначе политика
-- profiles_read, которая сама зовёт эту функцию, зациклилась бы на себе.
-- STABLE + обёртка (select …) в политиках дают одно вычисление на запрос,
-- а не на каждую строку.
create or replace function public.current_app_role()
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = auth.uid()
$$;

comment on function public.current_app_role() is
  'Роль вошедшего пользователя из profiles; NULL, если пользователя нет или у него нет профиля.';

-- Роль произвольного пользователя. Нужна триггерам, чтобы проверить, что
-- исполнителем назначают именно исполнителя. Клиенту не выдаётся: по ней можно
-- было бы перебором узнать роли чужих пользователей.
create or replace function private.role_of(p_user_id uuid)
returns public.app_role
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p where p.id = p_user_id
$$;

-- Общая проверка для всех изменяющих действий: есть вошедший пользователь
-- и у него заведён профиль. Возвращает его роль, чтобы не читать её дважды.
-- Запросы служебным ключом (service_role) пользователя не имеют и сюда не проходят:
-- так история всегда знает, кто совершил действие.
create or replace function private.require_actor()
returns public.app_role
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role public.app_role;
begin
  if auth.uid() is null then
    raise exception 'Действие доступно только вошедшему пользователю'
      using errcode = '42501';
  end if;

  v_role := private.role_of(auth.uid());
  if v_role is null then
    raise exception 'У пользователя нет профиля, обратитесь к администратору'
      using errcode = '42501';
  end if;

  return v_role;
end
$$;
