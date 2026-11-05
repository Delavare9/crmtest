/// <reference types="vite/client" />

// Переменные окружения, которые Vite встраивает во фронтенд при сборке.
// Во фронтенд попадает только то, что начинается с VITE_, поэтому служебный
// ключ (SUPABASE_SECRET_KEY) сюда не утечёт, даже если лежит в том же .env.
interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string;
  readonly VITE_SUPABASE_PUBLISHABLE_KEY: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
