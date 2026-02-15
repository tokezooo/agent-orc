Ниже — рабочий “скелет” под твой сценарий: **одно главное окно (Claude Code/Opus) = оркестратор**, а он через **tmux** поднимает **8–10 параллельных `codex exec`** под нужные проекты/профили (**Spark** для “быстро”, **deep/xhigh** для “план+анализ”). Завершение каждой задачи делает **отбивку** обратно в окно Opus (через `tmux send-keys`), плюс пишет логи/артефакты в папку оркестратора.

Важные факты из доков Codex CLI, на которых держится сетап:

* Codex CLI ставится через npm/brew, затем `codex` — логин (ChatGPT аккаунт или API key). ([OpenAI для разработчиков][1])
* Для скриптинга есть **`codex exec`**: по умолчанию он в **read-only sandbox**, а для правок есть **`--full-auto`**. ([OpenAI для разработчиков][2])
* `codex exec` поддерживает **`--json` (JSONL-ивенты), `-o/--output-last-message`, `--output-schema`, и PROMPT можно подавать через stdin (`-`)** — идеально для автоматизации. ([OpenAI для разработчиков][3])
* Конфиг Codex CLI живёт в `~/.codex/config.toml`, проектные оверрайды — в `.codex/config.toml` (после trust). ([OpenAI для разработчиков][4])
* Под “xhigh” есть настройка `model_reasoning_effort` (значения до `xhigh`, но `xhigh` модель-зависимый). ([OpenAI для разработчиков][4])
* Инструкции проекта удобно закреплять через `AGENTS.md` (цепочка глобал→проект). ([OpenAI для разработчиков][5])
* Модели/варианты типа `GPT-5.3-Codex` и `GPT-5.3-Codex-Spark` перечислены в “Models”/changelog Codex. ([OpenAI для разработчиков][6])

---

## 1) Базовая схема (как это будет работать)

**tmux session `ai`**:

* **window 0**: твой **Claude Code (Opus)**
* (опционально) **pane справа**: `agentctl tail` (живой лог уведомлений)
* каждое задание Codex = **новое tmux window** вида `project-profile-xxxxxx`
  там запускается `codex exec ...` и после завершения открывается shell (чтобы быстро посмотреть diff/тесты)

**Оркестратор** (скрипт `agentctl`) делает:

* создаёт run-папку `~/.ai-orch/runs/<run_id>/`
* пишет туда `prompt.md`, `events.jsonl`, `stderr.log`, `last_message.json`, `meta.json`
* запускает `codex exec` в отдельном tmux-window
* по завершению:

  * обновляет `meta.json` (goal_met/summary/thread_id/exit_code)
  * пишет строку в `~/.ai-orch/notify.log`
  * делает “отбивку” в Opus-окно через `tmux send-keys` (если включено)

---

## 2) Установка Codex CLI и tmux

### Codex CLI

Ставишь Codex CLI и логинишься (ChatGPT account или API key). ([OpenAI для разработчиков][1])

Пример:

```bash
# вариант npm
npm install -g @openai/codex

# или brew (если удобнее)
brew install codex

# логин
codex
```

### tmux

```bash
brew install tmux   # macOS
# или
sudo apt-get install tmux  # Ubuntu/Debian
```

---

## 3) Конфиг Codex: профили Spark / Deep (xhigh)

Файл: `~/.codex/config.toml` (и при желании `.codex/config.toml` в репах). ([OpenAI для разработчиков][4])

Пример (минимально полезный):

```toml
# ~/.codex/config.toml

# Базовые дефолты (на случай интерактивных сессий)
approval_policy = "on-request"     # untrusted | on-failure | on-request | never
sandbox_mode = "read-only"         # read-only | workspace-write | danger-full-access

# Профиль: быстрые правки / мелкие задачи
[profiles.spark]
model = "gpt-5.3-codex-spark"
model_reasoning_effort = "low"
model_verbosity = "low"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

# Профиль: глубокий анализ/планирование (xhigh если поддерживается)
[profiles.deep]
model = "gpt-5.3-codex"
model_reasoning_effort = "xhigh"   # модель-зависимо
model_verbosity = "medium"
model_reasoning_summary = "detailed"
approval_policy = "on-request"
sandbox_mode = "workspace-write"

# Профиль: review (без записи)
[profiles.review]
model = "gpt-5.3-codex"
model_reasoning_effort = "medium"
sandbox_mode = "read-only"
approval_policy = "never"
```

Что важно:

