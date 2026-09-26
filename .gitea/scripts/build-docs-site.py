#!/usr/bin/env python3
"""Сборка staging-дерева для `mkdocs build` (docs/adr/0024-platform-docs-site.md §3).

Запускается CI-джобой .gitea/workflows/docs-site.yml перед `mkdocs build`, не рукам — источник
правды остаётся docs/ и roles/*/README.md в git, docs_build/ никогда не коммитится.

Два независимых top-level раздела навигации (ADR §3): "Архитектура" — docs/overview.md,
docs/components.md, docs/adr/, docs/platform/ (ровно этот список, ADR явно не включает
docs/runbooks/, docs/proxmox-templates.md, docs/Requirements Specification/ — не публикуются);
"Роли коллекции" — README каждой роли. ROADMAP.md не публикуется нигде (ADR §3).
"""
import re
import shutil
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
STAGING = REPO_ROOT / "docs_build"


def get_git_commit_hash() -> str:
    """Короткий хеш коммита, из которого собрана документация."""
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--short", "HEAD"],
            cwd=str(REPO_ROOT),
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return "unknown"

STATUS_RE = re.compile(r"^-\s+\*\*Статус:\*\*\s+(.+)$", re.MULTILINE)

# Оба раздела навигации ссылаются друг на друга в исходном дереве (roles/*/README.md -> docs/adr/,
# docs/components.md -> roles/*/README.md) — после разнесения по двум staging-каталогам
# относительные пути меняют глубину/родителя, поэтому переписываются на лету. Остальные внешние
# ссылки исходников (ROADMAP.md, docs/runbooks/, docs/Requirements Specification/ — ни один не
# публикуется, ADR §3) намеренно не переписываются и остаются битыми в собранном сайте.
ROLE_README_DOCS_LINK_RE = re.compile(r"\]\(\.\./\.\./docs/(adr|platform)/([^)]+)\)")
COMPONENTS_ROLE_LINK_RE = re.compile(r"\]\(\.\./roles/([\w-]+)/README\.md([^)]*)\)")


def rewrite_role_readme_links(text: str) -> str:
    return ROLE_README_DOCS_LINK_RE.sub(r"](../Архитектура/\1/\2)", text)


def rewrite_components_links(text: str) -> str:
    return COMPONENTS_ROLE_LINK_RE.sub(r"](../Роли коллекции/\1.md\2)", text)


def classify_status(label: str) -> str:
    """Грубая категория для цвета бейджа — не парсер точной семантики статуса."""
    lowered = label.lower()
    if "реализован" in lowered:
        return "implemented"
    if lowered.startswith("принято"):
        return "accepted"
    if lowered.startswith("предложено"):
        return "proposed"
    if lowered.startswith("черновик"):
        return "draft"
    return "unknown"


def inject_status_badge(text: str) -> str:
    match = STATUS_RE.search(text)
    if not match:
        return text

    full_label = match.group(1).strip()
    display_label = re.split(r"[;,]| \(", full_label)[0].strip()
    css_class = classify_status(full_label)
    badge = f'<span class="adr-status adr-status-{css_class}">{display_label}</span>\n'

    lines = text.splitlines(keepends=True)
    for i, line in enumerate(lines):
        if line.startswith("# "):
            lines.insert(i + 1, "\n" + badge)
            break
    return "".join(lines)


def build_architecture_section() -> None:
    dest = STAGING / "Архитектура"
    dest.mkdir(parents=True, exist_ok=True)

    shutil.copy(REPO_ROOT / "docs/overview.md", dest / "overview.md")

    components_text = (REPO_ROOT / "docs/components.md").read_text(encoding="utf-8")
    (dest / "components.md").write_text(rewrite_components_links(components_text), encoding="utf-8")

    adr_dest = dest / "adr"
    adr_dest.mkdir(exist_ok=True)
    for adr_file in sorted((REPO_ROOT / "docs/adr").glob("*.md")):
        text = adr_file.read_text(encoding="utf-8")
        (adr_dest / adr_file.name).write_text(inject_status_badge(text), encoding="utf-8")

    shutil.copytree(REPO_ROOT / "docs/platform", dest / "platform", dirs_exist_ok=True)


