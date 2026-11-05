// Карточка объекта: название, адрес и задачи. Постановщик правит объект,
// создаёт задачи и архивирует объект, когда в нём не осталось незавершённых задач.
import { useState } from "react";
import { Anchor, Button, Group, Paper, Stack, Switch, Text, Title } from "@mantine/core";
import { Link, useParams } from "react-router";
import { ArchivedBadge, QueryState, notifyError, notifySuccess } from "../components/common";
import { ObjectFormModal } from "../components/ObjectFormModal";
import { TaskFormModal } from "../components/TaskFormModal";
import { TasksTable } from "../components/TasksTable";
import { useMe } from "../lib/auth";
import { formatDateTime } from "../lib/labels";
import { useArchiveObject, useObject, useObjectTasks } from "../lib/queries";

export function ObjectPage() {
  const { objectId = "" } = useParams();
  const me = useMe();
  const isManager = me.role === "manager";
  const [showArchived, setShowArchived] = useState(false);
  const [editing, setEditing] = useState(false);
  const [creatingTask, setCreatingTask] = useState(false);
  const object = useObject(objectId);
  const tasks = useObjectTasks(objectId, isManager && showArchived);
  const archive = useArchiveObject();

  const archiveObject = async () => {
    // Подтверждение браузера: действие необратимо через интерфейс.
    if (!window.confirm("Перенести объект в архив? Вернуть его можно будет только через администратора."))
      return;
    try {
      await archive.mutateAsync(objectId);
      notifySuccess("Объект перенесён в архив");
    } catch (error) {
      // Например: «В объекте есть незавершённые задачи» — текст пришёл из базы.
      notifyError(error);
    }
  };

  return (
    <QueryState isPending={object.isPending} error={object.error}>
      {() => {
        const data = object.data;
        // null — объекта нет или он не виден этому пользователю; для исполнителя
        // эти случаи неотличимы, и это правильно.
        if (!data) {
          return (
            <Stack>
              <Text>Объект не найден.</Text>
              <Anchor component={Link} to="/objects">
                К списку объектов
              </Anchor>
            </Stack>
          );
        }
        const archived = Boolean(data.archived_at);

        return (
          <Stack>
            <Anchor component={Link} to="/objects" size="sm">
              ← Объекты
            </Anchor>

            <Paper withBorder p="md">
              <Group justify="space-between" align="flex-start">
                <Stack gap={4}>
                  <Group gap="xs">
                    <Title order={2}>{data.name}</Title>
                    {archived && <ArchivedBadge />}
                  </Group>
                  <Text c="dimmed">{data.address || "Адрес не указан"}</Text>
                  <Text size="xs" c="dimmed">
                    Создан {formatDateTime(data.created_at)}
                    {data.archived_at && ` · в архиве с ${formatDateTime(data.archived_at)}`}
                  </Text>
                </Stack>
                {isManager && !archived && (
                  <Group>
                    <Button variant="default" onClick={() => setEditing(true)}>
                      Изменить
                    </Button>
                    <Button
                      variant="light"
                      color="red"
                      loading={archive.isPending}
                      onClick={() => void archiveObject()}
                    >
                      В архив
                    </Button>
                  </Group>
                )}
              </Group>
            </Paper>

            <Group justify="space-between">
              <Title order={3}>Задачи</Title>
              {isManager && (
                <Group>
                  <Switch
                    label="Показать архивные"
                    checked={showArchived}
                    onChange={(event) => setShowArchived(event.currentTarget.checked)}
                  />
                  {!archived && <Button onClick={() => setCreatingTask(true)}>Новая задача</Button>}
                </Group>
              )}
            </Group>

            <QueryState isPending={tasks.isPending} error={tasks.error}>
              {() => <TasksTable tasks={tasks.data!} showObject={false} />}
            </QueryState>

            {isManager && !archived && (
              <>
                {/* key заставляет форму пересоздаться с актуальными значениями после сохранения. */}
                <ObjectFormModal
                  key={`${data.id}-${data.name}-${data.address}`}
                  opened={editing}
                  onClose={() => setEditing(false)}
                  object={data}
                />
                <TaskFormModal
                  opened={creatingTask}
                  onClose={() => setCreatingTask(false)}
                  objectId={data.id}
                />
              </>
            )}
          </Stack>
        );
      }}
    </QueryState>
  );
}
