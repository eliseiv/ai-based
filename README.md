# AI Backend — AI Chat + Word Tools

Backend-сервис, реализующий:

1. **AI-чат** с поддержкой `conversationId` (автосоздание при первом сообщении, ответы с учётом истории).
2. **Word Tools** — поиск слов и фраз по 16 языковым критериям (рифмы, синонимы, антонимы, определения и т. д.) через LLM-провайдер.

**Стек:** Python 3.12, FastAPI, SQLAlchemy 2 (async), PostgreSQL, Alembic, OpenAI SDK, Docker Compose.

---

## Быстрый старт

```bash
# 1. Подготовить .env
cp .env.example .env
# отредактировать .env: указать OPENAI_API_KEY и при желании поменять API_KEY

# 2. Поднять контейнеры (api + postgres)
docker compose up --build
```

Когда оба контейнера в статусе `healthy`, доступны:

- **API:** `http://localhost:8000/api/v1`
- **Swagger UI:** `http://localhost:8000/docs`
- **ReDoc:** `http://localhost:8000/redoc`
- **OpenAPI JSON:** `http://localhost:8000/openapi.json`
- **Healthcheck:** `GET http://localhost:8000/healthz`

При старте контейнера автоматически выполняется `alembic upgrade head` — схема БД применяется без ручных шагов.

---

## Авторизация

Один статический ключ из `.env`:

```
API_KEY=my-super-secret-token
```

На каждый запрос (кроме `GET /healthz`) добавляйте заголовок:

```
Authorization: Bearer my-super-secret-token
```

`user_id` (для `conversations.user_id`, `search_requests.user_id` и rate-limit) выводится из ключа детерминированно через `uuid5` — стабилен между перезапусками.

### Тестирование через Swagger UI

1. Откройте http://localhost:8000/docs
2. В правом верхнем углу нажмите кнопку **Authorize** 🔓
3. В поле **Value** введите значение `API_KEY` (без слова `Bearer` — Swagger подставит его сам), нажмите **Authorize → Close**
4. Раскройте нужный эндпоинт → **Try it out** → введите тело запроса → **Execute**

После авторизации все защищённые эндпоинты помечены замком 🔒, и Swagger автоматически добавляет `Authorization: Bearer …` ко всем запросам.

---

## Эндпоинты

Все эндпоинты под префиксом `/api/v1`. Ошибки возвращаются единым конвертом:

```json
{
  "code": "string",
  "message": "string",
  "details": { },
  "requestId": "..."
}
```

Каждый ответ содержит заголовок `X-Request-Id`, по которому удобно искать запрос в логах.

---

### `POST /chat/conversations` — создать conversation

**Запрос:**
```json
{ "title": "Идеи песни" }
```
Поле `title` опциональное, до 200 символов. Можно отправить `{}`.

**Ответ 201:**
```json
{
  "conversationId": "f2bf8c34-4125-4c98-a838-40c22fabb148",
  "createdAt": "2026-05-08T14:39:08.169072Z"
}
```

**Пример (PowerShell):**
```powershell
$H = @{ "Authorization" = "Bearer local-dev-key-please-change"; "Content-Type" = "application/json" }
Invoke-WebRequest -Uri "http://localhost:8000/api/v1/chat/conversations" `
  -Method POST -Headers $H `
  -Body '{"title":"Smoke test"}' -UseBasicParsing | Select-Object -ExpandProperty Content
```

**Пример (curl):**
```bash
curl -X POST http://localhost:8000/api/v1/chat/conversations \
  -H "Authorization: Bearer local-dev-key-please-change" \
  -H "Content-Type: application/json" \
  -d '{"title":"Lyrics ideas"}'
```

**Возможные ошибки:** `400` (title длиннее 200), `401` (нет/неверный ключ), `429` (rate limit).

---

### `POST /chat/messages` — отправить сообщение и получить ответ AI

**Запрос:**
```json
{
  "message": "Suggest a rhyme scheme for a sad pop song.",
  "conversationId": "f2bf8c34-4125-4c98-a838-40c22fabb148"
}
```

- `message` — обязательное, 1..`MAX_MESSAGE_CHARS` (по умолчанию 8000) символов.
- `conversationId` — опциональное; если не передано, conversation создаётся автоматически.

**Ответ 200:**
```json
{
  "conversationId": "f2bf8c34-4125-4c98-a838-40c22fabb148",
  "userMessageId": "7457f283-b166-4d29-830c-dae127dd799d",
  "assistantMessageId": "2c0463b9-7692-4dd8-b9c1-a65611cb12b4",
  "assistantText": "Sure! Try ABAB with the chorus on AABB...",
  "createdAt": "2026-05-08T14:41:33.667429Z"
}
```