def build_roles_section() -> None:
    dest = STAGING / "Роли коллекции"
    dest.mkdir(parents=True, exist_ok=True)
    for readme in sorted((REPO_ROOT / "roles").glob("*/README.md")):
        role_name = readme.parent.name
        text = readme.read_text(encoding="utf-8")
        (dest / f"{role_name}.md").write_text(rewrite_role_readme_links(text), encoding="utf-8")


def copy_static_assets() -> None:
    shutil.copytree(
        REPO_ROOT / "docs/stylesheets",
        STAGING / "stylesheets",
        dirs_exist_ok=True,
    )
    js_dest = STAGING / "js"
    js_dest.mkdir(exist_ok=True)
    for js_file in (REPO_ROOT / "docs/js").glob("*.js"):
        shutil.copy(js_file, js_dest / js_file.name)

    # Записать хеш коммита сборки в .build-info — читается mermaid-zoom.js
    commit_hash = get_git_commit_hash()
    (STAGING / ".build-info").write_text(f"commit: {commit_hash}\n", encoding="utf-8")
    # Копируем .build-info в site/ (MkDocs не копирует dotfiles, копируем вручную)
    shutil.copy(STAGING / ".build-info", STAGING / "build-info.json")


def inject_build_version() -> None:
    """Добавляет extra.build_version в mkdocs.yml (только для mkdocs build).

    Material theme рендерит extra.footer в футере — используем его для показа
    хеша коммита сборки. build-docs-site.py модифицирует mkdocs.yml перед
    mkdocs build, а сам mkdocs.yml не коммитится с extra — чистый исходник.
    """
    mkdocs_path = REPO_ROOT / "mkdocs.yml"
    text = mkdocs_path.read_text(encoding="utf-8")
    commit_hash = get_git_commit_hash()
    # Экранируем двойные кавычки HTML для YAML (двойные кавычки YAML)
    footer_html = footer_html_raw = (
        '<div class="build-version">'
        'Сборка: <a href="https://github.com/anomalycs/devops-uslugi/tree/'
        + commit_hash
        + '" target="_blank" rel="noopener">'
        + commit_hash[:7]
        + '</a></div>'
    )
    footer_yaml = '"' + footer_html_raw.replace('"', '\\"') + '"'
    # Добавляем extra: секцию перед extra_css
    if "extra:" not in text:
        text = text.replace(
            "extra_css:",
            f"extra:\n  footer: {footer_yaml}\n\nextra_css:",
            1,
        )
    else:
        text = text.replace("extra:", f"extra:\n  footer: {footer_yaml}", 1)
    mkdocs_path.write_text(text, encoding="utf-8")


# Ни один исходник в docs/ не соответствует корню сайта — без этого у STAGING нет index.md,
# mkdocs не генерирует корневой index.html, а nginx отдаёt 403 на "/" (autoindex выключен,
# найдено живым прогоном при проверке ingress). components.md уже служит оглавлением для ролей
# (ссылки на каждый roles/*/README.md), поэтому landing-страница ссылается на него, а не
# перечисляет роли заново.
INDEX_CONTENT = """# devops.uslugi — документация платформы

- **[Архитектура](Архитектура/overview.md)** — обзор платформы и архитектурные решения (ADR).
- **[Роли коллекции](Архитектура/components.md)** — реестр всех ролей со ссылками на README
  каждой.

Полное дерево разделов — в меню слева.
"""


def build_index_page() -> None:
    (STAGING / "index.md").write_text(INDEX_CONTENT, encoding="utf-8")


def main() -> None:
    if STAGING.exists():
        shutil.rmtree(STAGING)
    STAGING.mkdir(parents=True)

    build_architecture_section()
    build_roles_section()
    copy_static_assets()
    inject_build_version()
    build_index_page()


if __name__ == "__main__":
    main()
