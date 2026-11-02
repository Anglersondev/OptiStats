#!/bin/bash
# True interval CPU, RSS and physical footprint; default: 5 minutes, process OptiStats.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$ROOT/scripts/benchmark.py" "$@"
