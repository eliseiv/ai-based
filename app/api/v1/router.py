from __future__ import annotations

from fastapi import APIRouter

from app.api.v1 import chat, word_tools

api_v1_router = APIRouter(prefix="/api/v1")
api_v1_router.include_router(chat.router)
api_v1_router.include_router(word_tools.router)
