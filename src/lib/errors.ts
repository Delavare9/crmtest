// Перевод ошибок базы и Auth в понятный пользователю текст.
//
// Наши функции и триггеры отдают русские сообщения — их показываем как есть.
// Встроенные ошибки PostgreSQL и PostgREST приходят на английском
// («permission denied for table tasks») — вместо них показываем общий текст
// по коду ошибки.

type ErrorLike = { code?: string; message?: string } | null | undefined;

const BY_CODE: Record<string, string> = {
  "42501": "Нет прав на это действие",
  P0002: "Задача не найдена",
  "55000": "Действие недоступно в текущем состоянии",
  "23514": "Данные не прошли проверку",
  "23503": "Связанная запись не найдена",
  "23502": "Не заполнено обязательное поле",
  invalid_credentials: "Неверный email или пароль",
  signup_disabled: "Регистрация отключена: доступ выдаёт администратор",
  // PostgREST: функция или таблица не найдена в открытой схеме.
  PGRST202: "Действие недоступно",
  PGRST116: "Запись не найдена",
};

// Кириллица в тексте ошибки означает, что сообщение написали мы в базе,
// а значит, оно уже сформулировано для пользователя.
const OWN_MESSAGE = /[А-Яа-яЁё]/;

export function toUserMessage(error: ErrorLike): string {
  if (!error) return "Неизвестная ошибка";
  if (error.message && OWN_MESSAGE.test(error.message)) return error.message;
  if (error.code && BY_CODE[error.code]) return BY_CODE[error.code]!;
  // Сеть недоступна или Supabase не отвечает — fetch бросает TypeError.
  if (error.message?.includes("Failed to fetch")) return "Нет связи с сервером";
  return error.message || "Неизвестная ошибка";
}
