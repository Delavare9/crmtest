# Инструкции

Три части: работа в приложении, администрирование сотрудников и доработка системы. SQL-запросы выполняются в Supabase → **SQL Editor**; все проверены на локальной базе.

## Работа в приложении

Сайт: https://crmtest-six.vercel.app

### Постановщик

| Действие | Где |
|---|---|
| Создать объект | **Объекты** → **Новый объект** → название и адрес → **Сохранить** |
| Изменить объект | Карточка объекта → **Изменить** |
| Создать задачу | Карточка объекта → **Новая задача** → название, описание, исполнитель → **Сохранить** |
| Изменить задачу | Карточка задачи → **Изменить**. Кнопка есть только в статусах «Новая» и «На доработке» |
| Принять работу | Карточка задачи в статусе «На проверке» → **Принять** |
| Вернуть на доработку | Там же → **Вернуть на доработку** → причина обязательна |
| Убрать задачу | Карточка задачи → **В архив**. История сохраняется |
| Убрать объект | Карточка объекта → **В архив**. Только когда все задачи приняты или в архиве |
| Посмотреть архив | Переключатель **Показать архив** на списке объектов и в карточке объекта |

### Исполнитель

| Действие | Где |
|---|---|
| Свои задачи | **Мои задачи**, фильтр по статусу |
| Начать работу | Карточка задачи → **Взять в работу** (или **Снова в работу** после возврата) |
| Сдать | **Сдать на проверку**, комментарий по желанию |
| Узнать, что исправить | Карточка задачи → история: комментарий постановщика при возврате |

### Жизненный цикл задачи

Новая → В работе → На проверке → Принята. С проверки постановщик может вернуть: На доработке → В работе → На проверке.

## Сотрудники

Создавать сотрудников и назначать роли может только администратор — тот, у кого есть доступ к панели Supabase. В приложении этого нет (решения 6 и 13 в [DECISIONS.md](DECISIONS.md)).

### Список сотрудников

```sql
select p.full_name as имя,
       p.role      as роль,
       u.email,
       u.last_sign_in_at as последний_вход
  from public.profiles p
  join auth.users u on u.id = p.id
 order by p.role, p.full_name;
```

`manager` — постановщик, `executor` — исполнитель.

### Кто вошёл бы, но без роли

Пользователь есть в Auth, а профиля нет — в приложении увидит «Нет профиля».

```sql
select u.email
  from auth.users u
  left join public.profiles p on p.id = u.id
 where p.id is null;
```

### Загрузка исполнителей

Сколько активных задач у кого и в каких статусах.

```sql
select p.full_name as исполнитель,
       t.status    as статус,
       count(*)    as задач
  from public.tasks t
  join public.profiles p on p.id = t.assignee_id
 where t.archived_at is null
 group by 1, 2
 order by 1, 2;
```

### Добавить сотрудника

1. **Authentication → Users → Add user → Create new user**: email, пароль, галочка **Auto Confirm User**.
2. SQL Editor (роль `executor` или `manager`):

```sql
insert into public.profiles (id, full_name, role)
values ((select id from auth.users where email = 'почта@сотрудника'), 'Имя Фамилия', 'executor');
```

3. Передать сотруднику email и пароль.

### Сменить роль

```sql
update public.profiles set role = 'manager' where id = (select id from auth.users where email = 'почта@сотрудника');
```

Перед тем как сделать исполнителя постановщиком, переназначьте его незавершённые задачи: у задачи исполнитель должен быть с ролью «исполнитель».

### Отключить сотрудника

Удалить сотрудника нельзя: на него ссылается история задач. Вход блокируется:

```sql
update auth.users set banned_until = '2999-01-01' where email = 'почта@сотрудника';
```

Дата нужна конкретная: значение `'infinity'` Supabase Auth не распознаёт, вход проходит. Уже открытая сессия живёт до истечения токена (до часа). Вернуть доступ — `banned_until = null`.

## Доработка системы

Общее правило: применённые миграции не редактируются, любое изменение — новым файлом в `supabase/migrations/`:

```bash
npx supabase migration new <что_меняем>
```

После изменения — локальная проверка, затем выкатка в облако (см. [OPERATIONS.md](OPERATIONS.md)):

```bash
npm run db:reset && npm run db:types && npm run db:test && npm test
```

### Новый статус (пример: «Отменена»)

**1. Две миграции.** PostgreSQL не позволяет использовать новое значение перечисления в той же транзакции, где его добавили.

```sql
-- …_add_cancelled_status.sql
alter type public.task_status add value 'cancelled';
```

```sql
-- …_cancelled_transitions.sql
-- Кто и из какого статуса может отменить. Кнопки появятся в интерфейсе сами.
insert into public.task_transitions (from_status, to_status, actor_role, requires_comment) values
  ('new',         'cancelled', 'manager', true),
  ('in_progress', 'cancelled', 'manager', true);
```

**2. Завершённый ли статус.** Если отменённые задачи не мешают архивировать объект, во второй миграции пересоздать `public.archive_object` с условием `t.status not in ('accepted', 'cancelled')` (сейчас — `supabase/migrations/20261105150400_rpc.sql`, проверка активных задач).

**3. Типы:** `npm run db:types`. TypeScript укажет, где не хватает подписи нового статуса.

**4. Подписи** — `src/lib/labels.ts`:
- `STATUS_LABEL`: `cancelled: "Отменена"`;
- `STATUS_COLOR`: `cancelled: "dark"`;
- `STATUS_ORDER`: добавить в фильтр;
- `transitionLabel`: `if (to === "cancelled") return "Отменить";` — без этого кнопка будет «Перевести: Отменена».

**5. Тесты:**
- `src/lib/actions.test.ts` — добавить новые правила в `RULES` и ожидания;
- `supabase/tests/03_transitions.test.sql` — число запрещённых пар: 6 × 6 × 2 − 7 = 65 вместо 45.

### Новое поле задачи (пример: срок `due_date`)

**1. Миграция.** Колонка, право на запись и учёт в журнале:

```sql
alter table public.tasks add column due_date date;

-- Права выданы поколоночно: без этой строки клиент не сможет записать поле.
grant insert (due_date), update (due_date) on public.tasks to authenticated;
```

В этой же миграции пересоздать две функции из `supabase/migrations/20261105150300_triggers.sql`:
- `private.tasks_before_update`: в `v_fields_changed` добавить `or new.due_date is distinct from old.due_date` — правка срока пойдёт по тем же правилам («только в Новая и На доработке»);
- `private.tasks_log_update`: в `jsonb_build_object` добавить `'due_date', case when … end` — правка попадёт в историю «было и стало».

**2. Типы:** `npm run db:types`.

**3. Интерфейс:**
- `src/lib/queries.ts` — поле в `TaskInput`;
- `src/components/TaskFormModal.tsx` — поле ввода рядом с «Описание»;
- `src/pages/TaskPage.tsx` — показ в карточке;
- `src/lib/labels.ts` → `FIELD_LABEL`: `due_date: "Срок"` — подпись в истории.

**4. Тесты:**
- `supabase/tests/02_writes.test.sql` — добавить колонку в структурный тест прав (иначе он упадёт — так и задумано);
- `supabase/tests/04_history.test.sql` — правка срока пишется в историю.

### Выкатка доработки в облако

Без CLI: `npm run setup:sql` пересобирает полный скрипт, но в уже настроенной базе выполнять в SQL Editor нужно только **новые** файлы миграций, по порядку. С CLI или кнопкой GitHub Actions применятся только новые миграции автоматически.