* `model_reasoning_effort` поддерживает значения до `xhigh`, но `xhigh` зависит от модели. ([OpenAI для разработчиков][4])
* Профили (`profiles.<name>`) — штатный механизм. ([OpenAI для разработчиков][4])
* Модельные слуги (включая Spark) смотри в Codex “Models”/changelog. ([OpenAI для разработчиков][6])

---

## 4) AGENTS.md (чтобы все сессии “думали одинаково”)

Codex подхватывает `AGENTS.md` автоматически (глобальный и проектный уровни). ([OpenAI для разработчиков][5])

**Глобальный** (опционально): `~/.codex/AGENTS.md`

```md
# Общие правила для всех реп
- Делай минимальные, безопасные изменения.
- Всегда предпочитай пройтись по тестам/линту если это быстро.
- Если задача расплывчатая — сформулируй явные критерии готовности в начале.
- В конце давай краткий итог: что изменено, как проверено, что осталось.
```

**Проектный**: `<repo>/AGENTS.md`

```md
# Правила проекта
- Стиль: eslint + prettier, форматировать перед коммитом
- Тесты: pnpm test
- Линт: pnpm lint
- Для миграций: не менять публичные API без отметки в CHANGELOG
```

---

## 5) Код оркестратора: `agentctl`

Это один файл Python (без зависимостей), который:

* регистрирует проекты
* запускает `codex exec`/`codex exec resume` в tmux окнах
* делает отбивки в Opus-окно (опционально)

### 5.1. Установка `agentctl`

```bash
mkdir -p ~/bin
nano ~/bin/agentctl
chmod +x ~/bin/agentctl
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.zshrc   # или ~/.bashrc
source ~/.zshrc
```

Вставь внутрь `~/bin/agentctl` вот этот код:

