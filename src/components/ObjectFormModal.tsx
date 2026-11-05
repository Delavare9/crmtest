// Окно создания и правки объекта. Один компонент на оба случая:
// если передан object — правим его, иначе создаём новый.
import { useState } from "react";
import { Button, Group, Modal, Stack, TextInput } from "@mantine/core";
import { useCreateObject, useUpdateObject } from "../lib/queries";
import type { CrmObject } from "../lib/types";
import { notifyError, notifySuccess } from "./common";

export function ObjectFormModal({
  opened,
  onClose,
  object,
}: {
  opened: boolean;
  onClose: () => void;
  object?: CrmObject;
}) {
  const create = useCreateObject();
  const update = useUpdateObject();
  const [name, setName] = useState(object?.name ?? "");
  const [address, setAddress] = useState(object?.address ?? "");
  const saving = create.isPending || update.isPending;

  const submit = async () => {
    try {
      if (object) {
        await update.mutateAsync({ id: object.id, name: name.trim(), address: address.trim() });
        notifySuccess("Объект сохранён");
      } else {
        await create.mutateAsync({ name: name.trim(), address: address.trim() });
        notifySuccess("Объект создан");
        setName("");
        setAddress("");
      }
      onClose();
    } catch (error) {
      notifyError(error);
    }
  };

  return (
    <Modal opened={opened} onClose={onClose} title={object ? "Изменить объект" : "Новый объект"}>
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
            value={name}
            onChange={(event) => setName(event.currentTarget.value)}
            data-autofocus
          />
          <TextInput
            label="Адрес"
            value={address}
            onChange={(event) => setAddress(event.currentTarget.value)}
          />
          <Group justify="flex-end">
            <Button variant="default" onClick={onClose}>
              Отмена
            </Button>
            {/* Пустое название база тоже не примет (CHECK), здесь просто не даём отправить. */}
            <Button type="submit" loading={saving} disabled={!name.trim()}>
              Сохранить
            </Button>
          </Group>
        </Stack>
      </form>
    </Modal>
  );
}
