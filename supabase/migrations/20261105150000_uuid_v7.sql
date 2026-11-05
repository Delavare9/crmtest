-- Генератор идентификаторов UUID v7 (RFC 9562) для всех таблиц приложения.
--
-- Зачем v7, а не случайный v4: первые 48 бит — время создания в миллисекундах.
-- Новые строки ложатся в конец индекса первичного ключа (меньше разбиений страниц
-- и раздувания индекса), а сортировка по id совпадает с хронологией, что удобно
-- для журнала событий задачи.
--
-- Где работает: в PostgreSQL 18+ есть встроенная pg_catalog.uuidv7(), и миграция
-- просто оборачивает её. Supabase на момент написания работает на PostgreSQL 17
-- (CLI 3.0.0 не принимает db.major_version = 18), поэтому применяется своя
-- реализация на plpgsql. При переходе проекта на 18 достаточно повторить эту
-- миграцию (или создать новую с тем же телом) — имя функции и все DEFAULT в
-- таблицах останутся прежними.
--
-- Идентификаторы пользователей выдаёт Supabase Auth (UUID v4), их не трогаем.

do $migration$
begin
  if current_setting('server_version_num')::int >= 180000 then
    -- Встроенная функция сама гарантирует рост значений внутри одного соединения,
    -- даже если несколько id выдаются в одну миллисекунду.
    execute $fn$
      create or replace function public.uuid_generate_v7()
      returns uuid
      language sql
      volatile
      parallel safe
      set search_path = ''
      as 'select pg_catalog.uuidv7()'
    $fn$;
  else
    execute $fn$
      create or replace function public.uuid_generate_v7()
      returns uuid
      language plpgsql
      volatile
      parallel safe
      set search_path = ''
      as $body$
      declare
        -- Время берём из clock_timestamp(), а не now(): now() одинаково для всей
        -- транзакции, и все id одной транзакции получили бы одну метку.
        v_us  bigint  := (extract(epoch from clock_timestamp()) * 1000000)::bigint;
        v_ms  bigint  := v_us / 1000;
        -- Доли миллисекунды (0..999 мкс) растягиваем на 12 бит поля rand_a
        -- (метод 3 из RFC 9562, так же делает PostgreSQL 18). Благодаря этому
        -- id, выданные в одну миллисекунду, тоже идут по возрастанию с точностью
        -- до микросекунды.
        v_sub int     := ((v_us % 1000) * 4096 / 1000)::int;
        -- Остальные 62 бита берём из случайного v4: у него уже выставлен
        -- вариант 10 (RFC 4122/9562), остаётся только заменить время и версию.
        v_b   bytea   := uuid_send(gen_random_uuid());
      begin
        -- Байты 0..5: 48 бит миллисекунд Unix-времени (int8send даёт 8 байт,
        -- старшие 2 отбрасываем).
        v_b := overlay(v_b placing substring(int8send(v_ms) from 3) from 1 for 6);
        -- Байт 6: старшая тетрада = версия 7 (0111), младшая = старшие 4 бита долей.
        v_b := set_byte(v_b, 6, 112 | (v_sub >> 8));
        -- Байт 7: младшие 8 бит долей миллисекунды.
        v_b := set_byte(v_b, 7, v_sub & 255);
        return encode(v_b, 'hex')::uuid;
      end
      $body$
    $fn$;
  end if;
end
$migration$;

comment on function public.uuid_generate_v7() is
  'UUID v7: 48 бит времени в мс + 12 бит долей мс + случайная часть. На PG18+ обёртка над uuidv7().';
