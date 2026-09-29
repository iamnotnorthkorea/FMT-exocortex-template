"""Проверки destructive-guard по WP-023 (вариант Г).

Запуск: python wp23_hook_cases.py [<новый хук> [<прежний хук>]]
Без аргументов — живой хук IWE без сравнения с прежним (охрана после внедрения: запускается
расширениями недельного закрытия и обновления платформы).
1) случаи с ожидаемыми кодами нового и прежнего хука; нигде новый не пропускает того, что прежний
   блокировал (надмножество);
2) отказ в закрытую: подделки jq, perl, grep, sed, которые падают, — блокировка с «ошибка проверки»;
3) обход пилота CC_ALLOW_DESTRUCTIVE_INPUT=1 работает и при сломанном jq.
Команды хуку передаются как данные, ничего не выполняется.
"""
import json
import pathlib
import os
import subprocess
import sys
import tempfile

G = "/home/user/IWE/.claude/bin/guarded-rm"
SCR = "/tmp/claude/project/session/scratchpad"
NEW_ONLY = None  # код прежнего хука не проверяется (зависит от состояния репозитория и т. п.)

# (название, команда, код нового, код прежнего, подстрока в сообщении нового или None)
CASES = [
    # --- обычный рекурсивный rm теперь блокируется всегда, с подсказкой guarded-rm ---
    ("rm -rf во временном каталоге", "rm -rf /tmp/x", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("rm -rf в scratchpad буквально", f"rm -rf {SCR}/pkg", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("scratchpad через переменную с косой", f'S="{SCR}/"; rm -rf "$S/x"', 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("worktree Claude", "rm -rf .claude/worktrees/wt1", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("/tmp в соседней команде больше не освобождает", "rm -rf /important; ls /tmp/", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("реальный случай: данные проекта", 'SCRATCH=/c/x/scratchpad/f; DEST=/home/user/IWE/project-repo; '
     'cp -r "$SCRATCH/a" "$DEST/"; rm -rf "$DEST/data/analysis"/*.xlsx 2>/dev/null', 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("/usr/bin/rm", "/usr/bin/rm -rf build", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("/bin/rm", "/bin/rm -rf build", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("\\rm", "\\rm -rf build", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("find -exec во временном каталоге", "find /tmp/x -name '*.pyc' -exec rm -rf {} \\;", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("xargs rm во временном каталоге", "ls -d /tmp/x/* | xargs rm -rf", 2, 0, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("rm -rf в репозитории (как раньше)", "rm -rf ~/IWE/DS-strategy", 2, 2, ".claude/bin/guarded-rm (те же ключи и цели)"),
    ("git rm -r -f — своё сообщение", "git -C repo rm -r -f dir", 2, 2, "git rm с -r и -f"),
    # --- guarded-rm и прочее проходит ---
    ("guarded-rm по полному пути", f'{G} -rf "$S/x"', 0, 0, None),
    ("guarded-rm через xargs", f"ls -d /tmp/x/* | xargs {G} -rf", 0, 0, None),
    ("guarded-rm относительным путём", ".claude/bin/guarded-rm -r -f /tmp/x", 0, 0, None),
    ("rm -f без рекурсии", "rm -f file.txt", 0, 0, None),
    ("git rm -r --cached", "git rm -r --cached dir", 0, 0, None),
    ("флаги у разных команд", "git -C r rm -q a.txt; git -C r log --format=%h --reverse", 0, 0, None),
    ("строка «rm -r -f» в коде Python", "python - <<'EOF'\nif \"rm -r -f\" in text:\n    print(1)\nEOF", 0, 0, None),
    ("обычная команда", "ls -la", 0, 0, None),
    ("git add конкретных путей", "git add a.txt b.txt", 0, 0, None),
    ("git push --force-with-lease", "git push --force-with-lease origin main", 0, 0, None),
    ("git clean -n", "git clean -n", 0, 0, None),
    ("пустая команда", "", 0, 0, None),
    # --- все git-вызовы, а не только первый ---
    ("второй git add -A", "git add one; git add -A", 2, 0, "git add -A"),
    ("второй git push --force", "git push origin; git push --force origin", 2, 0, "git push --force"),
    ("git push --force на следующей строке", "git status\ngit push --force origin", 2, 0, "git push --force"),
    ("второй git clean -fdx", "git clean -n; git clean -fdx", 2, 0, "git clean"),
    ("второй git reset --hard", "git reset --soft HEAD; git reset --hard HEAD~3", 2, NEW_ONLY, "git reset --hard"),
    ("Codex r1: git после then", "git add one; if true; then git add -A; fi", 2, 0, "git add -A"),
    ("Codex r1: git после !", "git push origin; ! git push --force origin", 2, 0, "git push --force"),
    ("Codex r1: слитный -C<путь>", "git add one; git -Cother add -A", 2, 0, "git add -A"),
    ("--no-pager перед подкомандой", "git --no-pager push --force origin", 2, NEW_ONLY, "git push --force"),
    ("git за xargs", "echo . | xargs git clean -fdx", 2, NEW_ONLY, "git clean"),
    ("git за sudo с ключами", "sudo -u build git push --force origin", 2, NEW_ONLY, "git push --force"),
    ("git за env с присваиванием", "env GIT_TRACE=1 git add -A", 2, NEW_ONLY, "git add -A"),
    ("git после do в цикле", "for r in a b; do git -C \"$r\" clean -fdx; done", 2, NEW_ONLY, "git clean"),
    ("Codex r2: echo sudo git — не вызов", "echo sudo git add -A", 0, 0, None),
    ("Codex r2: printf env git — не вызов", "printf '%s\\n' env git add -A", 0, 0, None),
    ("Codex r2: command -p git", "git add one; command -p git add -A", 2, 0, "git add -A"),
    ("Codex r2: time -p git", "git add one; time -p git add -A", 2, 0, "git add -A"),
    ("Codex r2: перенаправление перед git", "git add one; > /dev/null git add -A", 2, 0, "git add -A"),
    ("перенаправление вплотную перед git", "2>/dev/null git push --force origin", 2, NEW_ONLY, "git push --force"),
    ("timeout с длительностью", "timeout 30 git push --force origin", 2, NEW_ONLY, "git push --force"),
    ("xargs -I {} git", "ls | xargs -I {} git -C {} clean -fdx", 2, NEW_ONLY, "git clean"),
    ("Codex r3: xargs --replace git", "git add one; xargs --replace git add -A", 2, 0, "git add -A"),
    ("Codex r3: env -S git", "git add one; env -S git add -A", 2, 0, "git add -A"),
    ("Codex r3: sudo --user build git", "git add one; sudo --user build git add -A", 2, 0, "git add -A"),
    ("Codex r3: time -o файл git", "git add one; /usr/bin/time -o /tmp/timing git add -A", 2, 0, "git add -A"),
    ("Codex r3: 2>&1 перед git", "git add one; 2>&1 git add -A", 2, 0, "git add -A"),
    ("Codex r3: >| перед git", "git add one; >| /dev/null git add -A", 2, 0, "git add -A"),
    ("Codex r3: апостроф в теле heredoc не прячет git после", "git add one; cat <<'EOF'\nDon't panic.\nEOF\ngit add -A", 2, 0, "git add -A"),
    ("Codex r3: command --help — справка, не запуск", "command --help git add -A", 0, 0, None),
    ("апостроф в комментарии не прячет git после", "# don't\ngit add -A", 2, NEW_ONLY, "git add -A"),
    ("экранированная ; делит, как в v8 (консервативно)", "echo a\\; git add -A", 2, 2, "git add -A"),
    ("экранированная кавычка не прячет git после", "echo it\\'s; git add -A", 2, NEW_ONLY, "git add -A"),
    ("nice -n 5 git", "nice -n 5 git push --force origin", 2, NEW_ONLY, "git push --force"),
    ("вложенные обёртки sudo env git", "sudo env GIT_TRACE=1 git add -A", 2, NEW_ONLY, "git add -A"),
    ("принятая ложная блокировка: аргумент ключа обёртки не отличить от команды", "env -u HOME echo git add -A", 2, 0, "git add -A"),
    ("Codex r4: экранированный пробел перед #", "echo \\ #; git add -A", 2, 2, "git add -A"),
    ("Codex r4: перенос строки после heredoc", "cat <<EOF\nx\nEOF\ntrue; git add \\\n -A", 2, 2, "git add -A"),
    ("Codex r4: аргумент ключа обёртки = имя данных", "env -u cat git add -A", 2, 0, "git add -A"),
    ("Codex r4: strace -o git git", "strace -o git git add -A", 2, 0, "git add -A"),
    ("Codex r4: перенаправление перед подкомандой", "git 2>/dev/null add -A", 2, 0, "git add -A"),
    ("Codex r4: флаг слит с перенаправлением", "git add -A>/dev/null", 2, 0, "git add -A"),
    ("Codex r4: $'...' в соседней команде", "echo $'it\\'s'; git add -A", 2, 0, "git add -A"),
    ("принятая ложная блокировка: env echo git (внутри обёртки)", "env echo git add -A", 2, 0, "git add -A"),
    ("Codex r5: '>' в кавычках перед -f", "git clean '>' -f .", 2, 2, "git clean"),
    ("Codex r5: '>' в кавычках перед -A", "git add '>' -A", 2, 2, "git add -A"),
    ("Codex r5: '>' в кавычках перед --force", "git push '>' --force", 2, 2, "git push --force"),
    ("Codex r5: git в комментарии (как v8)", "echo ok # ; git add -A", 2, 2, "git add -A"),
    ("Codex r5: -A на следующей строке (как v8)", "git add foo\n-A", 2, 2, "git add -A"),
    # --- различают механизмы нового разбора (v8 эти формы не видит) ---
    ("then: экранированный пробел перед #", "echo \\ # ; if x; then git add -A; fi", 2, 0, "git add -A"),
    ("then: перенос строки после heredoc", "cat <<EOF\nx\nEOF\nif true; then git add \\\n -A; fi", 2, 0, "git add -A"),
    ("then: '>' в кавычках перед -f", "true; if true; then git clean '>' -f .; fi", 2, 0, "git clean"),
    # --- точность: не блокировать, когда git — аргумент команды-данных ---
    ("if echo git — данные", "if echo git add -A; then :; fi", 0, 0, None),
    ("перенаправление перед echo git — данные", "2>/dev/null echo git add -A", 0, 0, None),
    ("перенаправление отдельным словом перед echo git — данные", "> out.txt echo git add -A", 0, 0, None),
    ("перенаправление отдельным словом перед git — вызов (v8 пропускал)", "> out.txt git add -A", 2, 0, "git add -A"),
    ("присваивание перед echo git — данные", "X=1 echo git add -A", 0, 0, None),
    ("& перенаправления перед echo git — данные", "2>&1 echo git add -A", 0, 0, None),
    ("git за неизвестной командой (strace)","strace git push --force origin", 2, NEW_ONLY, "git push --force"),
    ("git за ssh", "ssh host git clean -fdx", 2, NEW_ONLY, "git clean"),
    ("git как аргумент grep — данные", "grep -r git add -A .", 0, 0, None),
    ("apt install git — не вызов подкоманды", "apt install git", 0, 0, None),
    ("command -v git — запрос, не запуск", "command -v git", 0, 0, None),
    ("command -v git add -A — запрос сведений о трёх именах, не запуск", "command -v git add -A", 0, 0, None),
    # Строка тела heredoc, начинающаяся с git-команды, блокируется (принятый отказ, как упоминание rm -rf в
    # тексте): пропуск тел нарушил бы надмножество — v8 ловил такие строки после скобок и других разделителей.
    ("строка git в теле heredoc для cat — принятый отказ", "cat > f.md <<'EOF'\ngit push --force origin\nEOF", 2, NEW_ONLY, "git push --force"),
    ("строка git в теле heredoc для python (v8 тоже блокировал)", "python - <<EOF\nprint('git add -A')\ngit add -A\nEOF", 2, 2, "git add -A"),
    ("после тела heredoc — снова команды", "cat > f.md <<'EOF'\ntext\nEOF\ngit add -A", 2, NEW_ONLY, "git add -A"),
    ("тело heredoc для bash — команды", "bash <<'EOF'\ngit push --force origin\nEOF", 2, NEW_ONLY, "git push --force"),
    ("тело heredoc для ssh — команды", "ssh host <<EOF\ngit clean -fdx\nEOF", 2, NEW_ONLY, "git clean"),
    ("незавершённый heredoc — разбирается как команды", "cat <<EOF\ngit add -A", 2, NEW_ONLY, "git add -A"),
    ("два heredoc, один для bash — оба разбираются", "cat <<A; bash <<B\nx\nA\ngit add -A\nB", 2, NEW_ONLY, "git add -A"),
    ("упоминание git в echo — не вызов", "echo git add -A", 0, 0, None),
    ("упоминание git в кавычках — не вызов", 'git commit -m "не делай git add -A"', 0, 0, None),
    ("первый git add -A (как раньше)", "git add -A", 2, 2, "git add -A"),
    ("верхнеуровневый cd (как раньше)", "cd /c/Users", 2, 2, "cd"),
    ("psql DROP (как раньше)", 'psql -c "DROP TABLE t"', 2, 2, "DROP"),
    ("gh repo delete (как раньше)", "gh repo delete a/b", 2, 2, "gh repo delete"),
]

REAL = {}


def real(tool):
    if tool not in REAL:
        REAL[tool] = subprocess.run(["bash", "-c", f"command -v {tool}"], capture_output=True, text=True).stdout.strip()
    return REAL[tool]


def run(hook, command, env=None, raw_input=None, cwd=None):
    data = raw_input if raw_input is not None else json.dumps({"tool_input": {"command": command}})
    proc = subprocess.run(["bash", hook], input=data, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", env=env, cwd=cwd)
    return proc.returncode, proc.stderr.strip()


def clean_repo():
    """Чистый git-репозиторий: в нём `git reset --hard HEAD` безвреден, и исключение хука срабатывает."""
    repo = tempfile.mkdtemp(prefix="wp23-repo-")
    for args in (["init", "-q"], ["config", "user.email", "t@t.test"], ["config", "user.name", "t"]):
        subprocess.run(["git", "-C", repo, *args], check=True)
    with open(os.path.join(repo, "a.txt"), "w") as f:
        f.write("a\n")
    subprocess.run(["git", "-C", repo, "add", "a.txt"], check=True)
    subprocess.run(["git", "-C", repo, "commit", "-qm", "a"], check=True)
    return repo


def fake_env(tool, condition="true"):
    """PATH с подделкой tool: при условии (sh-выражение над "$*") выходит с кодом 3, иначе вызывает настоящий."""
    d = tempfile.mkdtemp(prefix="wp23-fake-")
    with open(os.path.join(d, tool), "w", newline="\n") as f:
        f.write(f'#!/bin/sh\nif {condition}; then exit 3; fi\nexec {real(tool)} "$@"\n')
    os.chmod(os.path.join(d, tool), 0o755)
    return dict(os.environ, PATH=d + os.pathsep + os.environ["PATH"])


def main():
    new = sys.argv[1] if len(sys.argv) > 1 else str(pathlib.Path(__file__).resolve().parents[2] / ".claude" / "hooks" / "destructive-guard.sh")
    old = sys.argv[2] if len(sys.argv) > 2 else None
    failed = 0
    lines = []

    def check(ok, text):
        nonlocal failed
        failed += not ok
        lines.append(("ok  " if ok else "НЕ  ") + text)

    for name, command, want_new, want_old, marker in CASES:
        got_new, err = run(new, command)
        got_old = run(old, command)[0] if old else want_old
        ok = got_new == want_new and (want_old is None or got_old == want_old)
        ok = ok and not (got_old == 2 and got_new == 0)          # надмножество
        ok = ok and (marker is None or marker in err)
        check(ok, f"новый {got_new} (ждали {want_new}), прежний {got_old} (ждали {want_old}) — {name}"
                  + ("" if ok or not err else f"\n      >> {err[:220]}"))

    # --- reset --hard в чистом репозитории: без cd исключение действует, с cd — нет ---
    repo = clean_repo()
    code, err = run(new, "git reset --hard HEAD", cwd=repo)
    check(code == 0, f"reset --hard HEAD в чистом репозитории → {code} — исключение действует")
    code, err = run(new, "(cd /home/user/IWE/other-repo && git reset --hard HEAD)", cwd=repo)
    old_code = run(old, "(cd /home/user/IWE/other-repo && git reset --hard HEAD)", cwd=repo)[0] if old else 0
    check(code == 2 and old_code == 0, f"reset --hard после cd → новый {code}, прежний {old_code} — исключение не действует")

    # --- отказ в закрытую ---
    code, err = run(new, "ls -la", env=fake_env("perl", 'case "$*" in *"cd\\\\s+"*) true;; *) false;; esac'))
    check(code == 2 and "ошибка проверки" in err, f"сломан только perl проверки cd → {code} — блокировка")
    # Ловушка выхода: копия хука с заведомо падающей строкой сразу после установки ловушки.
    hook_text = open(new, encoding="utf-8", newline="").read()
    anchor = "trap on_exit EXIT"
    if anchor in hook_text:
        broken = os.path.join(tempfile.mkdtemp(prefix="wp23-trap-"), "destructive-guard.sh")
        with open(broken, "w", encoding="utf-8", newline="") as f:
            f.write(hook_text.replace(anchor, anchor + "\nfalse", 1))
        code, err = run(broken, "ls -la")
        check(code == 2 and "неожиданный выход" in err, f"неожиданный сбой под set -e → {code} — блокировка")
    else:
        check(False, "в хуке нет ловушки выхода")

    # Подмена printf функцией окружения внутри load_segments (рецензия Codex, последний круг).
    env_file = os.path.join(tempfile.mkdtemp(prefix="wp23-env-"), "env.sh")
    with open(env_file, "w", newline="\n") as f:
        f.write('printf() { if [ "${FUNCNAME[1]:-}" = load_segments ]; then return 3; fi; builtin printf "$@"; }\n')
    code, err = run(new, "git add -A", env=dict(os.environ, BASH_ENV=env_file))
    check(code == 2, f"сломан printf внутри load_segments → {code} — git add -A всё равно блокируется")
    env_file2 = os.path.join(tempfile.mkdtemp(prefix="wp23-env-"), "env.sh")
    with open(env_file2, "w", newline="\n") as f:
        f.write('printf() { if [ "${FUNCNAME[1]:-}" = matches ]; then return 3; fi; builtin printf "$@"; }\n')
    code, err = run(new, "git add -A", env=dict(os.environ, BASH_ENV=env_file2))
    check(code == 2 and "ошибка проверки" in err, f"сломан printf внутри matches → {code} — блокировка, не «нет совпадения»")
    code, err = run(new, "ls -la", env=fake_env("jq", 'case "$*" in *cwd*) true;; *) false;; esac'))
    check(code == 0, f"jq падает на .cwd → {code} — cwd не читается, команда проходит")
    code, err = run(new, "ls -la", env=fake_env("jq"))
    check(code == 2 and "ошибка проверки" in err, f"сломан jq → {code} — любая команда блокируется")
    env = fake_env("jq")
    env["CC_ALLOW_DESTRUCTIVE_INPUT"] = "1"
    code, err = run(new, "ls -la", env=env)
    check(code == 0, f"сломан jq, обход пилота → {code} — пропуск")
    code, err = run(new, "ls -la", env=fake_env("perl"))
    check(code == 2 and "ошибка проверки" in err, f"сломан perl → {code} — блокировка")
    code, err = run(new, "git status", env=fake_env("perl", 'case "$*" in *SUBCMD*) true;; *) false;; esac'))
    check(code == 2 and "ошибка проверки" in err, f"сломан только разбор git → {code} — блокировка")
    code, err = run(new, "git status", env=fake_env("perl", 'case "$*" in *inspect_git*) true;; *) false;; esac'))
    check(code == 2 and "ошибка проверки" in err, f"сломан только новый разбор git (разбор v8 цел) → {code} — блокировка")
    code, err = run(new, "ls -la", env=fake_env("grep"))
    check(code == 2 and "ошибка проверки" in err, f"сломан grep → {code} — блокировка")
    code, err = run(new, "git push origin main", env=fake_env("sed"))
    check(code == 2 and "ошибка проверки" in err, f"сломан sed, git push → {code} — блокировка")
    code, err = run(new, "", raw_input="{не json")
    check(code == 2 and "ошибка проверки" in err, f"вход не JSON → {code} — блокировка")
    code, err = run(new, "ls -la", env=fake_env("perl", 'case "$*" in *@commands*) true;; *) false;; esac'))
    check(code == 0, f"сломан только разбор rm, команда не кандидат → {code} — пропуск")
    code, err = run(new, "rm -r a; ls -f", env=fake_env("perl", 'case "$*" in *@commands*) true;; *) false;; esac'))
    check(code == 2, f"сломан только разбор rm, кандидат → {code} — блокировка")

    print("\n".join(lines))
    print(f"итог: {len(lines) - failed} из {len(lines)} как ожидалось")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
