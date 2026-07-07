# QA-агент (тестировщик) -- скелет

> Шаблон для DS-autonomous-agents/agents/tester/.
> Источник: WP-179 (6 уровней тестирования AI-бота).

## Структура

```
tester/
├── agent-card.yaml          # Паспорт агента (WEF 7 dimensions)
├── run-weekly.sh            # Точка входа cron
├── deepeval/
│   ├── eval_runner.py       # L3: LLM-as-Judge через Claude Haiku
│   └── rubrics.yaml         # 5 метрик качества
├── promptfoo/
│   ├── promptfoo.yaml       # L4: Red team probes
│   └── prompt-template.txt  # Полный system prompt бота
└── synthetic/
    └── scenarios.yaml       # L6: Multi-turn conversation scenarios
```

## Адаптация

1. **agent-card.yaml** -- заменить `{{AGENT_NAME}}`, `{{ROLE_ID}}`
2. **run-weekly.sh** -- заменить `{{BOT_REPO}}`, пути к .venv
3. **deepeval/rubrics.yaml** -- адаптировать criteria под свой домен
4. **deepeval/eval_runner.py** -- адаптировать SQL-запрос под свою схему БД
5. **promptfoo/prompt-template.txt** -- вставить полный system prompt бота
6. **promptfoo/promptfoo.yaml** -- добавить domain-specific probes
7. **synthetic/scenarios.yaml** -- написать сценарии под свои user flows
8. **synthetic/test_synthetic.py** -- адаптировать mock_setup под свои handler-ы
9. **synthetic/conversation_simulator.py** -- скопировать из DS-autonomous-agents (универсальный)

## Зависимости

- pytest, pytest-asyncio, pytest-mock, pytest-timeout
- anthropic (Python SDK)
- npx + promptfoo (для L4)
- asyncpg (для L3, если DB-sampling)

## Уровни тестирования

| Level | What | When | Tool |
|-------|------|------|------|
| L1 Smoke | Critical paths | CI/CD | pytest |
| L2 Regression | SM guards, callbacks | CI/CD | pytest |
| L3 AI Quality | Real dialogues | Weekly | Claude Haiku (judge) |
| L4 Red Team | Injection, PII | Weekly | Promptfoo |
| L5 Observability | Production traces | Continuous | Langfuse |
| L6 Synthetic | Multi-turn conversations | Weekly | Claude (simulator + judge) |
