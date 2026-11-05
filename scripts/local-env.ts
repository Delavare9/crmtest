// Создаёт .env.local для работы с локальным Supabase (npm run env:local).
//
// Адрес и ключи берутся из `supabase status` запущенного стека. Пароль
// демо-пользователей не хранится в репозитории: если в .env.local он уже есть,
// он сохраняется, иначе генерируется случайный и печатается один раз.
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";

const FILE = ".env.local";

// JSON-вывод статуса: API_URL, PUBLISHABLE_KEY, SECRET_KEY и др.
// Если стек не запущен, команда завершится с ошибкой — подсказываем, что делать.
let status: Record<string, string>;
try {
  status = JSON.parse(execFileSync("npx", ["supabase", "status", "-o", "json"], { encoding: "utf8" }));
} catch {
  console.error("Локальный Supabase не запущен. Сначала: npm run db:start");
  process.exit(1);
}

// Сохраняем пароль из прошлого файла, чтобы не сломать уже заведённых пользователей.
const previous = existsSync(FILE) ? readFileSync(FILE, "utf8") : "";
const keptPassword = /^SEED_PASSWORD=(.+)$/m.exec(previous)?.[1];
const password = keptPassword ?? randomBytes(12).toString("base64url");

writeFileSync(
  FILE,
  [
    "# Сгенерировано npm run env:local для локального стека. В git не попадает.",
    `VITE_SUPABASE_URL=${status.API_URL}`,
    `VITE_SUPABASE_PUBLISHABLE_KEY=${status.PUBLISHABLE_KEY}`,
    `SUPABASE_SECRET_KEY=${status.SECRET_KEY}`,
    `SEED_PASSWORD=${password}`,
    "",
  ].join("\n"),
);

console.log(`${FILE} записан.`);
if (!keptPassword) console.log(`Пароль демо-пользователей: ${password}`);
