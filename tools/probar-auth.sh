#!/usr/bin/env bash
set -euo pipefail

projectRoot="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
port="${1:-7778}"
if (( $# > 1 )) || [[ ! "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port > 65533 )); then
    echo 'Uso: ./tools/probar-auth.sh [puerto entre 1 y 65533; CEF usa puerto + 2]' >&2
    exit 2
fi
testRoot="$(mktemp -d "${TMPDIR:-/tmp}/gm-venta-linux.XXXXXX")"
serverPid=''
scenarioRoot=''

stop_server() {
    [[ -n "$serverPid" ]] || return 0
    if kill -0 "$serverPid" 2>/dev/null; then
        printf 'exit\n' >&3
        local deadline=$((SECONDS + 5))
        while kill -0 "$serverPid" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done
        if kill -0 "$serverPid" 2>/dev/null; then
            echo 'El servidor de pruebas no cerro a tiempo.' >&2
            kill -KILL "$serverPid" 2>/dev/null || true
        fi
    fi
    local status=0
    wait "$serverPid" || status=$?
    serverPid=''
    exec 3>&-
    return "$status"
}

cleanup() {
    local status=$?
    trap - EXIT
    stop_server || true
    if (( status != 0 )) && [[ -n "$scenarioRoot" ]]; then
        for logFile in "$scenarioRoot/server.stdout" "$scenarioRoot/server.stderr" "$scenarioRoot/test.log"; do
            if [[ -f "$logFile" ]]; then
                printf '\n--- %s ---\n' "$logFile" >&2
                tail -n 100 -- "$logFile" >&2
            fi
        done
    fi
    echo "Resultados y bases temporales: $testRoot"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

start_scenario() {
    local name="$1" sourceFile="$2"
    scenarioRoot="$testRoot/$name"
    mkdir -p -- "$scenarioRoot"/{gamemodes,scriptfiles,models,plugins}
    cp -R -- "$projectRoot/scriptfiles/cef" "$scenarioRoot/scriptfiles/cef"
    ln -s -- "$projectRoot/omp-server" "$scenarioRoot/omp-server"
    ln -s -- "$projectRoot/components" "$scenarioRoot/components"
    ln -s -- "$projectRoot/plugins/samp_bcrypt.so" "$scenarioRoot/plugins/samp_bcrypt.so"
    "$projectRoot/compilar.sh" "$sourceFile" "$scenarioRoot/gamemodes/gamemode.amx"
    cat > "$scenarioRoot/config.json" <<EOF
{
  "pawn": {"main_scripts": ["gamemode 1"], "side_scripts": [], "legacy_plugins": ["samp_bcrypt"]},
  "name": "Pruebas Linux", "announce": false, "max_players": 10,
  "rcon": {"enable": false},
  "logging": {"file": "test.log", "enable": true, "log_sqlite": false, "log_sqlite_queries": false},
  "network": {"port": $port, "bind": "127.0.0.1"},
  "cef": {"debug": false, "resources_loader_mode": "none", "master_resource_key": "$(python3 -c 'import secrets; print(secrets.token_hex(16))')"}
}
EOF
    mkfifo -- "$scenarioRoot/console"
    exec 3<>"$scenarioRoot/console"
    (cd -- "$scenarioRoot"; exec ./omp-server <&3 >server.stdout 2>server.stderr) &
    serverPid=$!
}

wait_for_log() {
    local pattern="$1" deadline=$((SECONDS + $2))
    while (( SECONDS < deadline )); do
        if [[ -f "$scenarioRoot/test.log" ]] && grep -Eq -- "$pattern" "$scenarioRoot/test.log"; then
            return 0
        fi
        if ! kill -0 "$serverPid" 2>/dev/null; then
            echo 'El servidor termino antes de completar la prueba.' >&2
            return 1
        fi
        sleep 0.1
    done
    echo 'La prueba excedio el tiempo limite.' >&2
    return 1
}

check_errors() {
    if grep -Eiq '\[TEST\] FAIL:|Runtime error|\[Error\]|Failed to load|could not load|cannot open shared object' \
        "$scenarioRoot/test.log" "$scenarioRoot/server.stdout" "$scenarioRoot/server.stderr"; then
        echo 'Se encontraron errores del servidor o de sus dependencias.' >&2
        return 1
    fi
}

start_scenario arranque 'gamemodes/Gm venta.pwn'
wait_for_log '\[Auth\] Login y registro preparados\.' 20
wait_for_log 'Component initialized \(v1\.3\.0\)\.' 5
wait_for_log "Resource 'auth' successfully packed" 5
wait_for_log "Network Server started successfully on port $((port + 2))\." 5
[[ -s "$scenarioRoot/scriptfiles/cef/auth.pak" ]]
[[ -s "$scenarioRoot/scriptfiles/cef/auth.pak.manifest" ]]
[[ -s "$scenarioRoot/scriptfiles/gm_venta.db" ]]
stop_server
check_errors
echo '[LINUX] GM y CEF 1.3.0 iniciados; recurso HTML empaquetado y base SQLite temporal comprobados.'

start_scenario autenticacion 'tests/auth_security.pwn'
wait_for_log '\[TEST\] FIN:' 75
stop_server
check_errors
grep -Eq '\[TEST\] FIN: 0 fallos, [1-9][0-9]* comprobaciones' "$scenarioRoot/test.log"
grep -E '\[TEST\] FIN:' "$scenarioRoot/test.log"
