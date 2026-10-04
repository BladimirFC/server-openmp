/*
    Login y registro independientes para open.mp + MySQL R41-4.

    Conexion: mysql_login.ini, junto a omp-server.exe.
    Activacion: pawn.main_scripts = ["Gm venta 1"] en config.json.
    Requiere pawn.legacy_plugins = ["mysql"].

    Reutiliza accounts sin borrar ni modificar los otros sistemas de roleplay.
    Conserva SHA256 + nombre como salt para admitir las contrasenas existentes.
    Una migracion a bcrypt requiere otro formato de contrasena y su dependencia.
    Solo registra cuentas, autentica jugadores y los envia a un spawn fijo.
*/

#include <open.mp>
#include <a_mysql>

#define DIALOG_LOGIN             (1000)
#define DIALOG_REGISTER          (1001)
#define MAX_LOGIN_ATTEMPTS       (3)
#define MIN_PASSWORD_LENGTH      (4)
#define AUTH_TIMEOUT_MS          (120000)

#define SPAWN_SKIN               (16)
#define SPAWN_X                  (1163.6478)
#define SPAWN_Y                  (-2037.3270)
#define SPAWN_Z                  (69.0078)
#define SPAWN_A                  (269.2671)

#define COLOR_ERROR              (0xFF5555FF)
#define COLOR_SUCCESS            (0x33AA33FF)

enum E_AUTH_STATE
{
    AUTH_LOOKUP,
    AUTH_REGISTER,
    AUTH_CREATING,
    AUTH_LOGIN,
    AUTH_LOGGED_IN,
    AUTH_CLOSING
}

enum E_AUTH_DATA
{
    authAccountId,
    authName[MAX_PLAYER_NAME + 1], // Caracteres, incluido el terminador.
    authHash[65],                 // 64 caracteres SHA256 y el terminador.
    authAttempts,
    authTimer,
    E_AUTH_STATE:authState
}

new MySQL:g_SQL = MYSQL_INVALID_HANDLE;
new bool:g_DatabaseReady;
new g_Auth[MAX_PLAYERS][E_AUTH_DATA];
// Este contador no se reinicia al limpiar los datos del jugador.
new g_Session[MAX_PLAYERS];

forward OnAuthAccountLoaded(playerid, session);
forward OnAuthAccountCreated(playerid, session);
forward AuthTimeout(playerid, session);
forward AuthKick(playerid, session);

stock bool:IsCurrentSession(playerid, session)
{
    return playerid >= 0 && playerid < MAX_PLAYERS && IsPlayerConnected(playerid)
        && !IsPlayerNPC(playerid) && g_Session[playerid] == session;
}

main() {}

public OnGameModeInit()
{
    SetGameModeText("Login / Registro");
    AddPlayerClass(SPAWN_SKIN, SPAWN_X, SPAWN_Y, SPAWN_Z, SPAWN_A,
        WEAPON_FIST, 0, WEAPON_FIST, 0, WEAPON_FIST, 0);
    DisableInteriorEnterExits();
    EnableStuntBonusForAll(false);
    UsePlayerPedAnims();

    g_SQL = mysql_connect_file("mysql_login.ini");
    if (g_SQL == MYSQL_INVALID_HANDLE || mysql_errno(g_SQL) != 0)
    {
        print("[Auth] No se pudo conectar a MySQL. Revisa mysql_login.ini.");
        return 1;
    }

    if (!mysql_set_charset("utf8mb4", g_SQL))
    {
        print("[Auth] No se pudo configurar el juego de caracteres de MySQL.");
        return 1;
    }

    // Una unica consulta sincrona al arrancar: no admitir logins antes del esquema.
    // Si accounts ya existe, conserva todas sus columnas y sus registros.
    mysql_query(g_SQL,
        "CREATE TABLE IF NOT EXISTS `accounts` (\
        `id` INT NOT NULL AUTO_INCREMENT PRIMARY KEY,\
        `username` VARCHAR(24) NOT NULL UNIQUE,\
        `password` VARCHAR(65) NOT NULL,\
        `ip` VARCHAR(45) NOT NULL DEFAULT '',\
        `registered_at` DATETIME DEFAULT CURRENT_TIMESTAMP,\
        `last_login` DATETIME DEFAULT CURRENT_TIMESTAMP\
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4", false);

    if (mysql_errno(g_SQL) != 0)
    {
        print("[Auth] No se pudo preparar accounts. Consulta el log de MySQL.");
        return 1;
    }

    g_DatabaseReady = true;
    print("[Auth] Login y registro preparados.");
    return 1;
}

