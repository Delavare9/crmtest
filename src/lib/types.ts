// Короткие имена для строк таблиц. Сами типы генерируются из схемы базы
// (npm run db:types → database.types.ts), поэтому после миграции достаточно
// перегенерировать файл, и TypeScript покажет все места, которые надо поправить.
import type { Database } from "./database.types";

type Tables = Database["public"]["Tables"];

export type TaskStatus = Database["public"]["Enums"]["task_status"];
export type AppRole = Database["public"]["Enums"]["app_role"];

export type Profile = Tables["profiles"]["Row"];
export type CrmObject = Tables["objects"]["Row"];
export type Task = Tables["tasks"]["Row"];
export type Transition = Tables["task_transitions"]["Row"];
export type HistoryEntry = Tables["task_history"]["Row"];

// Кто сейчас вошёл: достаточно id и роли, чтобы решить, какие кнопки показать.
export type Me = Pick<Profile, "id" | "role" | "full_name">;

// Событие журнала. В базе это text с CHECK, поэтому перечисляем значения здесь.
export type HistoryEvent = "created" | "updated" | "status_changed" | "archived";

// Формат поля changes у события updated: {"title": {"old": "…", "new": "…"}}.
export type FieldChanges = Partial<
  Record<"title" | "description" | "assignee_id", { old: string | null; new: string | null }>
>;
