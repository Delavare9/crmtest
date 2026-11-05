// Мелкие общие элементы экранов: бейдж статуса, состояние загрузки/ошибки,
// уведомления об успехе и ошибке.
import type { ReactNode } from "react";
import { Alert, Badge, Center, Loader } from "@mantine/core";
import { notifications } from "@mantine/notifications";
import { toUserMessage } from "../lib/errors";
import { STATUS_COLOR, STATUS_LABEL } from "../lib/labels";
import type { TaskStatus } from "../lib/types";

export function StatusBadge({ status }: { status: TaskStatus }) {
  return (
    <Badge color={STATUS_COLOR[status]} variant="light">
      {STATUS_LABEL[status]}
    </Badge>
  );
}

export function ArchivedBadge() {
  return (
    <Badge color="dark" variant="outline">
      В архиве
    </Badge>
  );
}

// Общая обёртка для данных из useQuery: пока грузится — крутилка, при ошибке —
// понятный текст, иначе — содержимое. Так каждый экран не повторяет эти ветки.
export function QueryState({
  isPending,
  error,
  children,
}: {
  isPending: boolean;
  error: unknown;
  children: () => ReactNode;
}) {
  if (isPending) {
    return (
      <Center py="xl">
        <Loader />
      </Center>
    );
  }
  if (error) {
    return (
      <Alert color="red" title="Не удалось загрузить данные">
        {toUserMessage(error as { code?: string; message?: string })}
      </Alert>
    );
  }
  return <>{children()}</>;
}

export function notifyError(error: unknown) {
  notifications.show({
    color: "red",
    title: "Действие не выполнено",
    message: toUserMessage(error as { code?: string; message?: string }),
  });
}

export function notifySuccess(message: string) {
  notifications.show({ color: "green", message });
}
