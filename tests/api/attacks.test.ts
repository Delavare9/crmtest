// Атаки через REST API Supabase — то, что может сделать человек с публичным
// ключом из сборки фронтенда и своим логином, минуя интерфейс.
// Каждая попытка должна закончиться ошибкой или пустым ответом.
//
// Нужны: запущенный Supabase (локальный или облачный), выполненный
// npm run seed и переменные из .env.local (см. .env.example).
//
// Тест создаёт свой объект и задачи от имени постановщика, а в конце
// переносит их в архив, поэтому демо-данные не меняются.
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { DEMO_USERS, adminClient, publicClient, signedInClient, type Db } from "../../scripts/env";

let manager: Db;
let executor1: Db;
let executor2: Db;
let admin: Db;
let ids: { manager: string; executor1: string; executor2: string };

// Свои данные теста.
let objectId: string;
let taskOfExecutor1: string;
let taskOfExecutor2: string;
let raceTask: string;

async function createTask(title: string, assignee: string): Promise<string> {
  const { data, error } = await manager
    .from("tasks")
    .insert({ object_id: objectId, title, assignee_id: assignee })
    .select("id")
    .single();
  if (error) throw error;
  return data.id;
}

// Текущее состояние задачи глазами базы, а не атакующего.
async function statusOf(taskId: string) {
  const { data, error } = await admin.from("tasks").select("status").eq("id", taskId).single();
  if (error) throw error;
  return data.status;
}

beforeAll(async () => {
  admin = adminClient();
  const m = await signedInClient("manager");
  const e1 = await signedInClient("executor1");
  const e2 = await signedInClient("executor2");
  manager = m.client;
  executor1 = e1.client;
  executor2 = e2.client;
  ids = { manager: m.userId, executor1: e1.userId, executor2: e2.userId };

  const { data, error } = await manager
    .from("objects")
    .insert({ name: `Проверка доступа ${new Date().toISOString()}`, address: "тест" })
    .select("id")
    .single();
  if (error) throw error;
  objectId = data.id;

  taskOfExecutor1 = await createTask("Атаки: задача исполнителя 1", ids.executor1);
  taskOfExecutor2 = await createTask("Атаки: задача исполнителя 2", ids.executor2);
  raceTask = await createTask("Атаки: одновременные запросы", ids.executor1);
});

afterAll(async () => {
  // Уборка: задачи и объект в архив (удаления в системе нет).
  if (!manager || !objectId) return;
  for (const id of [taskOfExecutor1, taskOfExecutor2, raceTask]) {
    if (id) await manager.rpc("archive_task", { p_task_id: id });
  }
  await manager.rpc("archive_object", { p_object_id: objectId });
});

