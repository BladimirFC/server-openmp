# Servidor open.mp

Proyecto de servidor open.mp para Windows, con el gamemode Pawn `Gm venta`, registro e inicio de sesión mediante SQLite y bcrypt.

El repositorio incluye el código fuente, los AMX existentes, componentes, plugins, compiladores, includes, recursos y copias históricas del código que estaban presentes en la carpeta del proyecto al subirlo.

## Preparación

1. Copiar `config.example.json` como `config.json` y ajustar la configuración local, incluida la contraseña RCON antes de habilitar RCON.
2. Ejecutar `compilar.bat` para compilar `gamemodes/Gm venta.pwn` con el compilador incluido en `tools/pawn-3.10.10`.
3. Ejecutar `omp-server.exe` desde la raíz del proyecto.

La configuración de ejemplo selecciona `Gm venta 1` y el plugin `samp_bcrypt`. El gamemode crea automáticamente su base de datos en `scriptfiles/gm_venta.db`.

`mysql_login.example.ini` es una plantilla para las versiones históricas que usaban MySQL. El gamemode actual utiliza SQLite.

## Archivos locales

Las configuraciones con credenciales, las bases de datos de jugadores, los bans, los logs y los diagnósticos de compilación se excluyen mediante `.gitignore`. Las configuraciones actuales y las de los backups tienen una copia `.example` sin contraseñas reales. Los originales permanecen en el equipo local.

La carpeta `docs/` mencionada en `AGENTS.md` no estaba presente al crear este repositorio. Antes de desarrollar funciones nuevas, se deben restaurar las fuentes de referencia que exige ese archivo.
