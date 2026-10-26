"""Tag spelling, shared by the daemon and the library CLI. Standard library
only, so `voice-say` can run without the daemon's dependencies."""
from __future__ import annotations

import re


def normalize_tag(raw: str) -> str:
    """Canonical form, the same rule as the app's TagText.sanitized: lowercase,
    separators → hyphens, only [a-z0-9-] kept, hyphen runs collapsed and
    trimmed ("News!!" and " news " → "news"). Empty = invalid."""
    s = re.sub(r"[ _\t\n]", "-", str(raw).lower())
    s = re.sub(r"[^a-z0-9-]", "", s)
    return re.sub(r"-{2,}", "-", s).strip("-")
