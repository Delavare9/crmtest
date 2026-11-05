// «Мои задачи» исполнителя с фильтром по статусу.
import { useState } from "react";
import { Group, SegmentedControl, Select, Title } from "@mantine/core";
import { useMediaQuery } from "@mantine/hooks";
import { QueryState } from "../components/common";
import { TasksTable } from "../components/TasksTable";
import { useMe } from "../lib/auth";
import { STATUS_LABEL, STATUS_ORDER } from "../lib/labels";
import { useMyTasks } from "../lib/queries";
import type { TaskStatus } from "../lib/types";

// "all" — служебное значение фильтра «все статусы», в базу не уходит.
const FILTER_OPTIONS = [
  { value: "all", label: "Все" },
  ...STATUS_ORDER.map((status) => ({ value: status, label: STATUS_LABEL[status] })),
];

export function MyTasksPage() {
  const me = useMe();
  const [filter, setFilter] = useState("all");
  const tasks = useMyTasks(me.id, filter === "all" ? null : (filter as TaskStatus));
  // На узком экране шесть кнопок фильтра не помещаются — показываем список.
  const narrow = useMediaQuery("(max-width: 48em)");

  return (
    <>
      <Group justify="space-between" mb="md">
        <Title order={2}>Мои задачи</Title>
      </Group>
      {narrow ? (
        <Select
          label="Статус"
          data={FILTER_OPTIONS}
          value={filter}
          onChange={(value) => setFilter(value ?? "all")}
          allowDeselect={false}
          mb="md"
        />
      ) : (
        <SegmentedControl data={FILTER_OPTIONS} value={filter} onChange={setFilter} mb="md" fullWidth />
      )}
      <QueryState isPending={tasks.isPending} error={tasks.error}>
        {() => <TasksTable tasks={tasks.data!} showObject showAssignee={false} />}
      </QueryState>
    </>
  );
}
