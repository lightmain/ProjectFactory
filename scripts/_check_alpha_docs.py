"""Temporary local link/heading check for the alpha backend documentation."""
from pathlib import Path
import re
import unicodedata
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    ROOT / "AGENTS.md",
    ROOT / "README.md",
    ROOT / "docs/development.md",
    *sorted((ROOT / "docs/features/alpha-2.0").glob("*.md")),
    ROOT / "docs/reviews/2026-11-25-alpha-2-start.md",
]


def anchors(path):
    seen = {}
    result = set()
    for heading in re.findall(r"^#{1,6}\s+(.+)$", path.read_text(), re.M):
        heading = re.sub(r"\[([^]]+)\]\([^)]*\)", r"\1", heading).lower()
        slug = "".join(c for c in heading if c == "-" or c == "_" or c.isspace()
                       or not unicodedata.category(c).startswith(("P", "S")))
        slug = re.sub(r"\s", "-", slug)
        suffix = seen.get(slug, 0)
        seen[slug] = suffix + 1
        result.add(slug if not suffix else f"{slug}-{suffix}")
    return result


paths = 0
headings = 0
errors = []
for source in SOURCES:
    for target in re.findall(r"\[[^]]*\]\(([^)]+)\)", source.read_text()):
        if re.match(r"[a-zA-Z][a-zA-Z0-9+.-]*:", target):
            continue
        path, _, fragment = unquote(target).partition("#")
        destination = (source.parent / path).resolve() if path else source
        paths += 1
        if not destination.exists():
            errors.append(f"{source.relative_to(ROOT)}: missing {target}")
        elif fragment and destination.suffix == ".md":
            headings += 1
            if fragment not in anchors(destination):
                errors.append(f"{source.relative_to(ROOT)}: missing anchor {target}")
for error in errors:
    print(error)
print(f"DOC_LINKS paths={paths} headings={headings} errors={len(errors)}")
raise SystemExit(bool(errors))
