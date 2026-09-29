# Охрана destructive-guard и guarded-rm после обновления платформы (WP-023)

Обновление платформы восстанавливает хуки из шаблона (stale repair при `author_mode: false`). Правки РП-23 в `.claude/hooks/destructive-guard.sh` живут только в этом рабочем пространстве, пока не приняты в шаблон, — после обновления их нужно проверить.

Выполнить (из корня IWE; `python` — или `python3`):

```bash
python extensions/destructive-guard/hook_cases.py
python extensions/destructive-guard/long_cases.py
python extensions/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
```

Каждый должен закончиться строкой `итог: N из N как ожидалось`.

Если упало — обновление, скорее всего, вернуло хук шаблона:
- **сообщить пилоту** в итоге обновления: защита от рекурсивного удаления снова работает по старому правилу (временный путь где угодно в строке освобождает удаление);
- предложить наложить правку: `DS-strategy/inbox/WP-023/build/destructive-guard-v8-to-v9.patch` поверх версии после исправления ошибки 26.09 (`DS-strategy/inbox/bugs/bug-2026-09-26-destructive-guard-git-rm.patch`), затем снова запустить наборы;
- правка хуков — только с разрешения пилота (S-33).

Если шаблон уже принял правку, наборы пройдут — действий не нужно.
