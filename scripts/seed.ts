// Заполнение базы демо-данными: 1 постановщик, 2 исполнителя, 3 объекта
// и задачи во всех статусах.
//
// Пользователей и профили заводит служебный ключ (через API их создать нельзя —
// регистрация закрыта). Всё остальное делается от имени настоящих
// пользователей через вход по паролю: объекты и задачи создаёт постановщик,
// статусы двигают исполнители и постановщик через change_task_status.
// Поэтому история в демо-данных настоящая, а не вставленная вручную.
//
// Запуск: npm run seed. Повторный запуск обновит пароли и профили,
// но не создаст задачи второй раз, если объекты уже есть.
import { DEMO_USERS, adminClient, seedPassword, signedInClient, type Db, type DemoUserKey } from "./env";
import type { TaskStatus } from "../src/lib/types";

const admin = adminClient();

// Находит пользователя Auth по email или создаёт его с подтверждённой почтой.
// Если пользователь уже есть, пароль приводится к SEED_PASSWORD, чтобы
// входы ниже и тесты атак работали с одним и тем же паролем.
async function ensureUser(key: DemoUserKey): Promise<string> {
  const { email } = DEMO_USERS[key];
  const password = seedPassword();

  // Пользователей несколько, первой страницы (до 1000) достаточно.
  const { data: list, error: listError } = await admin.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (listError) throw listError;
  const existing = list.users.find((user) => user.email === email);

  if (existing) {
    const { error } = await admin.auth.admin.updateUserById(existing.id, { password });
    if (error) throw error;
    return existing.id;
  }

  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw error;
  return data.user.id;
}

// Профиль с именем и ролью. upsert — чтобы повторный запуск не падал.
async function ensureProfile(key: DemoUserKey, userId: string): Promise<void> {
  const { full_name, role } = DEMO_USERS[key];
  const { error } = await admin.from("profiles").upsert({ id: userId, full_name, role });
  if (error) throw error;
}

// Двигает задачу по цепочке статусов от имени нужных людей.
// Каждый шаг — вызов той же функции, что и в интерфейсе.
async function walk(taskId: string, steps: { by: Db; to: TaskStatus; comment?: string }[]): Promise<void> {
  for (const step of steps) {
    const { error } = await step.by.rpc("change_task_status", {
      p_task_id: taskId,
      p_to: step.to,
      ...(step.comment ? { p_comment: step.comment } : {}),
    });
    if (error) throw new Error(`Переход в ${step.to} для задачи ${taskId}: ${error.message}`);
  }
}

async function main() {
  console.log("1/3 Пользователи и профили");
  const ids = {} as Record<DemoUserKey, string>;
  for (const key of Object.keys(DEMO_USERS) as DemoUserKey[]) {
    ids[key] = await ensureUser(key);
    await ensureProfile(key, ids[key]);
    console.log(`    ${DEMO_USERS[key].email} — ${DEMO_USERS[key].role}`);
  }

  // Данные создаём один раз: если объекты уже есть, второй набор задач
  // только запутает демонстрацию.
  const { count, error: countError } = await admin
    .from("objects")
    .select("id", { count: "exact", head: true });
  if (countError) throw countError;
  if ((count ?? 0) > 0) {
    console.log(
      `2/3 Объекты уже есть (${count}), данные не создаются. Для чистой локальной базы: npm run db:reset`,
    );
    return;
  }

  console.log("2/3 Вход под каждым пользователем");
  const manager = (await signedInClient("manager")).client;
  const executor1 = (await signedInClient("executor1")).client;
  const executor2 = (await signedInClient("executor2")).client;

  console.log("3/3 Объекты и задачи");
  const createObject = async (name: string, address: string) => {
    const { data, error } = await manager.from("objects").insert({ name, address }).select("id").single();
    if (error) throw error;
    return data.id;
  };
  const createTask = async (objectId: string, title: string, description: string, assignee: DemoUserKey) => {
    const { data, error } = await manager
      .from("tasks")
      .insert({ object_id: objectId, title, description, assignee_id: ids[assignee] })
      .select("id")
      .single();
    if (error) throw error;
    return data.id;
  };

  const north = await createObject("ЖК «Северный», корпус 2", "г. Казань, ул. Северная, 12");
  const office = await createObject("Офис на Лесной", "г. Казань, ул. Лесная, 5, этаж 3");
  const warehouse = await createObject("Склад в промзоне", "г. Казань, Промышленный проезд, 8");

  // Принята: полный путь без возвратов.
  const demolition = await createTask(
    north,
    "Демонтаж перегородок",
    "Квартиры 21–24, вывоз мусора",
    "executor1",
  );
  await walk(demolition, [
    { by: executor1, to: "in_progress" },
    { by: executor1, to: "review", comment: "Мусор вывезен, фото в чате" },
    { by: manager, to: "accepted" },
  ]);

  // На проверке.
  const plaster = await createTask(
    north,
    "Штукатурка стен, 3 этаж",
    "Машинная штукатурка, гипс",
    "executor1",
  );
  await walk(plaster, [
    { by: executor1, to: "in_progress" },
    { by: executor1, to: "review" },
  ]);

  // В работе.
  const wiring = await createTask(north, "Разводка кабеля", "Квартиры 21–24, по проекту ЭО-2", "executor2");
  await walk(wiring, [{ by: executor2, to: "in_progress", comment: "Кабель получен на складе" }]);

  // На доработке: постановщик вернул с причиной.
  const ceiling = await createTask(office, "Покраска потолков", "Переговорная и опенспейс", "executor2");
  await walk(ceiling, [
    { by: executor2, to: "in_progress" },
    { by: executor2, to: "review" },
    { by: manager, to: "rework", comment: "Разводы у окна в переговорной, нужен второй слой" },
  ]);

  // Новая, с правкой полей постановщиком — в истории будет событие «Изменена».
  const doors = await createTask(office, "Установка дверей", "6 дверей", "executor1");
  {
    const { error } = await manager
      .from("tasks")
      .update({ description: "6 межкомнатных дверей, фурнитура заказчика" })
      .eq("id", doors);
    if (error) throw error;
  }

  // Прошла возврат и снова в работе — показывает полный цикл в истории.
  const tiles = await createTask(warehouse, "Плитка в санузле", "Санузел персонала, 12 м²", "executor2");
  await walk(tiles, [
    { by: executor2, to: "in_progress" },
    { by: executor2, to: "review" },
    { by: manager, to: "rework", comment: "Не выдержан шов у раковины" },
    { by: executor2, to: "in_progress", comment: "Переделываю" },
  ]);

  // В архиве: создана по ошибке и убрана постановщиком.
  const measure = await createTask(warehouse, "Замер помещения", "Создана по ошибке", "executor1");
  {
    const { error } = await manager.rpc("archive_task", { p_task_id: measure });
    if (error) throw error;
  }

  const { data: summary, error: summaryError } = await admin
    .from("tasks")
    .select("title, status, archived_at")
    .order("id");
  if (summaryError) throw summaryError;
  for (const task of summary) {
    console.log(`    ${task.archived_at ? "архив" : task.status.padEnd(11)}  ${task.title}`);
  }
  console.log("Готово.");
}

main().catch((error: unknown) => {
  console.error("Заполнение остановлено:", error instanceof Error ? error.message : error);
  process.exit(1);
});