```python
#!/usr/bin/env python3
"""
agentctl: tiny tmux + Codex CLI orchestration helper.

Designed for:
- spawning many parallel `codex exec` runs in tmux windows (per project)
- collecting structured outputs via --output-schema / -o
- emitting a lightweight "done" notification back to a chosen tmux target
- (optional) resuming a non-interactive session via `codex exec resume <SESSION_ID>`

No external deps. Python 3.9+ recommended.
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import random
import re
import shlex
import string
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, Optional, Tuple


def _now_iso() -> str:
    return _dt.datetime.now().astimezone().isoformat(timespec="seconds")


def _short_rand(n: int = 6) -> str:
    alphabet = string.ascii_lowercase + string.digits
    return "".join(random.choice(alphabet) for _ in range(n))


def _default_home() -> Path:
    return Path(os.environ.get("AI_ORCH_HOME", "~/.ai-orch")).expanduser()


def _paths(home: Path) -> Dict[str, Path]:
    return {
        "home": home,
        "runs": home / "runs",
        "projects": home / "projects.json",
        "config": home / "config.json",
        "schema": home / "codex_output_schema.json",
        "notify_log": home / "notify.log",
    }


def _load_json(path: Path, default: Any) -> Any:
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def _save_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def _have_tmux() -> bool:
    try:
        subprocess.run(["tmux", "-V"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return True
    except Exception:
        return False


def _tmux_display_message(target: str, msg: str) -> None:
    if not _have_tmux():
        return
    try:
        subprocess.run(["tmux", "display-message", "-t", target, msg], check=False)
    except Exception:
        pass


def _tmux_send_keys(target: str, text: str, *, enter: bool = False) -> None:
    if not _have_tmux():
        return
    try:
        subprocess.run(["tmux", "send-keys", "-t", target, text], check=False)
        if enter:
            subprocess.run(["tmux", "send-keys", "-t", target, "Enter"], check=False)
    except Exception:
        pass


def _current_tmux_session() -> Optional[str]:
    if not _have_tmux():
        return None
    try:
        out = subprocess.check_output(["tmux", "display-message", "-p", "#S"], text=True).strip()
        return out or None
    except Exception:
        return None


def _safe_tmux_name(s: str, max_len: int = 40) -> str:
    s = re.sub(r"[^a-zA-Z0-9._-]+", "-", s).strip("-")
    if not s:
        s = "run"
    return s[:max_len]


def _read_prompt(prompt_file: str) -> str:
    if prompt_file == "-":
        return sys.stdin.read()
    return Path(prompt_file).expanduser().read_text(encoding="utf-8")


def _ensure_init(home: Path) -> Dict[str, Path]:
    p = _paths(home)
    p["home"].mkdir(parents=True, exist_ok=True)
    p["runs"].mkdir(parents=True, exist_ok=True)

    if not p["config"].exists():
        _save_json(p["config"], {})
    if not p["projects"].exists():
        _save_json(p["projects"], {"projects": {}})
    if not p["schema"].exists():
        _save_json(
            p["schema"],
            {
                "type": "object",
                "properties": {
                    "goal_met": {"type": "boolean"},
                    "summary": {"type": "string"},
                    "followup_prompt": {"type": "string"},
                    "notes": {"type": "string"},
                },
                "required": ["goal_met", "summary"],
                "additionalProperties": True,
            },
        )
    if not p["notify_log"].exists():
        p["notify_log"].write_text("", encoding="utf-8")

    return p


def cmd_init(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)

    session = _current_tmux_session() or os.environ.get("AI_TMUX_SESSION") or "ai"
    cfg = _load_json(p["config"], {})
    cfg.setdefault("tmux_session", session)
    cfg.setdefault("tmux_notify_target", f"{session}:0")  # window 0
    # If you want true "wake-up" into your Claude/Opus pane, set this to a pane id like "ai:0.0".
    cfg.setdefault("tmux_sendkeys_target", "")
    _save_json(p["config"], cfg)

    print("✅ Initialized agentctl workspace:")
    print(f"  Home:    {p['home']}")
    print(f"  Runs:    {p['runs']}")
    print(f"  Config:  {p['config']}")
    print(f"  Projects:{p['projects']}")
    print(f"  Schema:  {p['schema']}")
    print()
    print("Next:")
    print("  1) Add projects: agentctl add-project <name> <path> [--default-profile spark]")
    print("  2) Ensure Codex profiles exist in ~/.codex/config.toml (see answer template).")
    return 0


def cmd_add_project(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    data = _load_json(p["projects"], {"projects": {}})

    proj_path = Path(args.path).expanduser().resolve()
    if not proj_path.exists():
        print(f"❌ path does not exist: {proj_path}", file=sys.stderr)
        return 2

    data.setdefault("projects", {})
    data["projects"][args.name] = {"path": str(proj_path), "default_profile": args.default_profile}
    _save_json(p["projects"], data)
    print(f"✅ added project '{args.name}' -> {proj_path}")
    return 0


def _get_project(name: str, projects_path: Path) -> Dict[str, Any]:
    data = _load_json(projects_path, {"projects": {}})
    proj = data.get("projects", {}).get(name)
    if not proj:
        raise KeyError(f"Unknown project '{name}'. Add it via: agentctl add-project {name} /path/to/repo")
    return proj


def _write_run_meta(run_dir: Path, meta: Dict[str, Any]) -> None:
    _save_json(run_dir / "meta.json", meta)


def _new_run_id() -> str:
    return f"{_dt.datetime.now().strftime('%Y%m%d-%H%M%S')}-{_short_rand(4)}"


def _build_codex_exec_command(
    *,
    mode: str,
    proj_dir: Path,
    profile: str,
    schema_path: Path,
    last_file: Path,
    ephemeral: bool,
    full_auto: bool,
    sandbox: Optional[str],
    ask_for_approval: Optional[str],
    model: Optional[str],
    json_events: bool,
    skip_git_repo_check: bool,
    resume_session_id: Optional[str] = None,
) -> str:
    """
    Returns a shell-ready string.

    mode: "exec" or "resume"
    """
    parts: list[str] = ["codex", "exec"]
    if mode == "resume":
        parts.append("resume")
        if resume_session_id:
            parts.append(shlex.quote(resume_session_id))

    parts += ["-C", shlex.quote(str(proj_dir)), "--profile", shlex.quote(profile)]

    if ephemeral:
        parts.append("--ephemeral")
    if full_auto:
        parts.append("--full-auto")
    if sandbox:
        parts += ["--sandbox", shlex.quote(sandbox)]
    if ask_for_approval:
        parts += ["--ask-for-approval", shlex.quote(ask_for_approval)]
    if model:
        parts += ["--model", shlex.quote(model)]
    if json_events:
        parts.append("--json")
    if skip_git_repo_check:
        parts.append("--skip-git-repo-check")

    parts += ["--output-schema", shlex.quote(str(schema_path)), "-o", shlex.quote(str(last_file))]

    # PROMPT: read from stdin
    parts.append("-")
    return " ".join(parts)


def _spawn_tmux_window(
    *,
    tmux_session: str,
    window_name: str,
    cwd: Path,
    script_path: Path,
) -> None:
    if not _have_tmux():
        raise RuntimeError("tmux not found")
    subprocess.run(
        ["tmux", "new-window", "-t", tmux_session, "-n", window_name, "-c", str(cwd), "bash", str(script_path)],
        check=True,
    )
    subprocess.run(["tmux", "set-option", "-t", f"{tmux_session}:{window_name}", "remain-on-exit", "on"], check=False)


def _start_common(
    *,
    args: argparse.Namespace,
    run_id: str,
    run_dir: Path,
    proj_name: str,
    proj_dir: Path,
    profile: str,
    codex_cmd: str,
    title: str,
    parent_run_id: Optional[str] = None,
    resume_session_id: Optional[str] = None,
) -> None:
    prompt = _read_prompt(args.prompt_file)
    (run_dir / "prompt.md").write_text(prompt, encoding="utf-8")

    meta = {
        "run_id": run_id,
        "title": title or "",
        "project": proj_name,
        "project_dir": str(proj_dir),
        "profile": profile,
        "created_at": _now_iso(),
        "status": "running",
        "mode": "exec" if resume_session_id is None else "resume",
        "parent_run_id": parent_run_id,
        "thread_id": resume_session_id,  # filled from events for fresh runs; for resume we already know it
        "exit_code": None,
        "ended_at": None,
        "goal_met": None,
        "summary": None,
    }
    _write_run_meta(run_dir, meta)

    events_file = run_dir / "events.jsonl"
    stderr_file = run_dir / "stderr.log"
    prompt_file = run_dir / "prompt.md"

    run_sh = run_dir / "run.sh"
    run_sh.write_text(
        "\n".join(
            [
                "#!/usr/bin/env bash",
                "set -u",
                f'RUN_ID="{run_id}"',
                f'PROJECT_DIR="{str(proj_dir)}"',
                f'RUN_DIR="{str(run_dir)}"',
                "",
                'echo "[agentctl] run=$RUN_ID project=$PROJECT_DIR profile=' + profile + '"',
                "cd \"$PROJECT_DIR\"",
                "",
                "set +e",
                f'{codex_cmd} < "{str(prompt_file)}" > "{str(events_file)}" 2> >(tee "{str(stderr_file)}" >&2)',
                "EC=$?",
                "set -e",
                "",
                f'python3 "{str(Path(__file__).resolve())}" _on_finish --run-id "$RUN_ID" --exit-code "$EC"',
                "",
                'echo ""',
                'echo "[agentctl] done run=$RUN_ID exit=$EC"',
                f'echo "[agentctl] artifacts: {str(run_dir)}"',
                'echo "Drop into a shell for inspection. Type exit to close this tmux window."',
                'exec "${SHELL:-/bin/bash}" -l',
                "",
            ]
        )
        + "\n",
        encoding="utf-8",
    )
    run_sh.chmod(0o755)

    tmux_session = args.tmux_session
    window_name = _safe_tmux_name(f"{proj_name}-{profile}-{run_id[-6:]}", max_len=35)
    _spawn_tmux_window(tmux_session=tmux_session, window_name=window_name, cwd=proj_dir, script_path=run_sh)


def cmd_start(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    cfg = _load_json(p["config"], {})
    proj = _get_project(args.project, p["projects"])
    proj_dir = Path(proj["path"])

    profile = args.profile or proj.get("default_profile") or "spark"
    run_id = args.run_id or _new_run_id()
    run_dir = p["runs"] / run_id
    run_dir.mkdir(parents=True, exist_ok=False)

    tmux_session = args.tmux_session or cfg.get("tmux_session") or _current_tmux_session() or "ai"
    args.tmux_session = tmux_session

    schema_path = Path(args.output_schema).expanduser() if args.output_schema else p["schema"]
    last_file = run_dir / "last_message.json"

    codex_cmd = _build_codex_exec_command(
        mode="exec",
        proj_dir=proj_dir,
        profile=profile,
        schema_path=schema_path,
        last_file=last_file,
        ephemeral=args.ephemeral,
        full_auto=args.full_auto,
        sandbox=args.sandbox,
        ask_for_approval=args.ask_for_approval,
        model=args.model,
        json_events=args.json_events,
        skip_git_repo_check=args.skip_git_repo_check,
    )

    _start_common(
        args=args,
        run_id=run_id,
        run_dir=run_dir,
        proj_name=args.project,
        proj_dir=proj_dir,
        profile=profile,
        codex_cmd=codex_cmd,
        title=args.title,
    )

    notify_target = cfg.get("tmux_notify_target", f"{tmux_session}:0")
    _tmux_display_message(notify_target, f"▶️ Codex started: {run_id} ({args.project}, {profile})")
    print(run_id)
    return 0


def cmd_resume(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    cfg = _load_json(p["config"], {})

    parent_run_id = args.parent_run_id
    parent_dir = p["runs"] / parent_run_id
    parent_meta_path = parent_dir / "meta.json"
    if not parent_meta_path.exists():
        print(f"❌ unknown parent run_id: {parent_run_id}", file=sys.stderr)
        return 2
    parent_meta = _load_json(parent_meta_path, {})
    session_id = parent_meta.get("thread_id")
    if not session_id:
        print("❌ parent run has no thread_id (maybe it was --ephemeral or events weren't captured).", file=sys.stderr)
        return 2

    proj_name = parent_meta.get("project")
    proj_dir = Path(parent_meta.get("project_dir", "")).expanduser()
    if not proj_name or not proj_dir.exists():
        print("❌ could not resolve project from parent run.", file=sys.stderr)
        return 2

    profile = args.profile or parent_meta.get("profile") or "spark"
    run_id = args.run_id or _new_run_id()
    run_dir = p["runs"] / run_id
    run_dir.mkdir(parents=True, exist_ok=False)

    tmux_session = args.tmux_session or cfg.get("tmux_session") or _current_tmux_session() or "ai"
    args.tmux_session = tmux_session

    schema_path = Path(args.output_schema).expanduser() if args.output_schema else p["schema"]
    last_file = run_dir / "last_message.json"

    codex_cmd = _build_codex_exec_command(
        mode="resume",
        resume_session_id=str(session_id),
        proj_dir=proj_dir,
        profile=profile,
        schema_path=schema_path,
        last_file=last_file,
        ephemeral=args.ephemeral,
        full_auto=args.full_auto,
        sandbox=args.sandbox,
        ask_for_approval=args.ask_for_approval,
        model=args.model,
        json_events=args.json_events,
        skip_git_repo_check=args.skip_git_repo_check,
    )

    _start_common(
        args=args,
        run_id=run_id,
        run_dir=run_dir,
        proj_name=str(proj_name),
        proj_dir=proj_dir,
        profile=profile,
        codex_cmd=codex_cmd,
        title=args.title,
        parent_run_id=parent_run_id,
        resume_session_id=str(session_id),
    )

    notify_target = cfg.get("tmux_notify_target", f"{tmux_session}:0")
    _tmux_display_message(notify_target, f"↩️ Codex resumed: {run_id} (parent={parent_run_id})")
    print(run_id)
    return 0


def _extract_thread_id(events_path: Path) -> Optional[str]:
    if not events_path.exists():
        return None
    try:
        with events_path.open("r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") == "thread.started":
                    tid = obj.get("thread_id") or obj.get("thread-id") or obj.get("threadId")
                    if isinstance(tid, str) and tid:
                        return tid
                if obj.get("type") == "thread.started" and isinstance(obj.get("thread"), dict):
                    tid = obj["thread"].get("id")
                    if isinstance(tid, str) and tid:
                        return tid
    except Exception:
        return None
    return None


def _read_last_message(last_path: Path) -> Tuple[Optional[Dict[str, Any]], Optional[str]]:
    if not last_path.exists():
        return None, None
    raw = last_path.read_text(encoding="utf-8").strip()
    if not raw:
        return None, None
    try:
        return json.loads(raw), raw
    except json.JSONDecodeError:
        return None, raw


def _git_diff_stat(repo: Path) -> Optional[str]:
    try:
        out = subprocess.check_output(["git", "-C", str(repo), "diff", "--stat"], text=True, stderr=subprocess.DEVNULL).strip()
        return out or ""
    except Exception:
        return None


def cmd_on_finish(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    cfg = _load_json(p["config"], {})

    run_id = args.run_id
    run_dir = p["runs"] / run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        print(f"[agentctl] _on_finish: meta not found for run_id={run_id}", file=sys.stderr)
        return 2

    meta = _load_json(meta_path, {})
    meta["status"] = "finished"
    meta["exit_code"] = int(args.exit_code)
    meta["ended_at"] = _now_iso()

    if not meta.get("thread_id"):
        thread_id = _extract_thread_id(run_dir / "events.jsonl")
        if thread_id:
            meta["thread_id"] = thread_id

    parsed, raw = _read_last_message(run_dir / "last_message.json")
    if parsed is not None:
        meta["goal_met"] = parsed.get("goal_met")
        meta["summary"] = parsed.get("summary")
        meta["last_message"] = parsed
    else:
        meta["last_message_raw"] = raw

    proj_dir = Path(meta.get("project_dir", "")).expanduser()
    diff_stat = _git_diff_stat(proj_dir) if proj_dir else None
    if diff_stat is not None:
        meta["git_diff_stat"] = diff_stat

    _save_json(meta_path, meta)

    summary = meta.get("summary")
    goal_met = meta.get("goal_met")
    emoji = "✅" if goal_met is True and meta.get("exit_code") == 0 else ("⚠️" if meta.get("exit_code") == 0 else "❌")
    line = f"[{_dt.datetime.now().strftime('%Y-%m-%d %H:%M:%S')}] {emoji} done {run_id} proj={meta.get('project')} profile={meta.get('profile')} goal_met={goal_met} exit={meta.get('exit_code')}"
    if summary:
        line += f" — {summary}"
    line += "\n"

    p["notify_log"].write_text(p["notify_log"].read_text(encoding="utf-8") + line, encoding="utf-8")

    tmux_target = cfg.get("tmux_notify_target") or f"{cfg.get('tmux_session','ai')}:0"
    _tmux_display_message(tmux_target, line.strip())

    sendkeys_target = (cfg.get("tmux_sendkeys_target") or "").strip()
    if sendkeys_target:
        msg = f"[AI_ORCH DONE run_id={run_id} goal_met={goal_met} exit={meta.get('exit_code')}]"
        _tmux_send_keys(sendkeys_target, msg, enter=True)

    return 0


def cmd_list(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    runs_dir = p["runs"]

    runs = sorted([d for d in runs_dir.iterdir() if d.is_dir()], key=lambda d: d.name, reverse=True)
    runs = runs[: args.limit]

    for d in runs:
        meta_path = d / "meta.json"
        if not meta_path.exists():
            continue
        meta = _load_json(meta_path, {})
        status = meta.get("status")
        proj = meta.get("project")
        profile = meta.get("profile")
        goal = meta.get("goal_met")
        ec = meta.get("exit_code")
        title = meta.get("title") or ""
        parent = meta.get("parent_run_id") or ""
        print(f"{d.name}\t{status}\tproj={proj}\tprofile={profile}\tgoal_met={goal}\texit={ec}\tparent={parent}\t{title}")
    return 0


def cmd_show(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    run_dir = p["runs"] / args.run_id
    meta_path = run_dir / "meta.json"
    if not meta_path.exists():
        print(f"❌ unknown run_id: {args.run_id}", file=sys.stderr)
        return 2
    meta = _load_json(meta_path, {})
    print(json.dumps(meta, ensure_ascii=False, indent=2))
    return 0


def cmd_tail(args: argparse.Namespace) -> int:
    home = _default_home()
    p = _ensure_init(home)
    log_path = p["notify_log"]
    with log_path.open("r", encoding="utf-8") as f:
        f.seek(0, os.SEEK_END)
        try:
            while True:
                line = f.readline()
                if line:
                    sys.stdout.write(line)
                    sys.stdout.flush()
                else:
                    subprocess.run(["bash", "-lc", "sleep 0.2"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except KeyboardInterrupt:
            return 0


def _add_common_exec_flags(sp: argparse.ArgumentParser) -> None:
    sp.add_argument("--profile", default=None, help="Codex profile name (from ~/.codex/config.toml).")
    sp.add_argument("--title", default="")
    sp.add_argument("--prompt-file", default="-", help="Path to prompt file, or '-' for stdin.")
    sp.add_argument("--run-id", default=None, help="Optional explicit run id.")
    sp.add_argument("--tmux-session", default=None, help="tmux session to create the window in.")
    sp.add_argument("--full-auto", action="store_true", default=True, help="Use --full-auto. Default: true.")
    sp.add_argument("--no-full-auto", action="store_false", dest="full_auto")
    sp.add_argument("--sandbox", default=None, help="Override sandbox: read-only | workspace-write | danger-full-access")
    sp.add_argument("--ask-for-approval", default=None, help="Override approval: untrusted | on-failure | on-request | never")
    sp.add_argument("--model", default=None, help="Override model slug, e.g. gpt-5.3-codex-spark")
    sp.add_argument("--ephemeral", action="store_true", help="Use --ephemeral (no persistent session). Disables resume.")
    sp.add_argument("--json-events", action="store_true", default=True, help="Capture JSONL events via --json. Default: true.")
    sp.add_argument("--no-json-events", action="store_false", dest="json_events")
    sp.add_argument("--output-schema", default=None, help="Path to JSON Schema file for the final response.")
    sp.add_argument("--skip-git-repo-check", action="store_true", help="Allow running outside a Git repo (unsafe).")


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="agentctl")
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("init", help="Initialize ~/.ai-orch and seed config/schema/projects.")
    sp.set_defaults(func=cmd_init)

    sp = sub.add_parser("add-project", help="Register a project name -> path.")
    sp.add_argument("name")
    sp.add_argument("path")
    sp.add_argument("--default-profile", default="spark")
    sp.set_defaults(func=cmd_add_project)

    sp = sub.add_parser("start", help="Start a Codex run in a new tmux window.")
    sp.add_argument("--project", required=True)
    _add_common_exec_flags(sp)
    sp.set_defaults(func=cmd_start)

    sp = sub.add_parser("resume", help="Resume a previous non-interactive session (codex exec resume).")
    sp.add_argument("--parent-run-id", required=True, help="Run id to resume (uses its stored thread_id).")
    _add_common_exec_flags(sp)
    sp.set_defaults(func=cmd_resume)

    sp = sub.add_parser("_on_finish", help=argparse.SUPPRESS)
    sp.add_argument("--run-id", required=True)
    sp.add_argument("--exit-code", required=True)
    sp.set_defaults(func=cmd_on_finish)

    sp = sub.add_parser("list", help="List recent runs.")
    sp.add_argument("--limit", type=int, default=30)
    sp.set_defaults(func=cmd_list)

    sp = sub.add_parser("show", help="Show run metadata (JSON).")
    sp.add_argument("run_id")
    sp.set_defaults(func=cmd_show)

    sp = sub.add_parser("tail", help="Tail orchestrator notifications (like tail -f).")
    sp.set_defaults(func=cmd_tail)

    return p


def main(argv: list[str]) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
```

