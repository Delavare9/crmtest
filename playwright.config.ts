// Сквозной тест интерфейса: настоящий браузер, настоящий вход, локальный
// или облачный Supabase из .env.local. Нужны npm run seed и браузер
// (npx playwright install chromium — один раз).
import { defineConfig, devices } from "@playwright/test";

export default defineConfig({
  testDir: "tests/e2e",
  // Сценарий проходит по шагам от имени разных людей — параллелить нечего.
  workers: 1,
  timeout: 60_000,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: "http://127.0.0.1:5173",
    trace: "retain-on-failure",
    // Если браузер уже стоит в системе (например, в контейнере), путь к нему
    // можно передать через PLAYWRIGHT_CHROMIUM_PATH вместо установки.
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_PATH
      ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_PATH }
      : {},
  },
  projects: [{ name: "desktop", use: { ...devices["Desktop Chrome"] } }],
  // Фронтенд поднимается сам и останавливается после тестов.
  webServer: {
    command: "npm run dev",
    url: "http://127.0.0.1:5173",
    reuseExistingServer: !process.env.CI,
  },
});
