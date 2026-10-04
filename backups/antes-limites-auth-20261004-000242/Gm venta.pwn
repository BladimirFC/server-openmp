/*
    Gm venta: login y registro independientes para open.mp + SQLite local.

    Cuentas nuevas: scriptfiles/gm_venta.db, creada automaticamente.
    Activacion: pawn.main_scripts = ["Gm venta 1"] en config.json.
    Requiere el plugin samp_bcrypt en pawn.legacy_plugins.

    Contraseñas nuevas con bcrypt; SHA256 anterior se migra al iniciar sesion.
    Tres fallos bloquean la cuenta cinco minutos, incluso tras reconectar.
    Solo registra cuentas, autentica jugadores y los envia a un spawn fijo.
*/

#include <open.mp>
#include <samp_bcrypt>

#if !defined AUTH_DATABASE_FILE
    #define AUTH_DATABASE_FILE "gm_venta.db"
#endif

#define DIALOG_LOGIN             (1000)
#define DIALOG_REGISTER          (1001)
#define MAX_LOGIN_ATTEMPTS       (3)
#define MIN_PASSWORD_LENGTH      (8)
#define MAX_PASSWORD_LENGTH      (72)
#define LOGIN_LOCK_SECONDS       (300)
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
    AUTH_VERIFYING,
    AUTH_UPGRADING,
    AUTH_LOGGED_IN,
    AUTH_CLOSING
}

enum E_AUTH_DATA
{
    authAccountId,
    authName[MAX_PLAYER_NAME + 1], // Caracteres, incluido el terminador.
    authHash[65],                 // Bcrypt (60) o SHA256 anterior (64), mas terminador.
    authTimer,
    E_AUTH_STATE:authState
}

new DB:g_SQL;
new bool:g_DatabaseReady;
new g_Auth[MAX_PLAYERS][E_AUTH_DATA];
// Este contador no se reinicia al limpiar los datos del jugador.
new g_Session[MAX_PLAYERS];

forward AuthTimeout(playerid, session);
forward AuthKick(playerid, session);
forward OnAuthPasswordHashed(playerid, session, bool:registered);
forward OnAuthPasswordVerified(playerid, bool:success, session, accountId);

