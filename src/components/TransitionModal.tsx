// Подтверждение смены статуса с комментарием.
//
// Комментарий можно оставить при любом переходе (он попадёт в историю),
// а обязателен он только там, где так сказано в task_transitions —
// сейчас это возврат на доработку (решение 9). Пока обязательный комментарий
// пуст, кнопка неактивна; если обойти интерфейс, откажет база.
import { useState } from "react";
import { Button, Group, Modal, Stack, Text, Textarea } from "@mantine/core";
import { STATUS_LABEL, transitionLabel } from "../lib/labels";
import { useChangeStatus } from "../lib/queries";
import type { Transition } from "../lib/types";
import { notifyError, notifySuccess } from "./common";

export function TransitionModal({
  taskId,
  transition,
  onClose,
}: {
  taskId: string;
  transition: Transition | null;
  onClose: () => void;
}) {
  const change = useChangeStatus();
  const [comment, setComment] = useState("");
  const commentMissing = Boolean(transition?.requires_comment) && !comment.trim();

  const close = () => {
    setComment("");
    onClose();
  };

  const submit = async () => {
    if (!transition) return;
    try {
      await change.mutateAsync({ taskId, to: transition.to_status, comment });
      notifySuccess(`Статус: ${STATUS_LABEL[transition.to_status]}`);
      close();
    } catch (error) {
      notifyError(error);
    }
  };

  return (
    <Modal
      opened={transition !== null}
      onClose={close}
      title={transition ? transitionLabel(transition.from_status, transition.to_status) : ""}
    >
      {transition && (
        <Stack>
          <Text size="sm">
            {STATUS_LABEL[transition.from_status]} → {STATUS_LABEL[transition.to_status]}
          </Text>
          <Textarea
            label={transition.requires_comment ? "Комментарий (обязательно)" : "Комментарий (необязательно)"}
            description={transition.requires_comment ? "Что нужно исправить — увидит исполнитель" : undefined}
            required={transition.requires_comment}
            autosize
            minRows={3}
            maxLength={2000}
            value={comment}
            onChange={(event) => setComment(event.currentTarget.value)}
            data-autofocus
          />
          <Group justify="flex-end">
            <Button variant="default" onClick={close}>
              Отмена
            </Button>
            <Button onClick={() => void submit()} loading={change.isPending} disabled={commentMissing}>
              Подтвердить
            </Button>
          </Group>
        </Stack>
      )}
    </Modal>
  );
}
