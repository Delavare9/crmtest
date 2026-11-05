// Список объектов. Постановщик видит все и может создать новый; исполнитель —
// только объекты, где у него есть активные задачи (это решает RLS, не экран).
import { useState } from "react";
import { Button, Group, Switch, Table, Text, Title } from "@mantine/core";
import { useNavigate } from "react-router";
import { ArchivedBadge, QueryState } from "../components/common";
import { ObjectFormModal } from "../components/ObjectFormModal";
import { useMe } from "../lib/auth";
import { formatDateTime } from "../lib/labels";
import { useObjects } from "../lib/queries";

export function ObjectsPage() {
  const me = useMe();
  const navigate = useNavigate();
  const [showArchived, setShowArchived] = useState(false);
  const [creating, setCreating] = useState(false);
  const isManager = me.role === "manager";
  // Исполнителю архивные объекты база всё равно не отдаст, если в них нет его
  // активных задач; переключатель показываем только постановщику.
  const objects = useObjects(isManager && showArchived);

  return (
    <>
      <Group justify="space-between" mb="md">
        <Title order={2}>Объекты</Title>
        {isManager && (
          <Group>
            <Switch
              label="Показать архив"
              checked={showArchived}
              onChange={(event) => setShowArchived(event.currentTarget.checked)}
            />
            <Button onClick={() => setCreating(true)}>Новый объект</Button>
          </Group>
        )}
      </Group>

      <QueryState isPending={objects.isPending} error={objects.error}>
        {() =>
          objects.data!.length === 0 ? (
            <Text c="dimmed">{isManager ? "Объектов пока нет" : "Вам пока не назначено задач"}</Text>
          ) : (
            <Table.ScrollContainer minWidth={500}>
              <Table highlightOnHover verticalSpacing="sm">
                <Table.Thead>
                  <Table.Tr>
                    <Table.Th>Название</Table.Th>
                    <Table.Th>Адрес</Table.Th>
                    <Table.Th>Создан</Table.Th>
                  </Table.Tr>
                </Table.Thead>
                <Table.Tbody>
                  {objects.data!.map((object) => (
                    <Table.Tr
                      key={object.id}
                      style={{ cursor: "pointer" }}
                      onClick={() => navigate(`/objects/${object.id}`)}
                    >
                      <Table.Td>
                        <Group gap="xs">
                          {object.name}
                          {object.archived_at && <ArchivedBadge />}
                        </Group>
                      </Table.Td>
                      <Table.Td>{object.address || "—"}</Table.Td>
                      <Table.Td>{formatDateTime(object.created_at)}</Table.Td>
                    </Table.Tr>
                  ))}
                </Table.Tbody>
              </Table>
            </Table.ScrollContainer>
          )
        }
      </QueryState>

      {isManager && <ObjectFormModal opened={creating} onClose={() => setCreating(false)} />}
    </>
  );
}
