@echo off
cd /d "%~dp0"
"tools\pawn-3.10.10\pawncc.exe" "gamemodes\Gm venta.pwn" -o"gamemodes\Gm venta.amx" -i"qawno\include" -d2 -E -;+ -(+
if errorlevel 1 (
    echo Error al compilar Gm venta.
) else (
    echo Gm venta compilada correctamente.
)
pause
