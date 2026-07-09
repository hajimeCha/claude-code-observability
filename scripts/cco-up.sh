#!/usr/bin/env bash
#
# cco-up — Claude Code 可観測性スタックを確実に起動/復旧する。
#
# なぜ restart でなく down→up なのか:
#   Docker Desktop(WSL2) はホストのスリープ復帰でバックエンドを再起動する。その際、
#   バインドマウントのキャッシュ参照が失効し、単一ファイルマウント(prometheus.yml 等)は
#   exit 127、ディレクトリマウント(grafana provisioning)は空に解決されてダッシュボードが
#   消える。restart / start では古い参照を再利用して直らないため、down でコンテナを破棄し
#   up -d で作り直してマウントを貼り直す。詳細は README「トラブルシュート」参照。
#
# 使い方:
#   cco-up            コアスタックを復旧・検証
#   cco-up --traces   Tempo(traces プロファイル)も含めて起動
#
set -uo pipefail

PROJECT_DIR="${CCO_DIR:-$HOME/claude-code-observability}"
GRAFANA_URL="http://localhost:${GRAFANA_PORT:-3001}"
DASHBOARD_UID="claude-code-personal"
CORE_CONTAINERS=(cco-grafana cco-prometheus cco-loki cco-otel-collector)

profile_args=()
if [ "${1:-}" = "--traces" ]; then
  profile_args=(--profile traces)
  CORE_CONTAINERS+=(cco-tempo)
fi

cd "$PROJECT_DIR" || { echo "❌ プロジェクトが見つからない: $PROJECT_DIR"; exit 1; }

echo "▶ スタックを作り直す (down → up -d) ..."
docker compose "${profile_args[@]}" down
docker compose "${profile_args[@]}" up -d

echo -n "▶ Grafana 起動待ち"
health=000
for _ in $(seq 1 30); do
  health=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$GRAFANA_URL/api/health" 2>/dev/null || echo 000)
  [ "$health" = "200" ] && break
  echo -n "."; sleep 1
done
echo

echo "▶ 検証:"
fail=0

for c in "${CORE_CONTAINERS[@]}"; do
  st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)
  if [ "$st" = "running" ]; then echo "  ✓ $c: running"; else echo "  ✗ $c: $st"; fail=1; fi
done

if [ "$health" = "200" ]; then echo "  ✓ Grafana health: 200"; else echo "  ✗ Grafana health: $health"; fail=1; fi

# 前回の false-green の反省: 「箱が動いてる」で終わらせず、ダッシュボード定義が
# 実際に provisioning されたかまで確認する(マウント失効の直接症状はここに出る)。
if curl -s --max-time 5 "$GRAFANA_URL/api/search?type=dash-db" 2>/dev/null | grep -q "\"$DASHBOARD_UID\""; then
  echo "  ✓ ダッシュボード登録済み: $DASHBOARD_UID"
else
  echo "  ✗ ダッシュボード未登録(マウント失効の疑い)"; fail=1
fi

echo
if [ "$fail" = 0 ]; then
  echo "✅ OK → $GRAFANA_URL/d/$DASHBOARD_UID"
else
  echo "❌ 一部未復旧。'docker compose logs' / 'docker ps -a' を確認して。"
  exit 1
fi