**Пример 1 — auto-create conversation (PowerShell):**
```powershell
$H = @{ "Authorization" = "Bearer local-dev-key-please-change"; "Content-Type" = "application/json" }
Invoke-WebRequest -Uri "http://localhost:8000/api/v1/chat/messages" `
  -Method POST -Headers $H `
  -Body '{"message":"Reply with the single word: pong"}' -UseBasicParsing | Select-Object -ExpandProperty Content
```

**Пример 2 — продолжить существующий тред (curl):**
```bash
curl -X POST http://localhost:8000/api/v1/chat/messages \
  -H "Authorization: Bearer local-dev-key-please-change" \
  -H "Content-Type: application/json" \
  -d '{
        "message":"And now suggest two more lines.",
        "conversationId":"f2bf8c34-4125-4c98-a838-40c22fabb148"
      }'
```

**Возможные ошибки:**
- `400` — пустое или слишком длинное сообщение
- `401` — нет/неверный ключ
- `403` — `conversationId` принадлежит другому пользователю (`conversation_forbidden`)
- `404` — `conversationId` не существует (`conversation_not_found`)
- `429` — rate limit
- `502` — ошибка LLM-провайдера (`llm_provider_error`)
- `504` — таймаут LLM (`llm_timeout`)

---

### `GET /word-tools/criteria` — список поддерживаемых критериев

Возвращает все 16 кодов критериев — используйте для построения UI-выбора.

**Ответ 200:**
```json
{
  "criteria": [
    { "code": "rhymes",            "title": "Rhymes" },
    { "code": "rhymes_advanced",   "title": "Rhymes (advanced)" },
    { "code": "near_rhymes",       "title": "Near rhymes" },
    { "code": "synonyms",          "title": "Synonyms" },
    { "code": "descriptive_words", "title": "Descriptive words" },
    { "code": "phrases",           "title": "Phrases" },
    { "code": "antonyms",          "title": "Antonyms" },
    { "code": "definitions",       "title": "Definitions" },
    { "code": "related_words",     "title": "Related words" },
    { "code": "similar_sounding",  "title": "Similar sounding words" },
    { "code": "similarly_spelled", "title": "Similarly spelled words" },
    { "code": "homophones",        "title": "Homophones" },
    { "code": "phrase_rhymes",     "title": "Phrase rhymes" },
    { "code": "match_consonants",  "title": "Match consonants" },
    { "code": "match_letters",     "title": "Match these letters" },
    { "code": "unscramble",        "title": "Unscramble (anagrams)" }
  ]
}
```

**Пример (curl):**
```bash
curl -H "Authorization: Bearer local-dev-key-please-change" \
  http://localhost:8000/api/v1/word-tools/criteria
```

---

### `POST /word-tools/search` — поиск по критерию

**Запрос:**
```json
{
  "query": "love",
  "criterion": "rhymes",
  "limit": 50,
  "offset": 0
}
```

Поля:
- `query` — слово/фраза/буквы (1..120 символов)
- `criterion` — один из 16 кодов
- `limit` — сколько вернуть (1..200, по умолчанию 50)
- `offset` — пагинация (≥0, по умолчанию 0)

**Ответ 200:**
```json
{
  "query": "love",
  "criterion": "rhymes",
  "total": 5,
  "items": [
    { "text": "dove",  "score": 1.0 },
    { "text": "glove", "score": 1.0 },
    { "text": "shove", "score": 1.0 },
    { "text": "above", "score": 0.8 },
    { "text": "of",    "score": 0.5 }
  ],
  "promptVersion": "rhymes.v1"
}
```

**Пример 1 — рифмы для "love" (PowerShell):**
```powershell
$H = @{ "Authorization" = "Bearer local-dev-key-please-change"; "Content-Type" = "application/json" }
Invoke-WebRequest -Uri "http://localhost:8000/api/v1/word-tools/search" `
  -Method POST -Headers $H `
  -Body '{"query":"love","criterion":"rhymes","limit":10,"offset":0}' -UseBasicParsing | Select-Object -ExpandProperty Content
```

**Пример 2 — синонимы к "happy" (curl):**
```bash
curl -X POST http://localhost:8000/api/v1/word-tools/search \
  -H "Authorization: Bearer local-dev-key-please-change" \
  -H "Content-Type: application/json" \
  -d '{"query":"happy","criterion":"synonyms","limit":10,"offset":0}'
```

**Пример 3 — анаграммы букв "listen":**
```bash
curl -X POST http://localhost:8000/api/v1/word-tools/search \
  -H "Authorization: Bearer local-dev-key-please-change" \
  -H "Content-Type: application/json" \
  -d '{"query":"listen","criterion":"unscramble","limit":15,"offset":0}'
```

**Пример 4 — все 16 критериев** (готовые тела для копирования в Swagger):

