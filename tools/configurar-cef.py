"""Configura solo CEF en un config.json existente; nunca imprime credenciales."""
import json
import os
from pathlib import Path
import secrets
import sys
import tempfile

config_path = Path(sys.argv[1]) if len(sys.argv) == 2 else Path(__file__).resolve().parent.parent / "config.json"
if len(sys.argv) > 2:
    sys.exit("Uso: python3 tools/configurar-cef.py [config.json]")
if not config_path.is_file():
    sys.exit("Falta config.json. Copia config.example.json antes de configurar CEF.")
config = json.loads(config_path.read_text(encoding="utf-8-sig"))
cef = config.setdefault("cef", {})
if not isinstance(cef, dict):
    sys.exit("La seccion cef debe ser un objeto JSON; no se ha modificado la configuracion.")
key = cef.get("master_resource_key")
if key is None or key == "ThisIsA16ByteKey":
    cef["master_resource_key"] = secrets.token_hex(16)
elif not isinstance(key, str) or len(key.encode("utf-8")) not in (16, 24, 32):
    sys.exit("La clave CEF existente debe tener 16, 24 o 32 bytes; no se ha modificado la configuracion.")
cef["debug"] = False
cef["resources_loader_mode"] = "none"
fd, temporary = tempfile.mkstemp(prefix=".cef-config-", dir=config_path.parent)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(config, output, ensure_ascii=False, indent=4)
        output.write("\n")
    os.chmod(temporary, config_path.stat().st_mode & 0o777)
    os.replace(temporary, config_path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print("CEF configurado: depuracion desactivada y acceso clasico disponible durante la descarga.")
