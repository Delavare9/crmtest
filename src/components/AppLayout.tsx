// Каркас экранов после входа: шапка с навигацией и пользователем,
// под ней — текущий экран (Outlet).
import { AppShell, Badge, Button, Container, Group, Text, Title } from "@mantine/core";
import { NavLink, Outlet } from "react-router";
import { useMe, useAuth } from "../lib/auth";
import { ROLE_LABEL } from "../lib/labels";

export function AppLayout() {
  const me = useMe();
  const { signOut } = useAuth();

  return (
    <AppShell header={{ height: 60 }} padding="md">
      <AppShell.Header>
        <Container size="lg" h="100%">
          <Group h="100%" justify="space-between" wrap="nowrap">
            <Group gap="lg" wrap="nowrap">
              <Title order={4} visibleFrom="md">
                Объекты и задачи
              </Title>
              <Group gap="xs" wrap="nowrap">
                <Button component={NavLink} to="/objects" variant="subtle" size="compact-md">
                  Объекты
                </Button>
                {/* «Мои задачи» имеют смысл только для исполнителя: постановщик видит
                    задачи через объекты. */}
                {me.role === "executor" && (
                  <Button component={NavLink} to="/my" variant="subtle" size="compact-md">
                    Мои задачи
                  </Button>
                )}
              </Group>
            </Group>
            <Group gap="sm" wrap="nowrap">
              <Text size="sm" visibleFrom="sm">
                {me.full_name}
              </Text>
              <Badge variant="light" visibleFrom="xs">
                {ROLE_LABEL[me.role]}
              </Badge>
              <Button variant="default" size="compact-md" onClick={() => void signOut()}>
                Выйти
              </Button>
            </Group>
          </Group>
        </Container>
      </AppShell.Header>
      <AppShell.Main>
        <Container size="lg">
          <Outlet />
        </Container>
      </AppShell.Main>
    </AppShell>
  );
}