describe("чтение чужого", () => {
  it("исполнитель 1 запрашивает задачи исполнителя 2 — пустой список", async () => {
    const { data, error } = await executor1.from("tasks").select("id").eq("assignee_id", ids.executor2);
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("исполнитель 1 запрашивает чужую задачу по id — её нет", async () => {
    const { data, error } = await executor1.from("tasks").select("*").eq("id", taskOfExecutor2).maybeSingle();
    expect(error).toBeNull();
    expect(data).toBeNull();
  });

  it("исполнитель 1 не видит историю чужой задачи", async () => {
    const { data } = await executor1.from("task_history").select("id").eq("task_id", taskOfExecutor2);
    expect(data).toEqual([]);
  });

  it("исполнитель 1 не видит профиль исполнителя 2", async () => {
    const { data } = await executor1.from("profiles").select("id").eq("id", ids.executor2);
    expect(data).toEqual([]);
  });

  it("запрос без входа не возвращает данных", async () => {
    const anon = publicClient();
    const tasks = await anon.from("tasks").select("id");
    expect(tasks.error?.code).toBe("42501");
    const history = await anon.from("task_history").select("id");
    expect(history.error?.code).toBe("42501");
  });
});

describe("изменение в обход правил", () => {
  it("PATCH статуса напрямую отклоняется", async () => {
    const { error } = await executor1.from("tasks").update({ status: "accepted" }).eq("id", taskOfExecutor1);
    expect(error?.code).toBe("42501");
    expect(await statusOf(taskOfExecutor1)).toBe("new");
  });

  it("постановщик тоже не меняет статус напрямую", async () => {
    const { error } = await manager.from("tasks").update({ status: "accepted" }).eq("id", taskOfExecutor1);
    expect(error?.code).toBe("42501");
  });

  it("смена статуса чужой задачи через функцию — «задача не найдена»", async () => {
    const { error } = await executor1.rpc("change_task_status", {
      p_task_id: taskOfExecutor2,
      p_to: "in_progress",
    });
    expect(error?.code).toBe("P0002");
    expect(await statusOf(taskOfExecutor2)).toBe("new");
  });

  it("исполнитель сам принимает свою задачу — отказ", async () => {
    await executor1.rpc("change_task_status", { p_task_id: taskOfExecutor1, p_to: "in_progress" });
    await executor1.rpc("change_task_status", { p_task_id: taskOfExecutor1, p_to: "review" });
    const { error } = await executor1.rpc("change_task_status", {
      p_task_id: taskOfExecutor1,
      p_to: "accepted",
    });
    expect(error?.code).toBe("42501");
    expect(await statusOf(taskOfExecutor1)).toBe("review");
  });

  it("исполнитель меняет название своей задачи — ничего не меняется", async () => {
    const { data, error } = await executor1
      .from("tasks")
      .update({ title: "Переименовано исполнителем" })
      .eq("id", taskOfExecutor1)
      .select();
    // RLS не находит строк, доступных ему для изменения: ответ пустой, без ошибки.
    expect(error).toBeNull();
    expect(data).toEqual([]);
  });

  it("исполнитель создаёт себе задачу — отказ", async () => {
    const { error } = await executor1
      .from("tasks")
      .insert({ object_id: objectId, title: "Сам себе", assignee_id: ids.executor1 });
    expect(error?.code).toBe("42501");
  });

  it("постановщик подставляет чужого автора — отказ", async () => {
    const { error } = await manager
      .from("tasks")
      .insert({
        object_id: objectId,
        title: "Чужой автор",
        assignee_id: ids.executor1,
        author_id: ids.executor1,
      });
    expect(error?.code).toBe("42501");
  });

  it("возврат на доработку без комментария — отказ", async () => {
    const { error } = await manager.rpc("change_task_status", { p_task_id: taskOfExecutor1, p_to: "rework" });
    expect(error?.code).toBe("23514");
    expect(await statusOf(taskOfExecutor1)).toBe("review");
  });

  it("удаление задачи — отказ", async () => {
    const { error } = await manager.from("tasks").delete().eq("id", taskOfExecutor2);
    expect(error?.code).toBe("42501");
  });
});

describe("подделка истории и ролей", () => {
  it("вставка записи в историю — отказ", async () => {
    const { error } = await executor1.from("task_history").insert({
      task_id: taskOfExecutor1,
      actor_id: ids.manager,
      event: "status_changed",
      from_status: "review",
      to_status: "accepted",
    });
    expect(error?.code).toBe("42501");
  });

  it("удаление записи истории — отказ", async () => {
    const { error } = await executor1.from("task_history").delete().eq("task_id", taskOfExecutor1);
    expect(error?.code).toBe("42501");
  });

  it("служебный ключ тоже не удаляет историю", async () => {
    const { error } = await admin.from("task_history").delete().eq("task_id", taskOfExecutor1);
    expect(error?.code).toBe("42501");
  });

  it("смена своей роли на «постановщик» — отказ", async () => {
    const { error } = await executor1.from("profiles").update({ role: "manager" }).eq("id", ids.executor1);
    expect(error?.code).toBe("42501");
    const { data } = await admin.from("profiles").select("role").eq("id", ids.executor1).single();
    expect(data?.role).toBe("executor");
  });

  it("вызов служебной функции через REST — функции не существует для API", async () => {
    // private.role_of не входит в открытые схемы, PostgREST её не знает.
    const { error } = await (executor1.rpc as (fn: string, args: object) => ReturnType<Db["rpc"]>)(
      "role_of",
      {
        p_user_id: ids.executor2,
      },
    );
    expect(error?.code).toBe("PGRST202");
  });
});

describe("вход", () => {
  it("регистрация нового пользователя отклоняется", async () => {
    const { data, error } = await publicClient().auth.signUp({
      email: `intruder-${Date.now()}@example.com`,
      password: "Intruder-password-1",
    });
    expect(data.user).toBeNull();
    expect(error?.code).toBe("signup_disabled");
  });

  it("вход с неверным паролем отклоняется", async () => {
    const { error } = await publicClient().auth.signInWithPassword({
      email: DEMO_USERS.executor1.email,
      password: "wrong-password",
    });
    expect(error?.code).toBe("invalid_credentials");
  });
});

describe("одновременные действия", () => {
  it("два одновременных «Взять в работу» — проходит ровно один", async () => {
    const attempt = () => executor1.rpc("change_task_status", { p_task_id: raceTask, p_to: "in_progress" });
    const results = await Promise.all([attempt(), attempt(), attempt()]);

    const succeeded = results.filter((result) => result.error === null);
    const refused = results.filter((result) => result.error !== null);
    expect(succeeded).toHaveLength(1);
    // Остальные дождались блокировки строки и увидели уже «В работе».
    for (const result of refused) {
      expect(result.error?.code).toBe("42501");
      expect(result.error?.message).toContain("in_progress → in_progress");
    }

    const { data } = await admin
      .from("task_history")
      .select("id")
      .eq("task_id", raceTask)
      .eq("event", "status_changed");
    expect(data).toHaveLength(1);
  });

  it("исполнитель 2 не может взять задачу исполнителя 1 даже параллельно с ним", async () => {
    const { error } = await executor2.rpc("change_task_status", { p_task_id: raceTask, p_to: "review" });
    expect(error?.code).toBe("P0002");
  });
});