| Критерий | Тело запроса |
|---|---|
| `rhymes` | `{"query":"love","criterion":"rhymes","limit":10,"offset":0}` |
| `rhymes_advanced` | `{"query":"silver","criterion":"rhymes_advanced","limit":10,"offset":0}` |
| `near_rhymes` | `{"query":"orange","criterion":"near_rhymes","limit":10,"offset":0}` |
| `synonyms` | `{"query":"happy","criterion":"synonyms","limit":10,"offset":0}` |
| `descriptive_words` | `{"query":"ocean","criterion":"descriptive_words","limit":10,"offset":0}` |
| `phrases` | `{"query":"break","criterion":"phrases","limit":10,"offset":0}` |
| `antonyms` | `{"query":"fast","criterion":"antonyms","limit":10,"offset":0}` |
| `definitions` | `{"query":"serendipity","criterion":"definitions","limit":3,"offset":0}` |
| `related_words` | `{"query":"music","criterion":"related_words","limit":15,"offset":0}` |
| `similar_sounding` | `{"query":"night","criterion":"similar_sounding","limit":10,"offset":0}` |
| `similarly_spelled` | `{"query":"recieve","criterion":"similarly_spelled","limit":10,"offset":0}` |
| `homophones` | `{"query":"there","criterion":"homophones","limit":5,"offset":0}` |
| `phrase_rhymes` | `{"query":"sunshine","criterion":"phrase_rhymes","limit":10,"offset":0}` |
| `match_consonants` | `{"query":"brk","criterion":"match_consonants","limit":10,"offset":0}` |
| `match_letters` | `{"query":"l?ve","criterion":"match_letters","limit":10,"offset":0}` |
| `unscramble` | `{"query":"listen","criterion":"unscramble","limit":15,"offset":0}` |

> Все критерии работают только с английскими словами/фразами — это закреплено в системном промпте `prompts/_shared/system.txt`.

**Возможные ошибки:**
- `400` — неизвестный `criterion` или пустой `query` (`validation_error`)
- `401` — нет/неверный ключ
- `422` — `query` не подходит под критерий (например, `unscramble` с одним символом — `invalid_query_for_criterion`)
- `429` — rate limit
- `502` — LLM вернул невалидный JSON или сетевая ошибка
- `504` — таймаут LLM

---

## Конфигурация

Все настройки — в `.env`. Полный список — в `.env.example`. Самое важное:

| Переменная | Дефолт | Назначение |
|---|---|---|
| `DATABASE_URL` | — | `postgresql+asyncpg://user:pass@host:5432/db` |
| `API_KEY` | — | Bearer-ключ для всех запросов |
| `OPENAI_API_KEY` | — | Обязательно для реальных вызовов LLM |
| `OPENAI_CHAT_MODEL` | `gpt-4o-mini` | Модель для AI-чата |
| `OPENAI_WORDTOOLS_MODEL` | `gpt-4o-mini` | Модель для word-tools |
| `LLM_CHAT_TIMEOUT_SECONDS` | `20` | По истечении — 504 |
| `LLM_WORDTOOLS_TIMEOUT_SECONDS` | `8` | По истечении — 504 |
| `MAX_MESSAGE_CHARS` | `8000` | Жёсткий лимит на сообщение |
| `HISTORY_MAX_MESSAGES` | `30` | Сколько последних сообщений отдаём в LLM |
| `RATE_LIMIT_PER_MINUTE` | `0` | `0` = выкл; иначе — лимит req/min на ключ |
| `WORD_TOOLS_PROMPTS_DIR` | `prompts` | Директория с шаблонами промптов |

---

## Архитектура

```
HTTP → RequestContextMiddleware → RateLimitMiddleware → Router
     → Depends(auth) → Service → Repository | Provider → DB | OpenAI
```

- **Routers** (`app/api/v1/`) — только HTTP-валидация и маппинг ошибок.
- **Services** (`app/services/`) — бизнес-логика и управление транзакциями. AI-чат использует двухтранзакционную схему: запись пользовательского сообщения коммитится до вызова LLM, ответ — после, чтобы не держать соединение с PostgreSQL во время ожидания LLM.
- **Repositories** (`app/repositories/`) — тонкие обёртки над `AsyncSession`.
- **Providers** (`app/providers/`) — внешние интеграции за `Protocol`-интерфейсами; в тестах подменяются через DI override.

### Версионирование промптов word-tools

В каталоге `prompts/<criterion>.txt` лежит шаблон под каждый критерий, плюс общий системный промпт `prompts/_shared/system.txt`. У шаблона может быть директива версии в первой непустой строке:

```
# version: rhymes.v3
...
```

Если директивы нет, версия = `sha256(content)[:8]`. Версия возвращается в `promptVersion` ответа и попадает в логи — удобно для A/B-тестирования формулировок.

OpenAI вызывается с `response_format={"type":"json_object"}`, ответ валидируется через Pydantic. При невалидном JSON делается одна повторная попытка с усиленным «OUTPUT JSON ONLY» — если не помогло, отдаётся `502`.