public OnGameModeExit()
{
    g_DatabaseReady = false;
    new players[MAX_PLAYERS]; // IDs de jugadores conectados, no texto.
    new count = GetPlayers(players);
    for (new index = 0; index < count; index++)
    {
        new playerid = players[index];
        StopAuthTimer(playerid);
        g_Session[playerid]++;
    }
    if (g_SQL != MYSQL_INVALID_HANDLE)
    {
        mysql_close(g_SQL);
        g_SQL = MYSQL_INVALID_HANDLE;
    }
    return 1;
}

public OnPlayerConnect(playerid)
{
    StopAuthTimer(playerid);
    static const emptyAuth[E_AUTH_DATA];
    g_Auth[playerid] = emptyAuth;
    g_Session[playerid]++;
    if (IsPlayerNPC(playerid)) return 1;

    TogglePlayerSpectating(playerid, true);
    SetPlayerCameraPos(playerid, 1480.0, -2150.0, 150.0);
    SetPlayerCameraLookAt(playerid, 1480.0, -1770.0, 15.0);
    GetPlayerName(playerid, g_Auth[playerid][authName], MAX_PLAYER_NAME + 1);

    if (!g_DatabaseReady)
        return CloseAuth(playerid, "El sistema de cuentas no esta disponible.");

    g_Auth[playerid][authTimer] = SetTimerEx("AuthTimeout", AUTH_TIMEOUT_MS,
        false, "ii", playerid, g_Session[playerid]);

    new query[256]; // Caracteres; incluye el nombre escapado para SQL.
    mysql_format(g_SQL, query, sizeof query,
        "SELECT `id`, `username`, `password` FROM `accounts` WHERE `username` = '%e' LIMIT 1",
        g_Auth[playerid][authName]);
    if (!mysql_tquery(g_SQL, query, "OnAuthAccountLoaded", "ii", playerid, g_Session[playerid]))
        return CloseAuth(playerid, "No se pudo consultar tu cuenta. Intenta mas tarde.");
    return 1;
}

public OnPlayerDisconnect(playerid, reason)
{
    StopAuthTimer(playerid);
    g_Session[playerid]++;
    static const emptyAuth[E_AUTH_DATA];
    g_Auth[playerid] = emptyAuth;
    return 1;
}

public OnAuthAccountLoaded(playerid, session)
{
    if (!IsCurrentSession(playerid, session) || !g_DatabaseReady) return 1;
    if (g_Auth[playerid][authState] != AUTH_LOOKUP) return 1;

    if (cache_num_rows() == 0)
    {
        g_Auth[playerid][authState] = AUTH_REGISTER;
    }
    else
    {
        cache_get_value_name_int(0, "id", g_Auth[playerid][authAccountId]);
        cache_get_value_name(0, "username", g_Auth[playerid][authName], MAX_PLAYER_NAME + 1);
        cache_get_value_name(0, "password", g_Auth[playerid][authHash], 65);
        if (g_Auth[playerid][authAccountId] <= 0 || strlen(g_Auth[playerid][authHash]) != 64)
            return CloseAuth(playerid, "No se pudo cargar tu cuenta. Contacta con administracion.");
        g_Auth[playerid][authState] = AUTH_LOGIN;
    }
    ShowAuthDialog(playerid);
    return 1;
}