### 5.2. Инициализация и регистрация проектов

```bash
agentctl init

agentctl add-project projA ~/work/projA --default-profile spark
agentctl add-project projB ~/work/projB --default-profile deep
```

---

## 6) tmux: “отбивка” прямо в Claude Code (авто-wake)

### Вариант A (самый безопасный): просто хвостить лог

В окне Opus сделай сплит:

```bash
tmux split-window -h "agentctl tail"
```

### Вариант B (как ты описал): `send-keys` в панель Opus

1. Узнай pane id:

```bash
tmux list-panes -a
```

2. Открой `~/.ai-orch/config.json` и пропиши:

```json
{
  "tmux_session": "ai",
  "tmux_notify_target": "ai:0",
  "tmux_sendkeys_target": "ai:0.0"
}
```

Теперь при завершении любого run в Opus будет прилетать строка вида:

```
[AI_ORCH DONE run_id=20260213-120102-ab12 goal_met=True exit=0]
```

(и она отправится Enter’ом — т.е. реально “разбудит” чат).

---

## 7) Как именно запускать 8–10 сессий (команды)

### Один запуск (Spark)

```bash
agentctl start --project projA --profile spark --title "Quick fix: failing test" <<'PROMPT'
# TASK
Fix the failing unit test(s) with minimal change.

# Acceptance
- Tests pass (run the fastest relevant test command).
- No unrelated refactors.

# Output (IMPORTANT)
Return ONLY JSON:
{
  "goal_met": boolean,
  "summary": string,
  "followup_prompt": string,
  "notes": string
}
If you can't finish quickly, set goal_met=false and fill followup_prompt for the deep model.
PROMPT
```

