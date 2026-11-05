// Единственный клиент Supabase для всего фронтенда.
//
// Работает только с публичным ключом (publishable/anon): всё, что он может,
// ограничено правами и RLS в базе. Даже если кто-то вытащит ключ из сборки,
// он получит ровно те же возможности, что и интерфейс.
import { createClient } from "@supabase/supabase-js";
import type { Database } from "./database.types";

const url = import.meta.env.VITE_SUPABASE_URL;
const publishableKey = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY;

// Без адреса и ключа приложение не сможет ни войти, ни показать данные —
// падаем сразу с понятной причиной, а не непонятной сетевой ошибкой позже.
if (!url || !publishableKey) {
  throw new Error(
    "Не заданы VITE_SUPABASE_URL и VITE_SUPABASE_PUBLISHABLE_KEY. Скопируйте .env.example в .env.local.",
  );
}

export const supabase = createClient<Database>(url, publishableKey, {
  auth: {
    // Сессия хранится в localStorage и обновляется сама: пользователь
    // не вылетает через час, когда истекает токен доступа.
    persistSession: true,
    autoRefreshToken: true,
  },
});