public OnDialogResponse(playerid, dialogid, response, listitem, inputtext[])
{
    if (dialogid != DIALOG_LOGIN && dialogid != DIALOG_REGISTER) return 0;
    if (IsPlayerNPC(playerid)) return 1;

    // Ignorar respuestas repetidas o que no corresponden al estado actual.
    if (dialogid == DIALOG_REGISTER && g_Auth[playerid][authState] != AUTH_REGISTER) return 1;
    if (dialogid == DIALOG_LOGIN && g_Auth[playerid][authState] != AUTH_LOGIN) return 1;
    if (!response) return CloseAuth(playerid, "Has cancelado el acceso al servidor.");
    if (!g_DatabaseReady) return CloseAuth(playerid, "El sistema de cuentas no esta disponible.");

    if (dialogid == DIALOG_REGISTER)
    {
        if (strlen(inputtext) < MIN_PASSWORD_LENGTH)
        {
            SendClientMessage(playerid, COLOR_ERROR, "La contrasena debe tener al menos 4 caracteres.");
            ShowAuthDialog(playerid);
            return 1;
        }

        new hash[65], ip[46]; // Caracteres, incluidos sus terminadores.
        SHA256_Hash(inputtext, g_Auth[playerid][authName], hash, sizeof hash);
        GetPlayerIp(playerid, ip, sizeof ip);
        new query[512]; // Caracteres; reserva para nombre, hash e IP escapados.
        mysql_format(g_SQL, query, sizeof query,
            "INSERT INTO `accounts` (`username`, `password`, `ip`) VALUES ('%e', '%e', '%e')",
            g_Auth[playerid][authName], hash, ip);

        g_Auth[playerid][authState] = AUTH_CREATING;
        if (!mysql_tquery(g_SQL, query, "OnAuthAccountCreated", "ii", playerid, g_Session[playerid]))
            return CloseAuth(playerid, "No se pudo registrar la cuenta. Intenta mas tarde.");
        return 1;
    }

    new hash[65]; // 64 caracteres SHA256 y el terminador.
    SHA256_Hash(inputtext, g_Auth[playerid][authName], hash, sizeof hash);
    if (strcmp(hash, g_Auth[playerid][authHash], false) != 0)
    {
        g_Auth[playerid][authAttempts]++;
        if (g_Auth[playerid][authAttempts] >= MAX_LOGIN_ATTEMPTS)
            return CloseAuth(playerid, "Demasiados intentos de inicio de sesion.");
        SendClientMessage(playerid, COLOR_ERROR, "Contrasena incorrecta. Intenta de nuevo.");
        ShowAuthDialog(playerid);
        return 1;
    }

    return CompleteAuth(playerid, false);
}

public OnAuthAccountCreated(playerid, session)
{
    if (!IsCurrentSession(playerid, session) || !g_DatabaseReady) return 1;
    if (g_Auth[playerid][authState] != AUTH_CREATING) return 1;
    new accountId = cache_insert_id();
    if (accountId <= 0)
        return CloseAuth(playerid, "No se pudo registrar la cuenta. Intenta mas tarde.");
    g_Auth[playerid][authAccountId] = accountId;
    return CompleteAuth(playerid, true);
}

public OnPlayerRequestSpawn(playerid)
{
    return IsPlayerNPC(playerid) || g_Auth[playerid][authState] == AUTH_LOGGED_IN;
}

public OnPlayerSpawn(playerid)
{
    if (IsPlayerNPC(playerid)) return 1;
    if (g_Auth[playerid][authState] != AUTH_LOGGED_IN)
    {
        TogglePlayerSpectating(playerid, true);
        return 1;
    }
    SetPlayerInterior(playerid, 0);
    SetPlayerVirtualWorld(playerid, 0);
    SetPlayerPos(playerid, SPAWN_X, SPAWN_Y, SPAWN_Z);
    SetPlayerFacingAngle(playerid, SPAWN_A);
    SetPlayerHealth(playerid, 100.0);
    SetPlayerArmour(playerid, 0.0);
    SetPlayerSkin(playerid, SPAWN_SKIN);
    SetCameraBehindPlayer(playerid);
    return 1;
}

public OnPlayerText(playerid, text[])
{
    return g_Auth[playerid][authState] == AUTH_LOGGED_IN;
}

public OnPlayerCommandText(playerid, cmdtext[])
{
    if (g_Auth[playerid][authState] != AUTH_LOGGED_IN)
    {
        SendClientMessage(playerid, COLOR_ERROR, "Debes iniciar sesion primero.");
        return 1;
    }
    return 0;
}

