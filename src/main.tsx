// Точка входа: провайдеры (тема, кеш запросов, вход) и маршруты.
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { MantineProvider } from "@mantine/core";
import { Notifications } from "@mantine/notifications";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { Navigate, createBrowserRouter } from "react-router";
import { RouterProvider } from "react-router/dom";
// Стили Mantine подключаются один раз на всё приложение.
import "@mantine/core/styles.css";
import "@mantine/notifications/styles.css";
import { AppLayout } from "./components/AppLayout";
import { RequireAuth } from "./components/RequireAuth";
import { AuthProvider } from "./lib/auth";
import { LoginPage } from "./pages/LoginPage";
import { MyTasksPage } from "./pages/MyTasksPage";
import { ObjectPage } from "./pages/ObjectPage";
import { ObjectsPage } from "./pages/ObjectsPage";
import { TaskPage } from "./pages/TaskPage";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // Ошибку прав повторять бессмысленно — показываем сразу.
      retry: (failureCount, error) =>
        failureCount < 2 && !["42501", "PGRST301"].includes((error as { code?: string }).code ?? ""),
      refetchOnWindowFocus: true,
    },
  },
});

// Всё, кроме входа, — за RequireAuth и в общем каркасе с шапкой.
const router = createBrowserRouter([
  { path: "/login", element: <LoginPage /> },
  {
    element: <RequireAuth />,
    children: [
      {
        element: <AppLayout />,
        children: [
          { index: true, element: <Navigate to="/objects" replace /> },
          { path: "/objects", element: <ObjectsPage /> },
          { path: "/objects/:objectId", element: <ObjectPage /> },
          { path: "/tasks/:taskId", element: <TaskPage /> },
          { path: "/my", element: <MyTasksPage /> },
          { path: "*", element: <Navigate to="/objects" replace /> },
        ],
      },
    ],
  },
]);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <MantineProvider defaultColorScheme="auto">
      <Notifications position="top-right" />
      <QueryClientProvider client={queryClient}>
        <AuthProvider>
          <RouterProvider router={router} />
        </AuthProvider>
      </QueryClientProvider>
    </MantineProvider>
  </StrictMode>,
);
