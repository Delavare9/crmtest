// Таблица задач для карточки объекта и экрана «Мои задачи».
// Строка кликабельна целиком — переход в карточку задачи.
import { Table, Text } from "@mantine/core";
import { useNavigate } from "react-router";
import { formatDateTime } from "../lib/labels";
import type { TaskListItem } from "../lib/queries";
import { ArchivedBadge, StatusBadge } from "./common";

// showObject — колонка объекта (нужна в «Моих задачах», где задачи из разных объектов);
// showAssignee — колонка исполнителя (не нужна исполнителю в его же списке).
export function TasksTable({
  tasks,
  showObject,
  showAssignee = true,
}: {
  tasks: TaskListItem[];
  showObject: boolean;
  showAssignee?: boolean;
}) {
  const navigate = useNavigate();

  if (tasks.length === 0) {
    return (
      <Text c="dimmed" py="md">
        Задач нет
      </Text>
    );
  }

  return (
    <Table.ScrollContainer minWidth={showAssignee ? 600 : 480}>
      <Table highlightOnHover verticalSpacing="sm">
        <Table.Thead>
          <Table.Tr>
            <Table.Th>Задача</Table.Th>
            {showObject && <Table.Th>Объект</Table.Th>}
            {showAssignee && <Table.Th>Исполнитель</Table.Th>}
            <Table.Th>Статус</Table.Th>
            <Table.Th>Обновлена</Table.Th>
          </Table.Tr>
        </Table.Thead>
        <Table.Tbody>
          {tasks.map((task) => (
            <Table.Tr
              key={task.id}
              style={{ cursor: "pointer" }}
              onClick={() => navigate(`/tasks/${task.id}`)}
            >
              <Table.Td>{task.title}</Table.Td>
              {showObject && <Table.Td>{task.object?.name ?? "—"}</Table.Td>}
              {showAssignee && <Table.Td>{task.assignee?.full_name ?? "—"}</Table.Td>}
              <Table.Td>
                {task.archived_at ? <ArchivedBadge /> : <StatusBadge status={task.status} />}
              </Table.Td>
              <Table.Td>{formatDateTime(task.updated_at)}</Table.Td>
            </Table.Tr>
          ))}
        </Table.Tbody>
      </Table>
    </Table.ScrollContainer>
  );
}
