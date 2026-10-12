#!/usr/bin/env bash
# Применяет на ops-сервере изменения между двумя коммитами: трогает только затронутое.
#
#   scripts/deploy.sh <old_sha> <new_sha>
#
# Запускается из deploy workflow после `git reset --hard <new_sha>`, можно и вручную.
# Все стеки лежат в docker/, поэтому для Compose это один проект "docker":
# НИКОГДА не использовать --remove-orphans — удалит контейнеры остальных стеков.
set -euo pipefail

OLD="${1:?usage: deploy.sh <old_sha> <new_sha>}"
NEW="${2:?usage: deploy.sh <old_sha> <new_sha>}"

cd "$(dirname "$0")/.."
test -f .env || { echo "ERROR: .env not found in $(pwd)" >&2; exit 1; }

compose() {
  local stack="$1"
  shift
  docker compose -f "docker/docker-compose.${stack}.yaml" --env-file .env "$@"
}

STACKS=(traefik portainer stack ml web)

# Код 2 = ничего не применено (workflow откатывает checkout).
echo "== validate compose files"
for s in "${STACKS[@]}"; do
  compose "$s" config --quiet || { echo "ERROR: invalid compose: $s" >&2; exit 2; }
done

CHANGED="$(git diff --name-only "$OLD" "$NEW")"
if [ -z "$CHANGED" ]; then
  echo "nothing changed between $OLD and $NEW"
  exit 0
fi
echo "== changed files"
echo "$CHANGED"

changed() { grep -qE "$1" <<<"$CHANGED"; }

applied=0
run() {
  echo "+ $*"
  "$@"
  applied=1
}

echo "== apply"
changed '^docker/docker-compose\.traefik\.yaml$' && run compose traefik up -d
changed '^docker/docker-compose\.portainer\.yaml$' && run compose portainer up -d
changed '^docker/docker-compose\.stack\.yaml$' && run compose stack up -d
changed '^docker/docker-compose\.web\.yaml$' && run compose web up -d --no-build --no-deps tumar-web

if changed '^Dockerfile\.mlflow$'; then
  run compose ml build mlflow
fi
if changed '^Dockerfile\.superset$'; then
  run compose ml build superset
fi
if changed '^(docker/docker-compose\.ml\.yaml|Dockerfile\.(mlflow|superset))$'; then
  run compose ml up -d --no-build
fi

# Конфиги смонтированы отдельными файлами, а git пишет файл заново (новый inode):
# /-/reload увидит старую версию, поэтому только restart. `up -d` такие правки не подхватывает.
changed '^config/prometheus/' && run docker restart prometheus
changed '^config/loki/loki-config\.yml$' && run docker restart loki
changed '^config/loki/promtail-config\.yml$' && run docker restart promtail
changed '^config/blackbox/' && run docker restart blackbox-exporter
changed '^config/grafana/(grafana\.ini|provisioning/)' && run docker restart grafana
changed '^config/superset/' && run docker restart superset
changed '^scripts/keepalive\.py$' && run docker restart keepalive

if [ "$applied" -eq 0 ]; then
  echo "no runtime changes (docs/CI/dashboards only; dashboards reload automatically)"
fi

echo "== wait for healthchecks"
for _ in $(seq 1 36); do
  if [ -z "$(docker ps -q --filter health=starting)" ]; then
    break
  fi
  sleep 5
done
unhealthy="$(docker ps --filter health=unhealthy --format '{{.Names}}')"
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}'
if [ -n "$unhealthy" ]; then
  echo "ERROR: unhealthy containers: $unhealthy" >&2
  exit 1
fi
echo "deploy applied: $OLD -> $NEW"
