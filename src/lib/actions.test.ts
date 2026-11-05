// Логика кнопок: для каждой пары «роль × статус» интерфейс предлагает ровно
// те переходы, которые разрешит база. Правила ниже — копия строк из миграции
// 20261105150100_schema.sql; если миграция меняется, меняется и этот список.
import { describe, expect, it } from "vitest";
import { availableActions, canArchiveTask, canEditTask } from "./actions";
import { toUserMessage } from "./errors";
import { transitionLabel } from "./labels";
import type { AppRole, TaskStatus, Transition } from "./types";

const RULES: Transition[] = [
  { from_status: "new", to_status: "in_progress", actor_role: "executor", requires_comment: false },
  { from_status: "in_progress", to_status: "review", actor_role: "executor", requires_comment: false },
  { from_status: "review", to_status: "accepted", actor_role: "manager", requires_comment: false },
  { from_status: "review", to_status: "rework", actor_role: "manager", requires_comment: true },
  { from_status: "rework", to_status: "in_progress", actor_role: "executor", requires_comment: false },
];

const EXECUTOR = { id: "executor-1", role: "executor" as const };
const OTHER_EXECUTOR = { id: "executor-2", role: "executor" as const };
const MANAGER = { id: "manager-1", role: "manager" as const };

const task = (status: TaskStatus, archived = false) => ({
  status,
  assignee_id: EXECUTOR.id,
  archived_at: archived ? "2026-11-05T12:00:00Z" : null,
});

const targets = (status: TaskStatus, me: { id: string; role: AppRole }, archived = false) =>
  availableActions(task(status, archived), me, RULES).map((rule) => rule.to_status);

describe("availableActions — ровно разрешённые переходы", () => {
  // Ожидания выписаны вручную, а не вычислены из RULES: иначе тест повторял бы код.
  const expected: Record<AppRole, Record<TaskStatus, TaskStatus[]>> = {
    executor: {
      new: ["in_progress"],
      in_progress: ["review"],
      review: [],
      accepted: [],
      rework: ["in_progress"],
    },
    manager: {
      new: [],
      in_progress: [],
      review: ["accepted", "rework"],
      accepted: [],
      rework: [],
    },
  };

  for (const [role, byStatus] of Object.entries(expected) as [AppRole, Record<TaskStatus, TaskStatus[]>][]) {
    const me = role === "manager" ? MANAGER : EXECUTOR;
    for (const [status, allowed] of Object.entries(byStatus) as [TaskStatus, TaskStatus[]][]) {
      it(`${role} в статусе ${status}: ${allowed.join(", ") || "ничего"}`, () => {
        expect(targets(status, me).sort()).toEqual([...allowed].sort());
      });
    }
  }

  it("чужая задача для исполнителя — без действий в любом статусе", () => {
    for (const status of ["new", "in_progress", "review", "accepted", "rework"] as TaskStatus[]) {
      expect(targets(status, OTHER_EXECUTOR)).toEqual([]);
    }
  });

  it("архивная задача — без действий у обеих ролей", () => {
    for (const status of ["new", "in_progress", "review", "rework"] as TaskStatus[]) {
      expect(targets(status, EXECUTOR, true)).toEqual([]);
      expect(targets(status, MANAGER, true)).toEqual([]);
    }
  });

  it("возврат на доработку помечен как требующий комментарий", () => {
    const rework = availableActions(task("review"), MANAGER, RULES).find((r) => r.to_status === "rework");
    expect(rework?.requires_comment).toBe(true);
  });
});

describe("canEditTask и canArchiveTask", () => {
  it("постановщик правит только в «Новая» и «На доработке»", () => {
    const editable = (["new", "in_progress", "review", "accepted", "rework"] as TaskStatus[]).filter((s) =>
      canEditTask(task(s), MANAGER),
    );
    expect(editable).toEqual(["new", "rework"]);
  });

  it("исполнитель не правит никогда", () => {
    expect(canEditTask(task("new"), EXECUTOR)).toBe(false);
  });

  it("архивная задача не правится и не архивируется повторно", () => {
    expect(canEditTask(task("new", true), MANAGER)).toBe(false);
    expect(canArchiveTask(task("new", true), MANAGER)).toBe(false);
  });

  it("архивировать может только постановщик", () => {
    expect(canArchiveTask(task("accepted"), MANAGER)).toBe(true);
    expect(canArchiveTask(task("accepted"), EXECUTOR)).toBe(false);
  });
});

describe("подписи и ошибки", () => {
  it("подпись перехода зависит от исходного статуса", () => {
    expect(transitionLabel("new", "in_progress")).toBe("Взять в работу");
    expect(transitionLabel("rework", "in_progress")).toBe("Снова в работу");
  });

  it("свои русские сообщения базы показываются как есть", () => {
    expect(toUserMessage({ code: "23514", message: "Для этого перехода нужен комментарий" })).toBe(
      "Для этого перехода нужен комментарий",
    );
  });

  it("английские системные ошибки заменяются текстом по коду", () => {
    expect(toUserMessage({ code: "42501", message: "permission denied for table tasks" })).toBe(
      "Нет прав на это действие",
    );
  });
});
