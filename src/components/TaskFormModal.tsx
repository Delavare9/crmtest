// Окно создания и правки задачи. Если передан task — правим (доступно
// постановщику в статусах «Новая» и «На доработке»), иначе создаём в объекте.
import { useState } from "react";
import { Button, Group, Modal, Select, Stack, TextInput, Textarea } from "@mantine/core";
import { useCreateTask, useProfiles, useUpdateTask } from "../lib/queries";
import type { Task } from "../lib/types";
import { notifyError, notifySuccess } from "./common";

export function TaskFormModal({
  opened,
  onClose,
  objectId,
  task,
}: {
  opened: boolean;
  onClose: () => void;
  objectId: string;
  task?: Task;
}) {
  const profiles = useProfiles();
  const create = useCreateTask();
  const update = useUpdateTask();
  const [title, setTitle] = useState(task?.title ?? "");
  const [description, setDescription] = useState(task?.description ?? "");
  const [assigneeId, setAssigneeId] = useState<string | null>(task?.assignee_id ?? null);
  const saving = create.isPending || update.isPending;

  // В списке только исполнители: назначить постановщика база не даст (решение 1).
  const executors = (profiles.data ?? [])
    .filter((profile) => profile.role === "executor")
    .map((profile) => ({ value: profile.id, label: profile.full_name }));

  const submit = async () => {
    if (!assigneeId) return;
    const fields = { title: title.trim(), description: description.trim(), assignee_id: assigneeId };
    try {
      if (task) {
        await update.mutateAsync({ id: task.id, ...fields });
        notifySuccess("Задача сохранена");
      } else {
        await create.mutateAsync({ object_id: objectId, ...fields });
        notifySuccess("Задача создана");
        setTitle("");
        setDescription("");
        setAssigneeId(null);
      }
      onClose();
    } catch (error) {
      notifyError(error);
    }
  };

  return (
    <Modal opened={opened} onClose={onClose} title={task ? "Изменить задачу" : "Новая задача"} size="lg">
      <form
        onSubmit={(event) => {
          event.preventDefault();
          void submit();
        }}
      >
        <Stack>
          <TextInput
            label="Название"
            required
            value={title}
            onChange={(event) => setTitle(event.currentTarget.value)}
            data-autofocus
          />
          <Textarea
            label="Описание"
            autosize
            minRows={3}
            value={description}
            onChange={(event) => setDescription(event.currentTarget.value)}
          />
          <Select
            label="Исполнитель"
            required
            searchable
            data={executors}
            value={assigneeId}
            onChange={setAssigneeId}
            placeholder={profiles.isPending ? "Загрузка…" : "Выберите исполнителя"}
            nothingFoundMessage="Нет исполнителей"
          />
          <Group justify="flex-end">
            <Button variant="default" onClick={onClose}>
              Отмена
            </Button>
            <Button type="submit" loading={saving} disabled={!title.trim() || !assigneeId}>
              Сохранить
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  );
}
