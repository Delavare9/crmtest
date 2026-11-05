// Пропускает на экраны только вошедшего пользователя с профилем.
//
// Это удобство, а не защита: без входа база всё равно ничего не отдаст
// (у роли anon нет прав ни на одну таблицу).
import { Alert, Button, Center, Loader, Stack } from "@mantine/core";
import { Navigate, Outlet, useLocation } from "react-router";
import { useAuth } from "../lib/auth";

export function RequireAuth() {
  const { session, me, loading, signOut } = useAuth();
  const location = useLocation();

  if (loading) {
    return (
      <Center h="100vh">
        <Loader />
      </Center>
    );
  }

  // Не вошёл — на вход, а после входа вернём на страницу, куда он шёл.
  if (!session) {
    return <Navigate to="/login" replace state={{ from: location.pathname }} />;
  }

  // Вошёл, но профиль не заведён: пользователь создан в Auth вручную без
  // строки в profiles. Работать он не сможет — база откажет во всём.
  if (!me) {
    return (
      <Center h="100vh" p="md">
        <Stack maw={420}>
          <Alert color="yellow" title="Нет профиля">
            Учётная запись есть, но роль не назначена. Обратитесь к администратору.
          </Alert>
          <Button variant="default" onClick={() => void signOut()}>
            Выйти
          </Button>
        </Stack>
      </Center>
    );
  }

  return <Outlet />;
}