### Пачка (8 задач подряд)

Ты просто повторяешь `agentctl start ...` 8 раз — каждый вызов создаст отдельное tmux окно и вернёт `run_id` в stdout (Opus может заносить это в “реестр”).

---

## 8) “Промпты” (готовые шаблоны)

### 8.1. Промпт для Opus-оркестратора (вставь в начало чата в Claude Code)

```text
Ты — Orchestrator (Opus) в одном терминальном окне.
Твоя задача: управлять параллельными Codex CLI задачами через tmux с помощью команды `agentctl`.

Инструменты:
- `agentctl start` запускает Codex задачу в новом tmux window и возвращает run_id.
- `agentctl show <run_id>` показывает JSON-метаданные и финальный структурированный результат.
- `agentctl list` показывает последние запуски.
- `agentctl resume --parent-run-id <run_id>` продолжает ту же non-interactive сессию (если нужно допромптить).

Политика маршрутизации:
- Профиль `spark`: быстрые правки/скрипты/одно-файловые изменения/быстрые проверки.
- Профиль `deep`: планирование, многокомпонентные изменения, сложные баги, рефакторинг.
- Если spark вернул goal_met=false или сомнительный результат — эскалируй в deep.

Как работать:
1) На каждую пользовательскую задачу делай декомпозицию (1-5 подзадач максимум).
2) Для каждой подзадачи сформируй PROMPT с критериями приемки (tests/lint/output).
3) Запускай через `agentctl start ... <<'PROMPT' ... PROMPT`.
4) Веди список RUNS: run_id → project/profile/title/status.
5) Когда приходит строка “[AI_ORCH DONE run_id=…]”:
   - Выполни `agentctl show <run_id>`.
   - Если goal_met=true и есть проверка/дифф выглядит ок — дай мне короткий итог (3-7 буллетов).
   - Если goal_met=false — запусти `agentctl resume` (или новый `agentctl start` в deep) с followup_prompt.
6) Не раздувай текст. Я хочу короткий статус по каждому run: ✅/⚠️/❌ + 1-2 строки.

Важно:
- Не “делай руками” изменения в репах сам; делегируй в Codex.
- Если задача не имеет четких критериев, формализуй их в prompt сам.
```

