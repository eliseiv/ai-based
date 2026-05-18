from __future__ import annotations

from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.responses import ORJSONResponse

from app.api.errors import register_exception_handlers
from app.api.v1.router import api_v1_router
from app.auth.api_keys import ApiKeyResolver
from app.config import Settings, get_settings
from app.db.session import build_engine, build_sessionmaker
from app.logging_config import setup_logging
from app.middleware.rate_limit import RateLimitMiddleware
from app.middleware.request_context import RequestContextMiddleware
from app.providers.llm.openai_provider import OpenAIProvider
from app.providers.word_tools.llm_prompt_provider import LLMPromptWordToolsProvider
from app.providers.word_tools.prompt_loader import PromptLoader


def _default_llm_factory(settings: Settings):
    return OpenAIProvider(
        api_key=settings.OPENAI_API_KEY.get_secret_value(),
        base_url=settings.OPENAI_BASE_URL,
    )


def create_app(
    settings: Settings | None = None,
    *,
    llm_factory=None,
    word_tools_provider_factory=None,
    sessionmaker=None,
    engine=None,
) -> FastAPI:
    settings = settings or get_settings()
    setup_logging(settings.LOG_LEVEL)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if engine is None and sessionmaker is None:
            local_engine = build_engine(settings)
            local_sessionmaker = build_sessionmaker(local_engine)
            app.state.engine = local_engine
            app.state.sessionmaker = local_sessionmaker
        else:
            if engine is not None:
                app.state.engine = engine
            if sessionmaker is not None:
                app.state.sessionmaker = sessionmaker

        loader = PromptLoader(settings.WORD_TOOLS_PROMPTS_DIR)
        loader.load()
        app.state.prompt_loader = loader

        llm = (llm_factory or _default_llm_factory)(settings)
        app.state.llm = llm

        if word_tools_provider_factory is not None:
            provider = word_tools_provider_factory(settings, llm, loader)
        else:
            provider = LLMPromptWordToolsProvider(
                llm=llm, loader=loader, settings=settings
            )
        app.state.word_tools_provider = provider

        try:
            yield
        finally:
            local_engine = getattr(app.state, "engine", None)
            if local_engine is not None and engine is None:
                await local_engine.dispose()

    app = FastAPI(
        title="AI Backend — AI Chat и Word Tools",
        description=(
            "Backend для AI-чата с поддержкой `conversationId` "
            "и поиска слов/фраз по 16 языковым критериям через LLM.\n\n"
            "**Авторизация:** на каждом запросе (кроме `/healthz`) "
            "передавайте заголовок `Authorization: Bearer <API_KEY>`.\n\n"
            "В Swagger UI нажмите кнопку **Authorize** в правом верхнем углу "
            "и введите ваш `API_KEY` — Swagger будет автоматически "
            "подставлять токен ко всем запросам."
        ),
        version="1.0.0",
        default_response_class=ORJSONResponse,
        lifespan=lifespan,
        openapi_tags=[
            {
                "name": "chat",
                "description": (
                    "AI-чат: создание conversation и обмен сообщениями "
                    "с учётом истории."
                ),
            },
            {
                "name": "word-tools",
                "description": (
                    "Поиск слов и фраз по 16 языковым критериям "
                    "(рифмы, синонимы, антонимы и т. д.). Все запросы "
                    "выполняются на английском языке."
                ),
            },
            {
                "name": "system",
                "description": "Служебные эндпоинты (healthcheck).",
            },
        ],
    )

    app.state.settings = settings
    # Resolver is also re-created in lifespan; pre-create so middleware that
    # runs before lifespan completes (e.g. during tests) can rely on it.
    app.state.api_key_resolver = ApiKeyResolver(settings.api_key_map)

    register_exception_handlers(app)
    if settings.RATE_LIMIT_PER_MINUTE > 0:
        app.add_middleware(
            RateLimitMiddleware,
            resolver=app.state.api_key_resolver,
            per_minute=settings.RATE_LIMIT_PER_MINUTE,
            burst=max(settings.RATE_LIMIT_BURST, 1),
        )
    app.add_middleware(RequestContextMiddleware)

    app.include_router(api_v1_router)

    @app.get(
        "/healthz",
        tags=["system"],
        summary="Healthcheck",
        description="Проверка живости сервиса. Не требует авторизации.",
    )
    async def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


app = create_app()
