"""Antitrust 2.0 scenario presets. Company names are fictional."""
from __future__ import annotations

PRESETS: list[dict] = [
    {"label": "Triggered", "company": "Veridian Parcel Co.", "vertical": "last-mile delivery",
     "market_share": 62, "baseline_satisfaction": 81, "current_satisfaction": 68},
    {"label": "Watch", "company": "Northwind Streaming Ltd.", "vertical": "video streaming",
     "market_share": 55, "baseline_satisfaction": 80, "current_satisfaction": 78},
    {"label": "Not triggered", "company": "Brightwater Mapping Inc.", "vertical": "online maps",
     "market_share": 22, "baseline_satisfaction": 75, "current_satisfaction": 60},
    {"label": "Boundary", "company": "Quillfeather Search GmbH", "vertical": "web search",
     "market_share": 40, "baseline_satisfaction": 80, "current_satisfaction": 72},
]
