// Все подписи интерфейса для значений из базы — в одном месте. В базе хранятся
// английские коды (new, in_progress…), пользователю показываем русский текст.
import type { AppRole, HistoryEvent, TaskStatus } from "./types";

export const STATUS_LABEL: Record<TaskStatus, string> = {
  new: "Новая",
  in_progress: "В работе",
  review: "На проверке",
  accepted: "Принята",
  rework: "На доработке",
};

// Цвета Mantine для бейджа статуса: серый — ещё не начата, синий — идёт работа,
// жёлтый — ждёт проверки, зелёный — принята, красный — вернули.
export const STATUS_COLOR: Record<TaskStatus, string> = {
  new: "gray",
  in_progress: "blue",
  review: "yellow",
  accepted: "green",
  rework: "red",
};

// Порядок статусов в фильтрах — по жизненному циклу, а не по алфавиту.
export const STATUS_ORDER: TaskStatus[] = ["new", "in_progress", "review", "rework", "accepted"];

export const ROLE_LABEL: Record<AppRole, string> = {
  manager: "Постановщик",
  executor: "Исполнитель",
};

export const EVENT_LABEL: Record<HistoryEvent, string> = {
  created: "Создана",
  updated: "Изменена",
  status_changed: "Смена статуса",
  archived: "Перенесена в архив",
};

export const FIELD_LABEL: Record<string, string> = {
  title: "Название",
  description: "Описание",
  assignee_id: "Исполнитель",
};

// Подпись кнопки перехода. Один и тот же целевой статус может называться
// по-разному в зависимости от исходного: «Взять в работу» из «Новая»,
// но «Снова в работу» из «На доработке».
export function transitionLabel(from: TaskStatus, to: TaskStatus): string {
  if (to === "in_progress") return from === "rework" ? "Снова в работу" : "Взять в работу";
  if (to === "review") return "Сдать на проверку";
  if (to === "accepted") return "Принять";
  if (to === "rework") return "Вернуть на доработку";
  // Новый переход, добавленный миграцией, получит подпись без правки этого файла.
  return `Перевести: ${STATUS_LABEL[to]}`;
}

// Дата и время по-русски, в часовом поясе браузера.
const dateTime = new Intl.DateTimeFormat("ru-RU", { dateStyle: "short", timeStyle: "short" });

export function formatDateTime(value: string): string {
  return dateTime.format(new Date(value));
}