stock bool:IsBcryptHash(const hash[])
{
    if (strlen(hash) != 60 || hash[0] != '$' || hash[1] != '2'
        || (hash[2] != 'a' && hash[2] != 'b' && hash[2] != 'y')
        || hash[3] != '$' || hash[6] != '$'
        || hash[4] < '0' || hash[4] > '9' || hash[5] < '0' || hash[5] > '9') return false;
    new cost = strval(hash[4]);
    if (cost < 4 || cost > 31) return false;
    for (new index = 7; index < 60; index++)
    {
        new character = hash[index];
        if ((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')
            || (character >= '0' && character <= '9') || character == '.' || character == '/') continue;
        return false;
    }
    return true;
}

stock bool:IsLegacyHash(const hash[])
{
    if (strlen(hash) != 64) return false;
    for (new index = 0; index < 64; index++)
    {
        new character = hash[index];
        if ((character >= '0' && character <= '9') || (character >= 'A' && character <= 'F')
            || (character >= 'a' && character <= 'f')) continue;
        return false;
    }
    return true;
}

stock bool:IsValidNewPassword(const password[])
{
    new length = strlen(password);
    return length >= MIN_PASSWORD_LENGTH && length <= MAX_PASSWORD_LENGTH;
}

stock bool:IsCurrentSession(playerid, session)
{
    return playerid >= 0 && playerid < MAX_PLAYERS && IsPlayerConnected(playerid)
        && !IsPlayerNPC(playerid) && g_Session[playerid] == session;
}

stock bool:OpenAuthDatabase()
{
    g_SQL = DB_Open(AUTH_DATABASE_FILE);
    if (g_SQL == DB:0)
    {
        print("[Auth] No se pudo abrir la base local. Revisa permisos de scriptfiles.");
        return false;
    }

    new DBResult:result = DB_ExecuteQuery(g_SQL,
        "CREATE TABLE IF NOT EXISTS `accounts` (\
        `id` INTEGER PRIMARY KEY AUTOINCREMENT,\
        `username` TEXT NOT NULL COLLATE NOCASE UNIQUE,\
        `password` TEXT NOT NULL,\
        `ip` TEXT NOT NULL DEFAULT '',\
        `registered_at` TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,\
        `last_login` TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)");
    if (result == DBResult:0)
    {
        print("[Auth] No se pudo preparar la tabla accounts de la base local.");
        DB_Close(g_SQL);
        g_SQL = DB:0;
        return false;
    }
    DB_FreeResultSet(result);
    result = DB_ExecuteQuery(g_SQL,
        "CREATE TABLE IF NOT EXISTS `auth_limits` (\
        `account_id` INTEGER PRIMARY KEY,\
        `failures` INTEGER NOT NULL DEFAULT 0,\
        `locked_until` INTEGER NOT NULL DEFAULT 0)");
    if (result == DBResult:0)
    {
        print("[Auth] No se pudo preparar la proteccion de intentos.");
        DB_Close(g_SQL);
        g_SQL = DB:0;
        return false;
    }
    DB_FreeResultSet(result);
    return true;
}

stock bool:LoadAuthAccount(playerid)
{
    if (g_SQL == DB:0) return false;
    new query[256]; // Caracteres; incluye nombre escapado para SQLite.
    format(query, sizeof query,
        "SELECT `id`, `username`, `password` FROM `accounts` WHERE `username` = '%q' LIMIT 1",
        g_Auth[playerid][authName]);
    new DBResult:result = DB_ExecuteQuery(g_SQL, query);
    if (result == DBResult:0) return false;

    if (DB_GetRowCount(result) == 0)
    {
        g_Auth[playerid][authState] = AUTH_REGISTER;
        g_Auth[playerid][authAccountId] = 0;
        g_Auth[playerid][authHash][0] = EOS;
        DB_FreeResultSet(result);
        return true;
    }

    g_Auth[playerid][authAccountId] = DB_GetFieldIntByName(result, "id");
    // Recuperar la escritura original del nombre para verificar el mismo salt.
    new bool:loadedName = DB_GetFieldStringByName(result, "username", g_Auth[playerid][authName], MAX_PLAYER_NAME + 1);
    new bool:loadedHash = DB_GetFieldStringByName(result, "password", g_Auth[playerid][authHash], 65);
    DB_FreeResultSet(result);
    if (!loadedName || !loadedHash || g_Auth[playerid][authAccountId] <= 0
        || (!IsBcryptHash(g_Auth[playerid][authHash]) && !IsLegacyHash(g_Auth[playerid][authHash])))
        return false;
    g_Auth[playerid][authState] = AUTH_LOGIN;
    return true;
}

stock bool:CreateAuthAccount(playerid, const hash[], const ip[])
{
    if (g_SQL == DB:0 || !IsBcryptHash(hash)) return false;
    new query[512]; // Caracteres; nombre, hash e IP escapados para SQLite.
    format(query, sizeof query,
        "INSERT INTO `accounts` (`username`, `password`, `ip`) VALUES ('%q', '%q', '%q')",
        g_Auth[playerid][authName], hash, ip);
    new DBResult:result = DB_ExecuteQuery(g_SQL, query);
    if (result == DBResult:0) return false;
    DB_FreeResultSet(result);
    return LoadAuthAccount(playerid) && g_Auth[playerid][authState] == AUTH_LOGIN;
}

stock bool:UpdateAuthActivity(accountId, const ip[])
{
    if (g_SQL == DB:0 || accountId <= 0) return false;
    new query[256]; // Caracteres; consulta con IP escapada para SQLite.
    format(query, sizeof query,
        "UPDATE `accounts` SET `ip` = '%q', `last_login` = CURRENT_TIMESTAMP WHERE `id` = %d",
        ip, accountId);
    new DBResult:result = DB_ExecuteQuery(g_SQL, query);
    if (result == DBResult:0) return false;
    DB_FreeResultSet(result);
    return true;
}

stock bool:ExecuteAuthQuery(const query[])
{
    if (g_SQL == DB:0) return false;
    new DBResult:result = DB_ExecuteQuery(g_SQL, query);
    if (result == DBResult:0) return false;
    DB_FreeResultSet(result);
    return true;
}

stock bool:GetAuthLimit(accountId, &failures, &lockedUntil)
{
    failures = 0;
    lockedUntil = 0;
    if (g_SQL == DB:0 || accountId <= 0) return false;
    new query[256]; // Caracteres; vencimiento y consulta de limite de cuenta.
    format(query, sizeof query,
        "DELETE FROM `auth_limits` WHERE `account_id` = %d AND `locked_until` > 0 AND `locked_until` <= %d",
        accountId, gettime());
    if (!ExecuteAuthQuery(query)) return false;
    format(query, sizeof query,
        "SELECT `failures`, `locked_until` FROM `auth_limits` WHERE `account_id` = %d", accountId);
    new DBResult:result = DB_ExecuteQuery(g_SQL, query);
    if (result == DBResult:0) return false;
    if (DB_GetRowCount(result) > 0)
    {
        failures = DB_GetFieldIntByName(result, "failures");
        lockedUntil = DB_GetFieldIntByName(result, "locked_until");
    }
    DB_FreeResultSet(result);
    return true;
}

stock bool:RecordAuthFailure(accountId)
{
    new failures, lockedUntil;
    if (!GetAuthLimit(accountId, failures, lockedUntil)) return false;
    if (lockedUntil > gettime()) return true;
    new query[384]; // Caracteres; contador y fecha de desbloqueo persistentes.
    format(query, sizeof query, "INSERT OR IGNORE INTO `auth_limits` (`account_id`) VALUES (%d)", accountId);
    if (!ExecuteAuthQuery(query)) return false;
    format(query, sizeof query,
        "UPDATE `auth_limits` SET `failures` = `failures` + 1,\
        `locked_until` = CASE WHEN `failures` + 1 >= %d THEN %d ELSE 0 END WHERE `account_id` = %d",
        MAX_LOGIN_ATTEMPTS, gettime() + LOGIN_LOCK_SECONDS, accountId);
    return ExecuteAuthQuery(query);
}

stock bool:ClearAuthFailures(accountId)
{
    if (accountId <= 0) return false;
    new query[128]; // Caracteres; borrar limite tras autenticacion correcta.
    format(query, sizeof query, "DELETE FROM `auth_limits` WHERE `account_id` = %d", accountId);
    return ExecuteAuthQuery(query);
}

stock bool:UpgradeAuthPassword(accountId, const hash[])
{
    if (accountId <= 0 || !IsBcryptHash(hash)) return false;
    new query[256]; // Caracteres; guardar el nuevo hash bcrypt de la cuenta.
    format(query, sizeof query,
        "UPDATE `accounts` SET `password` = '%q' WHERE `id` = %d", hash, accountId);
    return ExecuteAuthQuery(query);
}

stock bool:CheckAuthAccess(playerid)
{
    new failures, lockedUntil;
    if (!GetAuthLimit(g_Auth[playerid][authAccountId], failures, lockedUntil))
    {
        CloseAuth(playerid, "No se pudo comprobar el acceso. Intenta mas tarde.");
        return false;
    }
    if (lockedUntil > gettime())
    {
        new message[128]; // Caracteres; motivo y segundos restantes de bloqueo.
        format(message, sizeof message, "Cuenta bloqueada temporalmente. Intenta de nuevo en %d segundos.", lockedUntil - gettime());
        CloseAuth(playerid, message);
        return false;
    }
    return true;
}

main() {}

public OnGameModeInit()
{
    SetGameModeText("Gm venta - Login / Registro");
    AddPlayerClass(SPAWN_SKIN, SPAWN_X, SPAWN_Y, SPAWN_Z, SPAWN_A,
        WEAPON_FIST, 0, WEAPON_FIST, 0, WEAPON_FIST, 0);
    DisableInteriorEnterExits();
    EnableStuntBonusForAll(false);
    UsePlayerPedAnims();
    bcrypt_set_thread_limit(2);

    g_DatabaseReady = OpenAuthDatabase();
    if (g_DatabaseReady)
        print("[Auth] Login y registro preparados. Base local: scriptfiles/" AUTH_DATABASE_FILE);
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
    if (g_SQL != DB:0)
    {
        DB_Close(g_SQL);
        g_SQL = DB:0;
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

    if (!LoadAuthAccount(playerid))
        return CloseAuth(playerid, "No se pudo consultar tu cuenta. Intenta mas tarde.");
    if (g_Auth[playerid][authState] == AUTH_LOGIN && !CheckAuthAccess(playerid)) return 1;
    ShowAuthDialog(playerid);
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
        if (!IsValidNewPassword(inputtext))
        {
            SendClientMessage(playerid, COLOR_ERROR, "La contrasena debe tener entre 8 y 72 caracteres.");
            ShowAuthDialog(playerid);
            return 1;
        }

        g_Auth[playerid][authState] = AUTH_CREATING;
        if (!bcrypt_hash(playerid, "OnAuthPasswordHashed", inputtext, BCRYPT_COST,
            "ii", g_Session[playerid], _:true))
            return CloseAuth(playerid, "No se pudo proteger la contrasena. Intenta mas tarde.");
        return 1;
    }

    if (!CheckAuthAccess(playerid)) return 1;
    if (strlen(inputtext) > MAX_PASSWORD_LENGTH)
    {
        SendClientMessage(playerid, COLOR_ERROR, "La contrasena no puede superar 72 caracteres.");
        ShowAuthDialog(playerid);
        return 1;
    }

    g_Auth[playerid][authState] = AUTH_VERIFYING;
    if (IsLegacyHash(g_Auth[playerid][authHash]))
    {
        // Solo para convertir cuentas anteriores: ningun registro nuevo usa SHA256.
        new legacyHash[65]; // Caracteres; SHA256 anterior y terminador.
        SHA256_Hash(inputtext, g_Auth[playerid][authName], legacyHash, sizeof legacyHash);
        if (strcmp(legacyHash, g_Auth[playerid][authHash], true) != 0)
            return OnAuthPasswordVerified(playerid, false, g_Session[playerid], g_Auth[playerid][authAccountId]);
        g_Auth[playerid][authState] = AUTH_UPGRADING;
        if (!bcrypt_hash(playerid, "OnAuthPasswordHashed", inputtext, BCRYPT_COST,
            "ii", g_Session[playerid], _:false))
            return CloseAuth(playerid, "No se pudo actualizar la proteccion de tu cuenta.");
        return 1;
    }

    if (!bcrypt_verify(playerid, "OnAuthPasswordVerified", inputtext, g_Auth[playerid][authHash],
        "ii", g_Session[playerid], g_Auth[playerid][authAccountId]))
        return CloseAuth(playerid, "No se pudo verificar la contrasena. Intenta mas tarde.");
    return 1;
}

public OnAuthPasswordHashed(playerid, session, bool:registered)
{
    if (!IsCurrentSession(playerid, session) || !g_DatabaseReady) return 1;
    if (registered && g_Auth[playerid][authState] != AUTH_CREATING) return 1;
    if (!registered && g_Auth[playerid][authState] != AUTH_UPGRADING) return 1;
    new hash[BCRYPT_HASH_LENGTH]; // Caracteres; bcrypt y terminador.
    if (!bcrypt_get_hash(hash, sizeof hash) || !IsBcryptHash(hash))
        return CloseAuth(playerid, "No se pudo proteger la contrasena. Intenta mas tarde.");
    if (registered)
    {
        new ip[46]; // Caracteres; IP y terminador.
        GetPlayerIp(playerid, ip, sizeof ip);
        if (!CreateAuthAccount(playerid, hash, ip))
            return CloseAuth(playerid, "No se pudo registrar la cuenta. Intenta mas tarde.");
    }
    else
    {
        if (!CheckAuthAccess(playerid)) return 1;
        if (!UpgradeAuthPassword(g_Auth[playerid][authAccountId], hash))
            return CloseAuth(playerid, "No se pudo actualizar la proteccion de tu cuenta.");
    }
    return CompleteAuth(playerid, registered);
}

public OnAuthPasswordVerified(playerid, bool:success, session, accountId)
{
    if (!g_DatabaseReady) return 1;
    // Guardar tambien los fallos que terminan despues de una desconexion.
    new bool:failureSaved = true;
    if (!success) failureSaved = RecordAuthFailure(accountId);
    if (!IsCurrentSession(playerid, session)) return 1;
    if (g_Auth[playerid][authState] != AUTH_VERIFYING || g_Auth[playerid][authAccountId] != accountId) return 1;
    if (!failureSaved)
        return CloseAuth(playerid, "No se pudo guardar el intento. Intenta mas tarde.");
    if (!CheckAuthAccess(playerid)) return 1;
    if (!success)
    {
        g_Auth[playerid][authState] = AUTH_LOGIN;
        SendClientMessage(playerid, COLOR_ERROR, "Contrasena incorrecta. Intenta de nuevo.");
        ShowAuthDialog(playerid);
        return 1;
    }
    return CompleteAuth(playerid, false);
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
            "Ingresa una contrasena para registrarte (entre 8 y 72 caracteres):", "Registrarse", "Salir");
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

    new ip[46]; // Caracteres; IP y terminador.
    GetPlayerIp(playerid, ip, sizeof ip);
    if (!UpdateAuthActivity(g_Auth[playerid][authAccountId], ip)
        || !ClearAuthFailures(g_Auth[playerid][authAccountId]))
        return CloseAuth(playerid, "No se pudo guardar el acceso. Intenta mas tarde.");

    StopAuthTimer(playerid);
    g_Auth[playerid][authState] = AUTH_LOGGED_IN;
    g_Auth[playerid][authHash][0] = EOS;

    SetSpawnInfo(playerid, NO_TEAM, SPAWN_SKIN, SPAWN_X, SPAWN_Y, SPAWN_Z, SPAWN_A,
        WEAPON_FIST, 0, WEAPON_FIST, 0, WEAPON_FIST, 0);
    // open.mp genera OnPlayerSpawn al desactivar el modo espectador.
    TogglePlayerSpectating(playerid, false);
    SendClientMessage(playerid, COLOR_SUCCESS, registered
        ? "Cuenta registrada. Bienvenido al servidor!"
        : "Has iniciado sesion. Bienvenido de vuelta!");
    return 1;
}

