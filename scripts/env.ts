// Общие настройки для скрипта заполнения и тестов атак: переменные окружения,
// демо-пользователи и создание клиентов Supabase.
//
// Работает только на машине администратора или в CI: здесь используется
// служебный ключ (SUPABASE_SECRET_KEY), который никогда не попадает во фронтенд.
import { config } from "dotenv";
import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../src/lib/database.types";

// .env.local — локальные значения владельца (в .gitignore), .env — запасной.
// quiet: dotenv 17+ по умолчанию печатает, сколько переменных загрузил.
config({ path: [".env.local", ".env"], quiet: true });

export type Db = SupabaseClient<Database>;

// Читает обязательную переменную или останавливает скрипт с понятной причиной.
export function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Не задана переменная ${name}. Посмотрите .env.example и docs/OPERATIONS.md.`);
  }
  return value;
}

export const SUPABASE_URL = () => requireEnv("VITE_SUPABASE_URL");
export const PUBLISHABLE_KEY = () => requireEnv("VITE_SUPABASE_PUBLISHABLE_KEY");
export const SECRET_KEY = () => requireEnv("SUPABASE_SECRET_KEY");

// Пароль демо-пользователей задаёт владелец (выбор владельца): в репозитории
// его нет. Минимум 8 символов — так же настроено в supabase/config.toml.
export function seedPassword(): string {
  const password = requireEnv("SEED_PASSWORD");
  if (password.length < 8) throw new Error("SEED_PASSWORD должен быть не короче 8 символов");
  return password;
}

// Демо-пользователи. Почта на домене example.com (зарезервирован для примеров,
// письма туда не уходят). Имена и адреса — выбор владельца, меняются здесь.
export const DEMO_USERS = {
  manager: { email: "manager@example.com", full_name: "Анна Петрова", role: "manager" },
  executor1: { email: "executor1@example.com", full_name: "Иван Смирнов", role: "executor" },
  executor2: { email: "executor2@example.com", full_name: "Олег Кузнецов", role: "executor" },
} as const;

export type DemoUserKey = keyof typeof DEMO_USERS;

// Клиент со служебным ключом: обходит RLS. Только для заведения пользователей,
// профилей и проверок в тестах — данные задач через него не создаются.
export function adminClient(): Db {
  return createClient<Database>(SUPABASE_URL(), SECRET_KEY(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Клиент с публичным ключом — ровно то, что есть у браузера.
export function publicClient(): Db {
  return createClient<Database>(SUPABASE_URL(), PUBLISHABLE_KEY(), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

// Вошедший пользователь: публичный ключ + настоящий вход по паролю.
// Все действия такого клиента база видит как действия этого человека.
export async function signedInClient(key: DemoUserKey): Promise<{ client: Db; userId: string }> {
  const client = publicClient();
  const { data, error } = await client.auth.signInWithPassword({
    email: DEMO_USERS[key].email,
    password: seedPassword(),
  });
  if (error) throw new Error(`Не удалось войти как ${DEMO_USERS[key].email}: ${error.message}`);
  return { client, userId: data.user.id };
}
