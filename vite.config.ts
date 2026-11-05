// Сборка фронтенда. Плагин React включает JSX-трансформацию и Fast Refresh
// в режиме разработки; остальное — настройки Vite по умолчанию.
import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: {
    // Адрес и порт совпадают с site_url в supabase/config.toml.
    host: "127.0.0.1",
    port: 5173,
    strictPort: true,
  },
});
