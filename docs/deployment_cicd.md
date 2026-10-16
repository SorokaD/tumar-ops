# CI/CD tumar-ops

## Схема

- **CI** (`.github/workflows/ci.yml`) — на каждый PR и push в `develop`:
  - `validate`: `docker compose config` всех стеков (с `.env.example`), `promtool check config`
    (Prometheus + alert rules), `-verify-config` Loki, `-check-syntax` Promtail, `--config.check` Blackbox,
    JSON дашбордов Grafana, синтаксис YAML и Python;
  - `docker`: сборка `Dockerfile.mlflow` и `Dockerfile.superset`.
- **Deploy** (`.github/workflows/deploy.yml`) — push в `main` → CI → ручное подтверждение (`production`) → SSH.
  В Environment снять **Allow administrators to bypass**, иначе admin обходит Approve.
- Шаги на сервере:
  1. отказ, если в checkout на сервере есть ручные правки отслеживаемых файлов;
  2. `git fetch` + `git reset --hard <sha>`;
  3. `scripts/deploy.sh <old> <new>` — проверяет все compose-файлы и трогает только затронутое.

Образов в GHCR нет: сайт деплоится из `tumar-web`, DAG-и — git-sync из `tumar-airflow`.

## Что перезапускает `scripts/deploy.sh`

| Изменение | Действие |
|---|---|
| `docker/docker-compose.<stack>.yaml` | `up -d` этого стека (Compose пересоздаёт только сервисы с изменённым конфигом) |
| `docker/docker-compose.web.yaml` | `up -d --no-build --no-deps tumar-web` |
| `Dockerfile.mlflow` / `Dockerfile.superset` | `build` + `up -d` ML-стека |
| `config/prometheus/*` | `docker restart prometheus` |
| `config/loki/loki-config.yml` / `promtail-config.yml` | restart `loki` / `promtail` |
| `config/blackbox/*` | restart `blackbox-exporter` |
| `config/grafana/grafana.ini`, `provisioning/*` | restart `grafana` |
| `config/grafana/dashboards/*` | ничего: Grafana перечитывает каждые 30 с |
| `config/superset/*` | restart `superset` |
| `scripts/keepalive.py` | restart `keepalive` |

После этого ждёт healthcheck-и (до 3 минут) и падает, если есть `unhealthy` контейнеры.

Если невалиден любой compose-файл (например, не задана переменная в `.env`), ничего не применяется,
checkout возвращается на прежний коммит.

## Важно

- Все compose-файлы лежат в `docker/`, поэтому для Compose это **один проект `docker`**.
  `--remove-orphans` для одного файла удалит контейнеры всех остальных стеков. Не использовать.
- Конфиги смонтированы отдельными файлами; git записывает файл заново (новый inode),
  поэтому `/-/reload` Prometheus видит старую версию — нужен restart.
- Пароли и ключи обязательны (`${VAR:?...}`): без `.env` compose-команды не работают.
  Всегда `--env-file .env` из корня репо.
- Правки конфигов — только через PR. Ручная правка на сервере заблокирует следующий деплой.

## Секреты и окружение (GitHub → Settings)

- Secrets: `VPS_SSH_HOST`, `VPS_SSH_USER` (`okx-hft-ops`), `VPS_SSH_PRIVATE_KEY`,
  `VPS_DEPLOY_PATH` (`/opt/hft/okx-hft-ops`).
- Environment `production`: required reviewer, deployment branches — `main`.
- Branch protection `main`: обязательные проверки `validate`, `docker`.

## Откат

```bash
cd /opt/hft/okx-hft-ops
git reset --hard <old_sha>
bash scripts/deploy.sh <bad_sha> <old_sha>
```
