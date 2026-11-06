// Собирает supabase/manual/setup.sql — один файл для вставки в SQL Editor
// облачного Supabase, когда база заводится вручную, без CLI (npm run setup:sql).
//
// Состав: все миграции по порядку, отметки о них в истории миграций
// (чтобы позже `supabase db push` не пытался применить их второй раз),
// затем профили трёх пользователей из supabase/manual/profiles.sql.
// Демо-данные (supabase/manual/demo-data.sql) сюда не входят: база остаётся
// пустой, при желании их запускают отдельно.
// Всё в одной транзакции: при любой ошибке база остаётся как была.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const MIGRATIONS = "supabase/migrations";
const OUT = "supabase/manual/setup.sql";

// Имена файлов вида 20261105150000_uuid_v7.sql: версия — цифры до подчёркивания.
const files = readdirSync(MIGRATIONS)
  .filter((name) => name.endsWith(".sql"))
  .sort();

const parts: string[] = [
  "-- Ручная установка базы: вставить целиком в Supabase → SQL Editor → Run.",
  "-- Перед запуском создайте в Authentication → Users трёх пользователей",
  "-- (manager@example.com, executor1@example.com, executor2@example.com) с галочкой Auto Confirm.",
  "-- Файл собран командой npm run setup:sql из supabase/migrations — не редактировать вручную.",
  "",
  "begin;",
  "",
];

for (const name of files) {
  parts.push(`-- ===== ${name} =====`, readFileSync(join(MIGRATIONS, name), "utf8").trim(), "");
}

// Та же таблица, которую ведёт Supabase CLI: версия миграции и её имя.
parts.push(
  "-- ===== история миграций =====",
  "create schema if not exists supabase_migrations;",
  "create table if not exists supabase_migrations.schema_migrations (version text primary key, statements text[], name text);",
  ...files.map((name) => {
    const [version, ...rest] = name.replace(/\.sql$/, "").split("_");
    return `insert into supabase_migrations.schema_migrations (version, name) values ('${version}', '${rest.join("_")}') on conflict do nothing;`;
  }),
  "",
  "-- ===== профили пользователей =====",
  readFileSync("supabase/manual/profiles.sql", "utf8").trim(),
  "",
  "commit;",
  "",
);

writeFileSync(OUT, parts.join("\n"));
console.log(`${OUT}: ${files.length} миграций + профили`);
