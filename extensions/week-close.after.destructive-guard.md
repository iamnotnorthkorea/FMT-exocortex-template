# Охрана destructive-guard и guarded-rm (WP-023)

Шаг недельного закрытия: убедиться, что защита от разрушительных команд не откатилась и работает. Наборы только читают хук и создают/удаляют файлы во временном каталоге — в рабочем пространстве ничего не пишут.

Выполнить (из корня IWE; `python` — или `python3`):

```bash
python extensions/destructive-guard/hook_cases.py
python extensions/destructive-guard/long_cases.py
python extensions/destructive-guard/guarded_rm_cases.py .claude/bin/guarded-rm
```

Каждый должен закончиться строкой `итог: N из N как ожидалось`.

В отчёт недели — одна строка: «Охрана destructive-guard: пройдена» или «НЕ пройдена: <набор, что упало>».

Если упало:
- вероятная причина — обновление платформы вернуло хук шаблона (`.claude/hooks/destructive-guard.sh`) или удалило `.claude/bin/guarded-rm`, `.claude/config/guarded-rm-roots.txt`;
- **не чинить молча** — сообщить пилоту и предложить наложить правку из `DS-strategy/inbox/WP-023/build/` (после архивации РП — `DS-strategy/archive/wp-contexts/WP-023/build/`);
- правка хуков — только с разрешения пилота (S-33).
