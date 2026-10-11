# Servidor open.mp

Proyecto de servidor open.mp para Windows y Linux x86, con el gamemode Pawn `Gm venta`, registro e inicio de sesión mediante SQLite y bcrypt.

El acceso dispone de una interfaz HTML con **omp-cef 1.3.0** y conserva los diálogos clásicos para clientes sin el mod. Consulta [CEF.md](CEF.md) para configurar el componente, instalar el cliente en GTA y abrir el puerto UDP adicional.

El repositorio incluye el código fuente, los AMX existentes, componentes, plugins, compiladores, includes, recursos y copias históricas del código que estaban presentes en la carpeta del proyecto al subirlo.

## Preparación en Windows

1. Copiar `config.example.json` como `config.json` y ajustar la configuración local, incluida la contraseña RCON antes de habilitar RCON.
2. Ejecutar `compilar.bat` para compilar `gamemodes/Gm venta.pwn` con el compilador incluido en `tools/pawn-3.10.10`.
3. Ejecutar `omp-server.exe` desde la raíz del proyecto.

La configuración de ejemplo selecciona `Gm venta 1` y el plugin `samp_bcrypt`. El gamemode crea automáticamente su base de datos en `scriptfiles/gm_venta.db`.

`mysql_login.example.ini` es una plantilla para las versiones históricas que usaban MySQL. El gamemode actual utiliza SQLite.

## Preparación en Linux

Se incluyen los binarios oficiales de **Pawn 3.10.10**, **open.mp 1.5.8.3079** y **samp-bcrypt 0.4.1**, todos para Linux x86 de 32 bits. La instalación de dependencias está preparada para Ubuntu/Debian en x86 o x86_64. Estos binarios no son nativos de ARM.

Desde una copia nueva del repositorio:

```bash
sudo bash tools/instalar-dependencias-linux.sh
cp config.example.json config.json
# Editar config.json para configurar el servidor y la contraseña RCON.
./compilar.sh
./iniciar.sh
```

No sobrescribas un `config.json` que ya hayas configurado. Ejecuta el servidor con tu usuario habitual. Para conexiones externas, el puerto configurado (7777 por defecto) debe estar accesible por UDP en el alojamiento.

El compilador usa `tools/pawnc-3.10.10-linux/lib/libpawnc.so` mediante `LD_LIBRARY_PATH` y conserva los flags y los includes utilizados en Windows. El ejecutable Linux es `omp-server`; los componentes y plugins Linux usan `.so`.

Git conserva los permisos de ejecución. Si transfieres los archivos por otro medio y pierdes esos permisos:

```bash
chmod +x omp-server compilar.sh iniciar.sh tools/*.sh tools/pawnc-3.10.10-linux/bin/*
```

### Pruebas Linux

```bash
./tools/probar-auth.sh
# Otro puerto local si 7778 está ocupado:
./tools/probar-auth.sh 7788
```

El script compila y arranca primero la GM real, comprueba que crea su base SQLite y luego ejecuta `tests/auth_security.pwn`. Usa carpetas y bases temporales, escucha en `127.0.0.1`, detiene sus propios procesos al terminar y conserva los logs para diagnóstico. No utiliza la configuración ni las cuentas del servidor local.

También verifica la carga de CEF y el empaquetado del recurso `auth`. La red adicional del componente escucha en puerto + 2; ejecutar las pruebas en una máquina aislada. CI prueba además la interfaz HTML en Chromium.

El workflow `.github/workflows/linux.yml` realiza estas comprobaciones en Ubuntu 22.04 en cada push a `main`, en pull requests y de forma manual desde GitHub Actions. Verifica además los SHA-256 de los binarios con `tools/linux-binaries.sha256`. Es una prueba de integración; no mantiene un servidor de juego desplegado.

### Procedencia de los binarios

Las URLs oficiales, versiones y hashes de los paquetes descargados están en `tools/linux-releases.json`. El hash de open.mp también se contrastó con el digest publicado por GitHub; los hashes de Pawn y bcrypt se calcularon tras descargar sus paquetes oficiales. El include de bcrypt y los includes `omp*.inc` coinciden con los del proyecto, por lo que se conservan los existentes.

- [Pawn 3.10.10](https://github.com/pawn-lang/compiler/releases/tag/v3.10.10)
- [open.mp 1.5.8.3079](https://github.com/openmultiplayer/open.mp/releases/tag/v1.5.8.3079)
- [samp-bcrypt 0.4.1](https://github.com/Sreyas-Sreelal/samp-bcrypt/releases/tag/0.4.1)
- [Guía oficial de instalación en Linux](https://open.mp/docs/server/LinuxServerInstallation)

## Archivos locales

Las configuraciones con credenciales, las bases de datos de jugadores, los bans, los logs y los diagnósticos de compilación se excluyen mediante `.gitignore`. Las configuraciones actuales y las de los backups tienen una copia `.example` sin contraseñas reales. Los originales permanecen en el equipo local.

La carpeta `docs/` mencionada en `AGENTS.md` no estaba presente al crear este repositorio. Antes de desarrollar funciones nuevas, se deben restaurar las fuentes de referencia que exige ese archivo.
