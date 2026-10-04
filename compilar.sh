#!/usr/bin/env bash
set -euo pipefail

projectRoot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd -- "$projectRoot"
if (( $# > 2 )); then
    echo 'Uso: ./compilar.sh [archivo.pwn] [archivo.amx]' >&2
    exit 2
fi
compilerRoot="$projectRoot/tools/pawnc-3.10.10-linux"
sourceFile="${1:-gamemodes/Gm venta.pwn}"
outputFile="${2:-${sourceFile%.pwn}.amx}"
if [[ ! -x "$compilerRoot/bin/pawncc" ]]; then
    echo 'Falta el compilador Linux o su permiso de ejecucion. Consulta README.md.' >&2
    exit 1
fi
mkdir -p -- "$(dirname -- "$outputFile")"
LD_LIBRARY_PATH="$compilerRoot/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    "$compilerRoot/bin/pawncc" "$sourceFile" "-o$outputFile" \
    "-i$projectRoot/qawno/include" -d2 -E '-;+' '-(+'
