// Вход по email и паролю. Регистрации нет (решение 13): учётные записи
// создаёт администратор скриптом заполнения.
import { useState } from "react";
import { Alert, Button, Center, Paper, PasswordInput, Stack, Text, TextInput, Title } from "@mantine/core";
import { Navigate, useLocation, useNavigate } from "react-router";
import { useAuth } from "../lib/auth";
import { toUserMessage } from "../lib/errors";

export function LoginPage() {
  const { session, signIn } = useAuth();
  const navigate = useNavigate();
  const location = useLocation();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  // Куда вернуть после входа: страница, с которой перенаправил RequireAuth.
  const from = (location.state as { from?: string } | null)?.from ?? "/objects";

  // Уже вошёл (например, открыл /login в новой вкладке) — сразу к работе.
  if (session) return <Navigate to={from} replace />;

  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      await signIn(email.trim(), password);
      navigate(from, { replace: true });
    } catch (err) {
      setError(toUserMessage(err as { code?: string; message?: string }));
    } finally {
      setSubmitting(false);
    }
  };

  return (
    <Center mih="100vh" p="md">
      <Paper withBorder shadow="sm" p="xl" w="100%" maw={400}>
        <form
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          <Stack>
            <Title order={3}>Объекты и задачи</Title>
            <Text size="sm" c="dimmed">
              Вход для сотрудников. Доступ выдаёт администратор.
            </Text>
            {error && <Alert color="red">{error}</Alert>}
            <TextInput
              label="Email"
              type="email"
              autoComplete="username"
              required
              value={email}
              onChange={(event) => setEmail(event.currentTarget.value)}
            />
            <PasswordInput
              label="Пароль"
              autoComplete="current-password"
              required
              value={password}
              onChange={(event) => setPassword(event.currentTarget.value)}
            />
            <Button type="submit" loading={submitting}>
              Войти
            </Button>
          </Stack>
        </form>
      </Paper>
    </Center>
  );
}
