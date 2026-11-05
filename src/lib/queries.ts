// Запросы к базе и действия, обёрнутые в TanStack Query.
//
// Ни один запрос не фильтрует данные «по правам» сам: что вернуть, решает RLS.
// Например, useObjectTasks у исполнителя вернёт только его задачи объекта,
// хотя запрос один и тот же для обеих ролей.
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { supabase } from "./supabase";
import type { CrmObject, HistoryEntry, Profile, Task, TaskStatus, Transition } from "./types";

// Ошибку supabase-js превращаем в исключение, чтобы TanStack Query
// перевёл запрос в состояние error и показал её на экране.
function unwrap<T>(result: { data: T | null; error: unknown }): T {
  if (result.error) throw result.error;
  return result.data as T;
}

// ---------------------------------------------------------------------------
// Чтение
// ---------------------------------------------------------------------------

// Задача вместе с названием объекта и именем исполнителя — для списков.
export type TaskListItem = Task & {
  object: Pick<CrmObject, "id" | "name"> | null;
  assignee: Pick<Profile, "id" | "full_name"> | null;
};

const TASK_LIST_SELECT =
  "*, object:objects!tasks_object_id_fkey(id, name), assignee:profiles!tasks_assignee_id_fkey(id, full_name)";

export function useObjects(includeArchived: boolean) {
  return useQuery({
    queryKey: ["objects", { includeArchived }],
    queryFn: async () => {
      let query = supabase.from("objects").select("*").order("id", { ascending: false });
      if (!includeArchived) query = query.is("archived_at", null);
      // UUID v7 растёт со временем, поэтому сортировка по id — это «сначала новые».
      return unwrap<CrmObject[]>(await query);
    },
  });
}

export function useObject(objectId: string) {
  return useQuery({
    queryKey: ["object", objectId],
    queryFn: async () =>
      unwrap<CrmObject | null>(await supabase.from("objects").select("*").eq("id", objectId).maybeSingle()),
  });
}

export function useObjectTasks(objectId: string, includeArchived: boolean) {
  return useQuery({
    queryKey: ["object-tasks", objectId, { includeArchived }],
    queryFn: async () => {
      let query = supabase
        .from("tasks")
        .select(TASK_LIST_SELECT)
        .eq("object_id", objectId)
        .order("id", { ascending: false });
      if (!includeArchived) query = query.is("archived_at", null);
      return unwrap<TaskListItem[]>(await query);
    },
  });
}

// Задачи исполнителя без архивных. RLS и так отдаёт ему только свои;
// явный фильтр по assignee_id оставлен, чтобы запрос читался однозначно
// и пользовался частичным индексом tasks_assignee_active_idx.
export function useMyTasks(userId: string, status: TaskStatus | null) {
  return useQuery({
    queryKey: ["my-tasks", userId, status],
    queryFn: async () => {
      let query = supabase
        .from("tasks")
        .select(TASK_LIST_SELECT)
        .eq("assignee_id", userId)
        .is("archived_at", null)
        .order("id", { ascending: false });
      if (status) query = query.eq("status", status);
      return unwrap<TaskListItem[]>(await query);
    },
  });
}

export function useTask(taskId: string) {
  return useQuery({
    queryKey: ["task", taskId],
    queryFn: async () =>
      unwrap<TaskListItem | null>(
        await supabase.from("tasks").select(TASK_LIST_SELECT).eq("id", taskId).maybeSingle(),
      ),
  });
}

export function useTaskHistory(taskId: string) {
  return useQuery({
    queryKey: ["task-history", taskId],
    queryFn: async () =>
      unwrap<HistoryEntry[]>(
        // По id, а не по created_at: внутри одной транзакции created_at одинаков,
        // а UUID v7 сохраняет точный порядок событий.
        await supabase.from("task_history").select("*").eq("task_id", taskId).order("id"),
      ),
  });
}

// Правила переходов почти не меняются — кешируем на всё время работы.
export function useTransitions() {
  return useQuery({
    queryKey: ["transitions"],
    staleTime: Infinity,
    queryFn: async () => unwrap<Transition[]>(await supabase.from("task_transitions").select("*")),
  });
}

// Видимые профили: постановщику — все, исполнителю — он сам и постановщики.
// Нужны для имён в истории и списка исполнителей при создании задачи.
export function useProfiles() {
  return useQuery({
    queryKey: ["profiles"],
    queryFn: async () => unwrap<Profile[]>(await supabase.from("profiles").select("*").order("full_name")),
  });
}

// ---------------------------------------------------------------------------
// Действия
// ---------------------------------------------------------------------------

// После любого действия перечитываем все запросы. Данных мало, а так экран
// гарантированно показывает то, что сейчас в базе, включая поля, которые
// поставили триггеры (статус, даты, история).
function useInvalidateAll() {
  const queryClient = useQueryClient();
  return () => queryClient.invalidateQueries();
}

export function useCreateObject() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async (input: { name: string; address: string }) =>
      unwrap<CrmObject>(await supabase.from("objects").insert(input).select().single()),
    onSuccess: invalidate,
  });
}

export function useUpdateObject() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async ({ id, ...fields }: { id: string; name: string; address: string }) =>
      unwrap<CrmObject>(await supabase.from("objects").update(fields).eq("id", id).select().single()),
    onSuccess: invalidate,
  });
}

export function useArchiveObject() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async (objectId: string) =>
      unwrap(await supabase.rpc("archive_object", { p_object_id: objectId })),
    onSuccess: invalidate,
  });
}

// Клиент передаёт только содержательные поля; id, автора, статус и даты
// поставит база (на остальные колонки у клиента просто нет прав).
export type TaskInput = { title: string; description: string; assignee_id: string };

export function useCreateTask() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async (input: TaskInput & { object_id: string }) =>
      unwrap<Task>(await supabase.from("tasks").insert(input).select().single()),
    onSuccess: invalidate,
  });
}

export function useUpdateTask() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async ({ id, ...fields }: TaskInput & { id: string }) =>
      unwrap<Task>(await supabase.from("tasks").update(fields).eq("id", id).select().single()),
    onSuccess: invalidate,
  });
}

export function useChangeStatus() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async (input: { taskId: string; to: TaskStatus; comment: string }) =>
      unwrap(
        await supabase.rpc("change_task_status", {
          p_task_id: input.taskId,
          p_to: input.to,
          // Пустой комментарий не передаём: база сохранит NULL, а не пустую строку.
          ...(input.comment.trim() ? { p_comment: input.comment.trim() } : {}),
        }),
      ),
    onSuccess: invalidate,
  });
}

export function useArchiveTask() {
  const invalidate = useInvalidateAll();
  return useMutation({
    mutationFn: async (taskId: string) => unwrap(await supabase.rpc("archive_task", { p_task_id: taskId })),
    onSuccess: invalidate,
  });
}
