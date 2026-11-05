// Какие действия показать пользователю на карточке задачи.
//
// Это только подсказка интерфейсу: правила проверяет база (функция
// change_task_status и триггер). Кнопки строятся по той же таблице
// task_transitions, по которой проверяет база, поэтому интерфейс и база
// не расходятся: новый переход появляется в интерфейсе без правки кода.
import type { Me, Task, Transition } from "./types";

// Переходы, которые пользователь может выполнить с задачей прямо сейчас.
// Пусто, если задача в архиве или (для исполнителя) назначена не ему —
// совпадает с тем, что база ответила бы «задача не найдена».
export function availableActions(
  task: Pick<Task, "status" | "assignee_id" | "archived_at">,
  me: Pick<Me, "id" | "role">,
  rules: Transition[],
): Transition[] {
  if (task.archived_at) return [];
  if (me.role === "executor" && task.assignee_id !== me.id) return [];
  return rules.filter((rule) => rule.from_status === task.status && rule.actor_role === me.role);
}

// Статусы, в которых постановщик может править название, описание
// и исполнителя (решение 2). Дублирует проверку триггера tasks_before_update.
const EDITABLE_STATUSES = new Set<Task["status"]>(["new", "rework"]);

export function canEditTask(task: Pick<Task, "status" | "archived_at">, me: Pick<Me, "role">): boolean {
  return me.role === "manager" && !task.archived_at && EDITABLE_STATUSES.has(task.status);
}

// Архивировать задачу может постановщик, пока она не в архиве.
export function canArchiveTask(task: Pick<Task, "archived_at">, me: Pick<Me, "role">): boolean {
  return me.role === "manager" && !task.archived_at;
}
