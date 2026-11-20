"""Settings loaded from environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass, field


@dataclass(frozen=True)
class Settings:
    kudzu_host: str = "http://100.70.67.110:4001"
    kudzu_api_key: str = field(default="", repr=False)
    ollama_host: str = "http://localhost:11434"
    searxng_host: str = "http://localhost:8888"
    anthropic_api_key: str = field(default="", repr=False)

    @classmethod
    def from_env(cls) -> "Settings":
        env = os.environ
        d = cls()
        return cls(
            kudzu_host=env.get("KUDZU_HOST", d.kudzu_host).rstrip("/"),
            kudzu_api_key=env.get("KUDZU_API_KEY", ""),
            ollama_host=env.get("OLLAMA_HOST", d.ollama_host).rstrip("/"),
            searxng_host=env.get("SEARXNG_HOST", d.searxng_host).rstrip("/"),
            anthropic_api_key=env.get("ANTHROPIC_API_KEY", ""),
        )
