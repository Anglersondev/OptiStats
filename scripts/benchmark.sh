#!/bin/bash
# Mede RAM (RSS/footprint) e CPU médio do OptiStats em repouso. Rode no Mac, com o app aberto e o Mac ocioso.
# Uso: scripts/benchmark.sh [duração_s=300] [processo=OptiStats]
set -e
DUR=${1:-300}; NAME=${2:-OptiStats}
PID=$(pgrep -x "$NAME" | head -1); [ -z "$PID" ] && { echo "Processo $NAME não encontrado"; exit 1; }
echo "# $NAME pid=$PID, ${DUR}s, $(sysctl -n machdep.cpu.brand_string), $(sw_vers -productVersion)"
echo "footprint:"; (footprint "$PID" 2>/dev/null | grep -E "Footprint|phys_footprint" | head -3) || true
echo "t_s,cpu_pct,rss_kb"
sum=0; n=0
for ((t=0; t<DUR; t+=5)); do
  read cpu rss < <(ps -o %cpu=,rss= -p "$PID"); echo "$t,$cpu,$rss"
  sum=$(echo "$sum + $cpu" | bc -l); n=$((n+1)); sleep 5
done
echo "CPU média: $(echo "scale=3; $sum / $n" | bc -l)%  (meta ≤ 1%)"