### 8.2. Шаблон PROMPT для Spark (быстро, если нет — эскалировать)

```text
# TASK
<одно предложение: что сделать>

# Context
- Repo: current directory
- Goal: <что считается “готово”>

# Constraints
- Minimal diff.
- Prefer surgical changes.
- Run only fast checks.

# Acceptance
- <1-3 пункта>

# If blocked
If anything is ambiguous or needs deeper analysis, set goal_met=false and write followup_prompt for a deep session.

# Output (STRICT)
Return ONLY JSON with keys:
goal_met (bool), summary (string), followup_prompt (string), notes (string)
```

### 8.3. Шаблон PROMPT для deep/xhigh (план+реализация)

```text
# TASK
<что сделать>

# Expectations
- First: identify the root cause / architecture impact.
- Then: implement a safe fix with tests (or at least a verification command).
- Prefer incremental commits/checkpoints (if you choose to create them, mention it).

# Acceptance
- <tests/lint + функциональное условие>

# Output (STRICT)
Return ONLY JSON with keys:
goal_met (bool), summary (string), followup_prompt (string), notes (string)
```

### 8.4. Шаблон review-задачи (если хочешь “двойную проверку” отдельным прогоном)

```text
# TASK
Review the current git diff for correctness, edge cases, and regressions.
Suggest any minimal improvements.

# Constraints
- Do not modify files (read-only).
- Prefer actionable checklist.

# Output (STRICT)
Return ONLY JSON with:
goal_met=true/false (true if changes look good),
summary,
followup_prompt (if changes are not acceptable),
notes (risks + suggested fixes).
```

