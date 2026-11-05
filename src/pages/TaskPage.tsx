// Карточка задачи: поля, доступные действия и журнал событий.
//
// Кнопки переходов строятся функцией availableActions по таблице
// task_transitions — той же, по которой проверяет база.
import { useState } from "react";
import { Anchor, Button, Grid, Group, Paper, Stack, Text, Title } from "@mantine/core";
import { Link, useParams } from "react-router";
import { ArchivedBadge, QueryState, StatusBadge, notifyError, notifySuccess } from "../components/common";
import { TaskFormModal } from "../components/TaskFormModal";
import { TaskHistory } from "../components/TaskHistory";
import { TransitionModal } from "../components/TransitionModal";
import { availableActions, canArchiveTask, canEditTask } from "../lib/actions";
import { useMe } from "../lib/auth";
import { formatDateTime, transitionLabel } from "../lib/labels";
import { useArchiveTask, useProfiles, useTask, useTaskHistory, useTransitions } from "../lib/queries";
import type { Transition } from "../lib/types";

export function TaskPage() {
  const { taskId = "" } = useParams();
  const me = useMe();
  const task = useTask(taskId);
  const history = useTaskHistory(taskId);
  const transitions = useTransitions();
  const profiles = useProfiles();
  const archive = useArchiveTask();
  const [editing, setEditing] = useState(false);
  const [transition, setTransition] = useState<Transition | null>(null);

  const archiveTask = async () => {
    if (!window.confirm("Перенести задачу в архив? История сохранится.")) return;
    try {
      await archive.mutateAsync(taskId);
      notifySuccess("Задача перенесена в архив");
    } catch (error) {
      notifyError(error);
    }
  };

  return (
    <QueryState isPending={task.isPending} error={task.error}>
      {() => {
        const data = task.data;
        if (!data) {
          return (
            <Stack>
              <Text>Задача не найдена.</Text>
              <Anchor component={Link} to="/objects">
                К списку объектов
              </Anchor>
            </Stack>
          );
        }

        const actions = availableActions(data, me, transitions.data ?? []);
        const authorName = profiles.data?.find((profile) => profile.id === data.author_id)?.full_name ?? "—";

        return (
          <Stack>
            <Anchor component={Link} to={`/objects/${data.object_id}`} size="sm">
              ← {data.object?.name ?? "Объект"}
            </Anchor>

            <Paper withBorder p="md">
              <Stack>
                <Group justify="space-between" align="flex-start">
                  <Group gap="xs">
                    <Title order={2}>{data.title}</Title>
                    {data.archived_at ? <ArchivedBadge /> : <StatusBadge status={data.status} />}
                  </Group>
                  <Group>
                    {canEditTask(data, me) && (
                      <Button variant="default" onClick={() => setEditing(true)}>
                        Изменить
                      </Button>
                    )}
                    {canArchiveTask(data, me) && (
                      <Button
                        variant="light"
                        color="red"
                        loading={archive.isPending}
                        onClick={() => void archiveTask()}
                      >
                        В архив
                      </Button>
                    )}
                  </Group>
                </Group>

                <Text style={{ whiteSpace: "pre-wrap" }}>{data.description || "Без описания"}</Text>

                <Grid>
                  <Grid.Col span={{ base: 12, sm: 4 }}>
                    <Text size="xs" c="dimmed">
                      Исполнитель
                    </Text>
                    <Text>{data.assignee?.full_name ?? "—"}</Text>
                  </Grid.Col>
                  <Grid.Col span={{ base: 12, sm: 4 }}>
                    <Text size="xs" c="dimmed">
                      Постановщик
                    </Text>
                    <Text>{authorName}</Text>
                  </Grid.Col>
                  <Grid.Col span={{ base: 12, sm: 4 }}>
                    <Text size="xs" c="dimmed">
                      Создана / обновлена
                    </Text>
                    <Text>
                      {formatDateTime(data.created_at)} / {formatDateTime(data.updated_at)}
                    </Text>
                  </Grid.Col>
                </Grid>

                {actions.length > 0 && (
                  <Group>
                    {actions.map((action) => (
                      <Button
                        key={`${action.from_status}-${action.to_status}`}
                        // Возврат на доработку — «отрицательное» действие, выделяем цветом.
                        color={action.to_status === "rework" ? "red" : undefined}
                        variant={action.to_status === "rework" ? "light" : "filled"}
                        onClick={() => setTransition(action)}
                      >
                        {transitionLabel(action.from_status, action.to_status)}
                      </Button>
                    ))}
                  </Group>
                )}
              </Stack>
            </Paper>

            <Title order={3}>История</Title>
            <QueryState isPending={history.isPending} error={history.error}>
              {() => <TaskHistory entries={history.data!} profiles={profiles.data ?? []} />}
            </QueryState>

            <TransitionModal taskId={data.id} transition={transition} onClose={() => setTransition(null)} />
            {canEditTask(data, me) && (
              <TaskFormModal
                key={data.updated_at}
                opened={editing}
                onClose={() => setEditing(false)}
                objectId={data.object_id}
                task={data}
              />
            )}
          </Stack>
        );
      }}
    </QueryState>
  );
}
