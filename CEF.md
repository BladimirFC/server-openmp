# Login y registro HTML con CEF

La GM usa **omp-cef 1.3.0** como componente nativo de open.mp. Incluye
`components/Cef.so` para Linux x86, `components/Cef.dll` para Windows x86 y
`qawno/include/cef.inc`. No se agrega CEF a `pawn.legacy_plugins`.
La procedencia, versión y SHA-256 están en `tools/cef/release.json` y
`tools/linux-binaries.sha256`; la licencia original se conserva en `tools/cef/LICENSE`.

## Preparar el servidor

1. Conservar la configuración existente. Si es una instalación nueva, copiar
   primero `config.example.json` a `config.json`.
2. Ejecutar `python3 tools/configurar-cef.py` (en Windows puede usarse `py`).
   Genera una clave de recursos si falta, desactiva la depuración de CEF y usa
   `cef.resources_loader_mode = "none"`, para mantener visible el acceso clásico
   durante la descarga. Conserva el resto de la configuración y nunca imprime
   sus credenciales. Puede recibir una ruta de configuración como argumento.
3. Compilar con `compilar.bat` en Windows, `./compilar.sh` en Linux compatible
   con i386, o `compilar64` tras activar el entorno Cloud.
4. Permitir **UDP en el puerto del servidor y en puerto + 2**. Para 7777 se
   necesitan 7777/UDP y 7779/UDP. El puerto principal debe ser como máximo 65533.
5. Reiniciar el servidor. Debe registrar `Component initialized (v1.3.0).`,
   el inicio de la red CEF y el empaquetado del recurso `auth`.

La pantalla está en `scriptfiles/cef/auth/`, con HTML, CSS y JavaScript locales.
Se registra con `CEF_AddResource("auth")` y se abre en
`http://cef/auth/index.html`. No necesita hosting web. Los `.pak` y manifests
generados son caché y están excluidos de Git. Reiniciar la GM después de cambiar
los recursos permite al componente actualizar el paquete.

## Preparar GTA en el PC de los jugadores

Descargar los archivos de cliente de la
[release oficial 1.3.0](https://github.com/aurora-mp/omp-cef/releases/tag/v1.3.0),
incluido `client-files-v1.3.0.zip`, y seguir la
[instalación oficial](https://github.com/aurora-mp/omp-cef/wiki/Installation-Client-side).
Se requiere un ASI loader y todos los archivos de la misma versión.

La estructura resultante debe ser:

```text
GTA San Andreas/
  gta_sa.exe
  cef.asi
  cef/
    client.dll
    renderer.exe
    libcef.dll
    icudtl.dat
    locales/
    resources/
    ...otros archivos del runtime de la release
```

Upstream declara soporte para SA-MP 0.3.7-R1, R3-1, R5-1 y 0.3.DL-R1 sobre
GTA para Windows. No se ha validado un cliente móvil con esta integración.

## Comportamiento y validación

El servidor decide la cuenta a partir del nombre del jugador y muestra registro
o login según SQLite. HTML envía únicamente la contraseña y los identificadores
de sesión/generación. El adaptador comprueba jugador, browser, sesión y estado,
y utiliza la misma autenticación bcrypt, migración SHA256, bloqueos y límites
de trabajos/IP que los diálogos originales. No se guardan contraseñas en la
página, en URLs, en almacenamiento del navegador ni en logs de la aplicación.

La interfaz CEF acepta caracteres ASCII imprimibles (32–126). El componente
convierte texto a ANSI en Windows y mantiene UTF-8 en Linux; esta restricción
evita que una contraseña cambie entre plataformas. Para contraseñas existentes
con otros caracteres, elegir **Acceso clásico**. Las reglas del diálogo clásico
se conservan.

Un cliente sin CEF conserva el diálogo clásico. Si el HTML no confirma que ha
cargado en ocho segundos, o falla la creación del browser, se vuelve al diálogo.
Al completar, cancelar o desconectar se limpian browser y temporizadores.
El límite global de autenticación sigue siendo dos minutos.

CI ejecuta open.mp y el componente real, comprueba el paquete HTML y prueba
SQLite/bcrypt. Las pruebas Pawn simulan los endpoints de renderizado para
comprobar eventos obsoletos, envíos duplicados, errores, reconexión y cierre.
`tools/probar-cef-ui.cjs` ejecuta el HTML en Chromium con un puente CEF simulado.
Estas pruebas no ejecutan GTA ni validan su renderizado, foco o transporte de
cliente. Antes del despliegue, comprobar desde GTA registro, reconexión/login,
contraseña incorrecta, acceso clásico, salida y recuperación del control tras
autenticarse, con los puertos UDP abiertos.

Para ejecutar la prueba de interfaz fuera de CI, instalar Playwright 1.62.1 y
su Chromium en una carpeta de herramientas, y ejecutar
`node tools/probar-cef-ui.cjs` con `NODE_PATH` apuntando a sus `node_modules`.
`CEF_TEST_CHROMIUM` permite seleccionar un Chromium instalado y
`CEF_TEST_SCREENSHOT` guardar una captura de vista previa.
