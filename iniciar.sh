#!/usr/bin/env bash
set -euo pipefail

projectRoot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$projectRoot"
if [[ ! -f config.json ]]; then
    echo 'Copia config.example.json a config.json y ajusta la configuracion antes de iniciar.' >&2
    exit 1
fi
mkdir -p -- scriptfiles models logs
exec ./omp-server "$@"