### Rate limiting

**По умолчанию rate-limit выключен** (`RATE_LIMIT_PER_MINUTE=0`) — подходит для сценария, когда `API_KEY` зашит в мобильном клиенте и распространяется на всех пользователей iOS/Android приложения.

Чтобы включить лимит, поставьте положительное число: `RATE_LIMIT_PER_MINUTE=60`. Тогда подключится in-memory token-bucket на каждый `user_id` (а у одного `API_KEY` `user_id` всегда один — значит, лимит будет общим на все клиенты с этим ключом). Не лимитируются: `/healthz`, `/api/v1/word-tools/criteria`, `/docs`, `/redoc`, `/openapi.json`.

**Trade-off:** in-memory бакет работает корректно только для одного инстанса API. При горизонтальном масштабировании эффективный лимит превратится в `N × per_minute`. Чтобы перейти на Redis, достаточно заменить `RateLimitMiddleware` — остальной код не зависит от реализации.

### Логирование

JSON-лог на каждый запрос: `{"timestamp", "level", "request_id", "user_id", "method", "path", "status", "latency_ms", "provider"}`. Поле `provider` заполняется во время вызова LLM (`openai`). В каждый ответ кладётся заголовок `X-Request-Id` — клиент может задать свой, отправив тот же заголовок в запросе.

---

## Тесты

Тестам нужна реальная PostgreSQL (используется PG `ENUM`).

```bash
# 1. Поднять отдельную тестовую БД (или переиспользовать compose-овскую)
docker compose up -d postgres
docker compose exec postgres createdb -U aibased aibased_test

# 2. Установить dev-зависимости локально
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"

# 3. Запустить тесты
DATABASE_URL=postgresql+asyncpg://aibased:aibased@localhost:5432/aibased_test \
  pytest -q
```

С отчётом покрытия:
```bash
DATABASE_URL=postgresql+asyncpg://aibased:aibased@localhost:5432/aibased_test \
  pytest --cov=app --cov-report=term-missing
```

LLM в тестах подменяется на `tests/fakes/fake_llm.py` — реальные вызовы OpenAI не выполняются.

---

## Production-деплой

Все артефакты для развёртывания на сервере (Nginx + certbot + автодеплой через GitHub Actions) лежат в каталоге [`deploy/`](deploy/README.md). Кратко:

- **Nginx** обрывает TLS, редиректит HTTP→HTTPS, проксирует `/api/`, `/healthz`, `/docs`, `/redoc`, `/openapi.json` в контейнер `api`.
- **Certbot** в отдельном контейнере выпускает и автоматически продлевает Let's Encrypt сертификаты для `appstorepro.store` через webroot-challenge. Nginx делает `nginx -s reload` каждые 6 часов.
- **GitHub Actions** (`.github/workflows/deploy.yml`) при `git push origin main` билдит образ на ubuntu-раннере, пушит в `ghcr.io/<owner>/<repo>:sha-XXXXXXX`, заходит на сервер по SSH и делает `docker pull` + `docker compose up -d`. Старые образы автоматически очищаются (`docker image prune --filter until=72h`) — критично для серверов с маленьким диском.
- **Скрипты в `deploy/scripts/`**:
  - `init-server.sh` — настройка голой Ubuntu (Docker, ufw, fail2ban, swap 2GB, log-rotation, weekly cron-prune)
  - `init-letsencrypt.sh` — первичный выпуск сертификатов
  - `deploy.sh` — что выполняется на сервере при каждом деплое
  - `renew-certs.sh` — ручное продление (на случай если)

Подробная инструкция, чек-лист и список GitHub Secrets — в [`deploy/README.md`](deploy/README.md).

---

## Структура проекта

```
app/
  api/v1/        # routers (chat, word_tools)
  api/errors.py  # APIError-иерархия + handlers
  auth/          # резолвер bearer-ключа
  db/            # async engine, session, enums
  middleware/    # request context, rate limit
  models/        # SQLAlchemy-модели
  providers/
    llm/         # LLMProvider Protocol + OpenAIProvider
    word_tools/  # WordToolsProvider + LLM-prompt impl + загрузчик 16 шаблонов
  repositories/  # тонкие обёртки над AsyncSession
  schemas/       # Pydantic v2 (camelCase aliases)
  services/      # ChatService, WordToolsService
  config.py      # Settings (pydantic-settings)
  deps.py        # FastAPI Depends + HTTPBearer
  main.py        # фабрика приложения
prompts/         # 16 шаблонов LLM + _shared/system.txt
migrations/      # Alembic
deploy/          # Nginx + certbot + production docker-compose + скрипты
.github/workflows/deploy.yml   # CI/CD на ghcr.io + ssh deploy
tests/           # unit + integration + fakes
```
