// Журнал событий задачи: кто, когда и что сделал. Только показ — записи
// пишет база, изменить их нельзя никому.
import { Stack, Text, Timeline } from "@mantine/core";
import { EVENT_LABEL, FIELD_LABEL, STATUS_LABEL, formatDateTime } from "../lib/labels";
import type { FieldChanges, HistoryEntry, HistoryEvent, Profile } from "../lib/types";

// Имя по id. Исполнитель видит только себя и постановщиков (решение 7),
// поэтому чужое имя может быть недоступно — тогда пишем нейтрально.
function nameOf(profiles: Map<string, Profile>, id: string | null | undefined): string {
  if (!id) return "—";
  return profiles.get(id)?.full_name ?? "Другой пользователь";
}

function ChangesList({ changes, profiles }: { changes: FieldChanges; profiles: Map<string, Profile> }) {
  return (
    <Stack gap={2}>
      {Object.entries(changes).map(([field, change]) => {
        if (!change) return null;
        // Для исполнителя в истории хранится id — показываем имя.
        const show = (value: string | null) =>
          field === "assignee_id" ? nameOf(profiles, value) : value || "(пусто)";
        return (
          <Text key={field} size="sm">
            {FIELD_LABEL[field] ?? field}: «{show(change.old)}» → «{show(change.new)}»
          </Text>
        );
      })}
    </Stack>
  );
}

export function TaskHistory({ entries, profiles }: { entries: HistoryEntry[]; profiles: Profile[] }) {
  const byId = new Map(profiles.map((profile) => [profile.id, profile]));

  return (
    <Timeline active={entries.length - 1} bulletSize={14} lineWidth={2}>
      {entries.map((entry) => {
        const event = entry.event as HistoryEvent;
        // Создание показываем как переход «— → Новая», как договорились в решениях.
        const statusLine =
          event === "created"
            ? `— → ${STATUS_LABEL[entry.to_status!]}`
            : event === "status_changed" && entry.from_status && entry.to_status
              ? `${STATUS_LABEL[entry.from_status]} → ${STATUS_LABEL[entry.to_status]}`
              : null;

        return (
          <Timeline.Item key={entry.id} title={EVENT_LABEL[event] ?? entry.event}>
            <Text size="xs" c="dimmed">
              {formatDateTime(entry.created_at)} · {nameOf(byId, entry.actor_id)}
            </Text>
            {statusLine && <Text size="sm">{statusLine}</Text>}
            {entry.comment && (
              <Text size="sm" fs="italic">
                «{entry.comment}»
              </Text>
            )}
            {event === "updated" && entry.changes && (
              <ChangesList changes={entry.changes as FieldChanges} profiles={byId} />
            )}
          </Timeline.Item>
        );
      })}
    </Timeline>
  );
}