public AuthTimeout(playerid, session)
{
    if (!IsCurrentSession(playerid, session)) return 1;
    g_Auth[playerid][authTimer] = 0;
    if (g_Auth[playerid][authState] == AUTH_LOGGED_IN) return 1;
    return CloseAuth(playerid, "Se agoto el tiempo para iniciar sesion o registrarte.");
}

public AuthKick(playerid, session)
{
    if (!IsCurrentSession(playerid, session)) return 1;
    g_Auth[playerid][authTimer] = 0;
    if (g_Auth[playerid][authState] == AUTH_CLOSING) Kick(playerid);
    return 1;
}

stock StopAuthTimer(playerid)
{
    if (g_Auth[playerid][authTimer] != 0)
    {
        KillTimer(g_Auth[playerid][authTimer]);
        g_Auth[playerid][authTimer] = 0;
    }
}

stock CloseAuth(playerid, const message[])
{
    g_Auth[playerid][authState] = AUTH_CLOSING;
    g_Auth[playerid][authHash][0] = EOS;
    StopAuthTimer(playerid);
    SendClientMessage(playerid, COLOR_ERROR, message);
    g_Auth[playerid][authTimer] = SetTimerEx("AuthKick", 500, false,
        "ii", playerid, g_Session[playerid]);
    return 1;
}

stock ShowAuthDialog(playerid)
{
    new title[64]; // Caracteres; texto del titulo y nombre de hasta 24 caracteres.
    if (g_Auth[playerid][authState] == AUTH_REGISTER)
    {
        format(title, sizeof title, "Registro - %s", g_Auth[playerid][authName]);
        ShowPlayerDialog(playerid, DIALOG_REGISTER, DIALOG_STYLE_PASSWORD, title,
            "Ingresa una contrasena para registrarte (minimo 4 caracteres):", "Registrarse", "Salir");
    }
    else if (g_Auth[playerid][authState] == AUTH_LOGIN)
    {
        format(title, sizeof title, "Login - %s", g_Auth[playerid][authName]);
        ShowPlayerDialog(playerid, DIALOG_LOGIN, DIALOG_STYLE_PASSWORD, title,
            "Ingresa tu contrasena:", "Ingresar", "Salir");
    }
}

stock CompleteAuth(playerid, bool:registered)
{
    new players[MAX_PLAYERS]; // IDs de jugadores conectados, no texto.
    new count = GetPlayers(players);
    for (new index = 0; index < count; index++)
    {
        new other = players[index];
        if (other == playerid || g_Auth[other][authState] != AUTH_LOGGED_IN) continue;
        if (g_Auth[other][authAccountId] == g_Auth[playerid][authAccountId])
            return CloseAuth(playerid, "Esta cuenta ya esta conectada en el servidor.");
    }

    StopAuthTimer(playerid);
    g_Auth[playerid][authState] = AUTH_LOGGED_IN;
    g_Auth[playerid][authHash][0] = EOS;

    new ip[46], query[256]; // Caracteres; IP y consulta de actividad de la cuenta.
    GetPlayerIp(playerid, ip, sizeof ip);
    mysql_format(g_SQL, query, sizeof query,
        "UPDATE `accounts` SET `ip` = '%e', `last_login` = CURRENT_TIMESTAMP WHERE `id` = %d",
        ip, g_Auth[playerid][authAccountId]);
    mysql_tquery(g_SQL, query);

    SetSpawnInfo(playerid, NO_TEAM, SPAWN_SKIN, SPAWN_X, SPAWN_Y, SPAWN_Z, SPAWN_A,
        WEAPON_FIST, 0, WEAPON_FIST, 0, WEAPON_FIST, 0);
    // open.mp genera OnPlayerSpawn al desactivar el modo espectador.
    TogglePlayerSpectating(playerid, false);
    SendClientMessage(playerid, COLOR_SUCCESS, registered
        ? "Cuenta registrada. Bienvenido al servidor!"
        : "Has iniciado sesion. Bienvenido de vuelta!");
    return 1;
}
