# Эксплуатация

Команды для запуска, деплоя, заполнения данных, логов и обслуживания. Все команды выполняются из корня репозитория.

## Переменные окружения

| Переменная | Где нужна | Откуда взять |
|---|---|---|
| `VITE_SUPABASE_URL` | Фронтенд, скрипты, тесты | Локально — `npm run env:local`; облако — Project Settings → Data API → URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Фронтенд, скрипты, тесты | Project Settings → API Keys → Publishable key |
| `SUPABASE_SECRET_KEY` | Только `seed` и `test:api` | Project Settings → API Keys → Secret key. **Не добавлять в Vercel** |
| `SEED_PASSWORD` | Только `seed` и `test:api` | Выбор владельца, не короче 8 символов |

Значения лежат в `.env.local` (в `.gitignore`). Шаблон — `.env.example`.

## Локальный запуск

```bash
npm install
```

```bash
npm run db:start
```

```bash
npm run env:local
```

```bash
npm run seed
```

```bash
npm run dev
```

Локальный стек запускается без Studio, imgproxy, почты и пула соединений. Нужна Studio (веб-панель базы на http://127.0.0.1:54323) — запустите без исключений:

```bash
npx supabase start
```

Пересоздать базу с нуля (все данные стираются, миграции применяются заново), затем заполнить:

```bash
npm run db:reset && npm run seed
```

## Деплой базы в Supabase Cloud

1. Создать проект в панели Supabase (регион — выбор владельца). Сохранить пароль базы.
2. Закрыть регистрацию: Authentication → Sign In / Providers → выключить **Allow new users to sign up**. Там же — минимальная длина пароля 8.
3. Указать адрес сайта: Authentication → URL Configuration → Site URL = адрес на Vercel.
4. Связать репозиторий с проектом (ref — из адреса проекта в панели):

```bash
npx supabase login
```

```bash
npx supabase link --project-ref <ref>
```

5. Посмотреть, какие миграции применятся, и применить:

```bash
npx supabase db push --remote --dry-run
```

```bash
npm run db:push
```

6. Проверить облако встроенным аудитом:

```bash
npx supabase db advisors --remote --level info
```

7. Заполнить облако: в `.env.local` подставить URL и ключи облачного проекта и пароль, затем:

```bash
npm run seed
```

8. Прогнать атаки против облака (создадут и сразу заархивируют объект «Проверка доступа …»):

```bash
npm run test:api
```

`supabase config push` для облака не использовать без просмотра `supabase config diff`: он перезапишет и локальные значения вроде `site_url = http://127.0.0.1:5173`.

## Деплой фронтенда на Vercel

Через панель: Import Git Repository → фреймворк определится как Vite (`vercel.json`) → Environment Variables: `VITE_SUPABASE_URL` и `VITE_SUPABASE_PUBLISHABLE_KEY` облачного проекта → Deploy. Каждый push в `main` выкатывается сам, pull request получает предпросмотр.

Через CLI:

```bash
npx vercel link
```

```bash
npx vercel env add VITE_SUPABASE_URL production
```

```bash
npx vercel env add VITE_SUPABASE_PUBLISHABLE_KEY production
```

```bash
npx vercel --prod
```

После первого деплоя внести адрес в Supabase: Site URL и Redirect URLs.

## Новая миграция

```bash
npx supabase migration new <что_меняем>
```

Написать SQL, затем проверить локально: база пересоздаётся, тесты проходят, типы обновляются.

```bash
npm run db:reset && npm run db:test && npm run db:types
```

```bash
npm run check
```

После слияния в `main` — `npm run db:push` в облако. Уже применённые миграции не редактируются: исправление — новой миграцией.

Правила переходов защищены триггером. Миграция, которая меняет существующие строки `task_transitions`, сначала отключает его:

```sql
alter table public.task_transitions disable trigger task_transitions_readonly;
-- изменения
alter table public.task_transitions enable trigger task_transitions_readonly;
```

## Логи

| Что | Где |
|---|---|
| Локальная база | `docker logs -f supabase_db_crmtest` |
| Локальный REST | `docker logs -f supabase_rest_crmtest` |
| Локальный Auth (входы, отказы в регистрации) | `docker logs -f supabase_auth_crmtest` |
| Облачная база, Auth, REST | Панель Supabase → Logs & Analytics (Postgres, Auth, API) |
| Медленные запросы в облаке | `npx supabase inspect db outliers --remote` |
| Фронтенд на Vercel | Панель Vercel → Deployments → Logs, либо `npx vercel logs <адрес-деплоя>` |
| Ход CI | GitHub → Actions |

Все отказы базы приходят с кодом: `42501` — нет прав, `P0002` — не найдено, `55000` — недоступно в текущем состоянии, `23514` — не прошла проверка данных. По коду легко фильтровать логи API.

## Пользователи

Новый пользователь: добавить в `DEMO_USERS` (`scripts/env.ts`) и запустить `npm run seed` — либо в панели Authentication → Add user, затем профиль в SQL Editor:

```sql
insert into public.profiles (id, full_name, role)
values ('<id из Authentication>', 'Имя Фамилия', 'executor');
```

Без строки в `profiles` пользователь войдёт, но увидит «Нет профиля» и ничего не сможет.

## Ключи и секреты

Проверка, что служебный ключ не попал в историю git (должно быть пусто):

```bash
git log -p --all | grep -inE 'sb_secret_[A-Za-z0-9]|service_role.*eyJ'
```

Если ключ утёк: Project Settings → API Keys → создать новый secret key, удалить старый, обновить `.env.local` и секреты CI. Публичный ключ секретом не является.

## Резервные копии и восстановление

На бесплатном тарифе Supabase делает ежедневные копии (панель → Database → Backups). Ручная копия схемы и данных:

```bash
npx supabase db dump --remote -f backup-schema.sql
```

```bash
npx supabase db dump --remote --data-only -f backup-data.sql
```

Файлы копий не коммитить.

## Частые проблемы

| Симптом | Причина и решение |
|---|---|
| «Не заданы VITE_SUPABASE_URL…» на старте | Нет `.env.local`: `npm run env:local` или заполнить по `.env.example` |
| Вход проходит, но «Нет профиля» | Пользователь в Auth без строки в `profiles` — см. «Пользователи» |
| `seed`: «Объекты уже есть» | Данные создаются один раз. Локально: `npm run db:reset && npm run seed` |
| `test:api` падает на входе | Пароль в `.env.local` не совпадает с паролем пользователей: повторить `npm run seed` (обновит пароли) |
| `db push` пишет в локальную базу | В CLI 3.x цель по умолчанию — локальная; для облака нужен `--remote` (так в `npm run db:push`) |
| `db:start` долго стартует впервые | Скачиваются образы Docker, это один раз |