---

## 9) Автоматический “цикл допромпта” (как ты описал)

Ты можешь держать правило:

* Spark всегда делает **первую попытку**.
* Если `goal_met=false` → Opus берёт `followup_prompt` и делает:

  ```bash
  agentctl resume --parent-run-id <spark_run_id> --profile deep <<'PROMPT'
  <followup_prompt из результата Spark + уточнение критериев>
  PROMPT
  ```

`codex exec resume` поддерживает follow-up PROMPT и stdin через `-`, так что это нормальный механизм “допромпта в ту же сессию”. ([OpenAI для разработчиков][3])

---

## 10) (Опционально) Если захочешь “без tmux” и с более настоящими callback’ами

Если позже захочется не через окна tmux, а реально “агент оркестрирует агента” программно — Codex CLI можно поднять как MCP server и оркестрировать через Agents SDK (это уже прямой путь к многоагентности без TUI). ([OpenAI для разработчиков][7])
Но под твой текущий UX (“одно окно Opus + tmux workers”) вариант выше обычно быстрее внедрить.

---

Если хочешь, можешь просто сказать: **“Сделай мне дефолтный набор профилей под Spark+Deep+Review с моими лимитами/правилами, и добавь авто-review после каждого run”** — и я под это расширю `agentctl` (например: `agentctl start --with-review`, который сам запускает второй read-only прогон и шлёт Opus один итог).

[1]: https://developers.openai.com/codex/quickstart/?utm_source=chatgpt.com "Quickstart"
[2]: https://developers.openai.com/codex/noninteractive/?utm_source=chatgpt.com "Non-interactive mode"
[3]: https://developers.openai.com/codex/cli/reference/ "Command line options"
[4]: https://developers.openai.com/codex/config-reference/ "Configuration Reference"
[5]: https://developers.openai.com/codex/guides/agents-md/?utm_source=chatgpt.com "Custom instructions with AGENTS.md"
[6]: https://developers.openai.com/codex/models/ "Codex Models"
[7]: https://developers.openai.com/codex/guides/agents-sdk/?utm_source=chatgpt.com "Use Codex with the Agents SDK"

