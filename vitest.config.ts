// Два набора тестов с разными требованиями к окружению:
//   unit — чистая логика фронтенда, запускается без базы (npm test);
//   api  — атаки через REST на живой Supabase, нужен запущенный стек
//          и заполненные данные (npm run test:api).
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    projects: [
      {
        test: {
          name: "unit",
          include: ["src/**/*.test.ts"],
          environment: "node",
        },
      },
      {
        test: {
          name: "api",
          include: ["tests/api/**/*.test.ts"],
          environment: "node",
          // Сетевые запросы к облаку бывают медленнее локальных.
          testTimeout: 20_000,
          hookTimeout: 60_000,
          // Тесты атак меняют общие данные (создают и архивируют свою задачу),
          // поэтому файлы выполняются по очереди.
          fileParallelism: false,
        },
      },
    ],
  },
});
