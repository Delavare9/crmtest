// Полный цикл задачи через интерфейс, от имени трёх разных людей:
// постановщик создаёт → исполнитель берёт и сдаёт → постановщик возвращает
// с комментарием → исполнитель переделывает и сдаёт → постановщик принимает.
// Попутно проверяется, что каждый видит только свои кнопки и свои задачи.
import { expect, test, type Browser, type Page } from "@playwright/test";
import { DEMO_USERS, seedPassword, type DemoUserKey } from "../../scripts/env";

// Отдельный контекст браузера на каждого человека — как три разных компьютера.
async function login(browser: Browser, who: DemoUserKey): Promise<Page> {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("/objects");
  // Без входа приложение отправляет на страницу входа.
  await expect(page).toHaveURL(/\/login$/);
  await page.getByLabel("Email").fill(DEMO_USERS[who].email);
  await page.getByLabel("Пароль").fill(seedPassword());
  await page.getByRole("button", { name: "Войти" }).click();
  await expect(page).toHaveURL(/\/objects$/);
  return page;
}

// Нажать кнопку перехода, при необходимости написать комментарий, подтвердить
// и дождаться нового статуса на бейдже.
async function transition(page: Page, button: string, newStatus: string, comment?: string) {
  await page.reload();
  await page.getByRole("button", { name: button }).click();
  if (comment) await page.getByLabel(/Комментарий/).fill(comment);
  await page.getByRole("dialog").getByRole("button", { name: "Подтвердить" }).click();
  await expect(page.locator(".mantine-Badge-root", { hasText: newStatus })).toBeVisible();
}

test("задача проходит полный цикл с возвратом на доработку", async ({ browser }) => {
  const title = `Сквозной тест ${Date.now()}`;

  // Постановщик создаёт задачу в первом объекте и назначает исполнителя 1.
  const manager = await login(browser, "manager");
  await manager.getByText("ЖК «Северный», корпус 2").click();
  await manager.getByRole("button", { name: "Новая задача" }).click();
  await manager.getByLabel("Название").fill(title);
  await manager.getByLabel("Описание").fill("Проверка интерфейса");
  await manager.getByPlaceholder("Выберите исполнителя").click();
  await manager.getByRole("option", { name: DEMO_USERS.executor1.full_name }).click();
  await manager.getByRole("button", { name: "Сохранить" }).click();
  await manager.getByText(title).click();
  await expect(manager).toHaveURL(/\/tasks\//);
  const taskUrl = manager.url();

  // У новой задачи постановщику двигать нечего, но править можно.
  await expect(manager.getByRole("button", { name: "Принять" })).toHaveCount(0);
  await expect(manager.getByRole("button", { name: "Изменить" })).toBeVisible();

  // Исполнитель 2 по прямой ссылке задачу не видит.
  const stranger = await login(browser, "executor2");
  await stranger.goto(taskUrl);
  await expect(stranger.getByText("Задача не найдена.")).toBeVisible();

  // Исполнитель 1 берёт в работу и сдаёт.
  const executor = await login(browser, "executor1");
  await executor.goto(taskUrl);
  await transition(executor, "Взять в работу", "В работе");
  await transition(executor, "Сдать на проверку", "На проверке", "Готово, проверьте углы");
  // Принять свою работу исполнитель не может — кнопки нет.
  await expect(executor.getByRole("button", { name: "Принять" })).toHaveCount(0);

  // Постановщик возвращает: без комментария подтвердить нельзя.
  await manager.reload();
  await manager.getByRole("button", { name: "Вернуть на доработку" }).click();
  const confirm = manager.getByRole("dialog").getByRole("button", { name: "Подтвердить" });
  await expect(confirm).toBeDisabled();
  await manager.getByLabel(/Комментарий/).fill("Щель у двери в 3 мм");
  await confirm.click();
  await expect(manager.locator(".mantine-Badge-root", { hasText: "На доработке" })).toBeVisible();
  // В «На доработке» правка снова доступна.
  await expect(manager.getByRole("button", { name: "Изменить" })).toBeVisible();

  // Исполнитель переделывает и сдаёт повторно.
  await transition(executor, "Снова в работу", "В работе");
  await transition(executor, "Сдать на проверку", "На проверке");

  // Постановщик принимает; править принятую задачу нельзя.
  await transition(manager, "Принять", "Принята");
  await expect(manager.getByRole("button", { name: "Изменить" })).toHaveCount(0);

  // В истории все 7 событий: создание и шесть переходов, с комментариями.
  await expect(manager.locator(".mantine-Timeline-item")).toHaveCount(7);
  await expect(manager.getByText("«Щель у двери в 3 мм»")).toBeVisible();

  // В «Моих задачах» исполнителя 1 задача есть, у исполнителя 2 — нет.
  await executor.goto("/my");
  await expect(executor.getByText(title)).toBeVisible();
  await stranger.goto("/my");
  await expect(stranger.getByRole("heading", { name: "Мои задачи" })).toBeVisible();
  await expect(stranger.getByText(title)).toHaveCount(0);
});
