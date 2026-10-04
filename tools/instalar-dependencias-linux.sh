#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != Linux ]]; then
    echo 'Este instalador requiere Linux.' >&2
    exit 1
fi
case "$(uname -m)" in
    x86_64|i386|i486|i586|i686) ;;
    *) echo 'Los binarios incluidos requieren una maquina x86; no son ARM.' >&2; exit 1 ;;
esac
if ! command -v apt-get >/dev/null || ! command -v dpkg >/dev/null; then
    echo 'Este instalador requiere Ubuntu o Debian con apt-get y dpkg.' >&2
    exit 1
fi
if (( EUID != 0 )); then
    echo 'Ejecuta: sudo bash tools/instalar-dependencias-linux.sh' >&2
    exit 1
fi

dpkg --add-architecture i386
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    libc6:i386 libgcc-s1:i386 libatomic1:i386 libstdc++6:i386
