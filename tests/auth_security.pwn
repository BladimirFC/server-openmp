#include <open.mp>
#include <cef>
new testCefCreates, testCefDestroys, testCefStates;
stock TestCefCreate(playerid, browserid, const url[], bool:focused, bool:controls_chat)
{
    #pragma unused playerid, browserid, url, focused, controls_chat
    testCefCreates++;
    return 1;
}
stock TestCefDestroy(playerid, browserid)
{
    #pragma unused playerid, browserid
    testCefDestroys++;
    return 1;
}
stock TestCefFocus(playerid, browserid, bool:focused)
{
    #pragma unused playerid, browserid, focused
    return 1;
}
stock TestCefChat(playerid, bool:enabled)
{
    #pragma unused playerid, enabled
    return 1;
}
stock TestCefEmit(playerid, browserid, const event[], {E_CEF_ARGUMENT_TYPE, Float, _}:...)
{
    #pragma unused playerid, browserid, event
    testCefStates++;
    return 1;
}
stock bool:TestHideDialog(playerid)
{
    #pragma unused playerid
    return true;
}
#define CEF_CreateBrowser TestCefCreate
#define CEF_DestroyBrowser TestCefDestroy
#define CEF_FocusBrowser TestCefFocus
#define CEF_ToggleChatInput TestCefChat
#define CEF_EmitEvent TestCefEmit
#define HidePlayerDialog TestHideDialog
new bool:testConnected[MAX_PLAYERS];
stock bool:TestIsPlayerConnected(playerid) { return playerid >= 0 && playerid < MAX_PLAYERS && testConnected[playerid]; }
stock bool:TestIsPlayerNPC(playerid) {
    #pragma unused playerid
    return false;
}
new bool:testSharedIP;
stock TestGetPlayerIp(playerid, ip[], len)
{
    if (testSharedIP) format(ip, len, "198.51.100.1");
    else format(ip, len, "192.0.2.%d", playerid + 1);
    return 1;
}
#define GetPlayerIp TestGetPlayerIp
#define AUTH_DATABASE_FILE "secure_test.db"
#define main GmVentaMain
#define OnGameModeInit GmVentaOnGameModeInit
#define IsPlayerConnected TestIsPlayerConnected
#define IsPlayerNPC TestIsPlayerNPC
#define OnAuthPasswordHashed CoreAuthPasswordHashed
#define OnAuthPasswordVerified CoreAuthPasswordVerified
forward GmVentaOnGameModeInit();
#include "../gamemodes/Gm venta.pwn"
#undef main
#undef OnGameModeInit
#undef IsPlayerConnected
#undef IsPlayerNPC
#undef GetPlayerIp
#undef OnAuthPasswordHashed
#undef OnAuthPasswordVerified

new testFailures, testChecks, testAccountId, testStage, testTicks;
new bool:testStaleHashSeen, bool:testStaleVerifySeen;
forward RunSecureStage();
forward OnAuthPasswordHashed(playerid, session, bool:registered, epoch, jobId);
forward OnAuthPasswordVerified(playerid, bool:success, session, accountId, epoch, jobId);
main() { GmVentaMain(); }
stock Check(bool:ok, const label[])
{
    testChecks++;
    printf("[TEST] %s: %s", ok ? "PASS" : "FAIL", label);
    if (!ok) testFailures++;
}
stock SubmitTestDialog(playerid, dialogid, const password[])
{
    new input[145];
    format(input, sizeof input, "%s", password);
    return OnDialogResponse(playerid, dialogid, true, 0, input);
}
stock SetTestPlayer(playerid, const name[])
{
    OnPlayerDisconnect(playerid, 1);
    testConnected[playerid] = true;
    g_Session[playerid]++;
    format(g_Auth[playerid][authName], MAX_PLAYER_NAME + 1, "%s", name);
    Check(LoadAuthAccount(playerid), "cargar cuenta de prueba");
}
stock DisconnectTestPlayer(playerid)
{
    OnPlayerDisconnect(playerid, 1);
    testConnected[playerid] = false;
}
stock FinishTests()
{
    if (g_SQL != DB:0) { DB_Close(g_SQL); g_SQL = DB:0; }
    g_DatabaseReady = false;
    Check(DB_GetDatabaseConnectionCount() == 0 && DB_GetDatabaseResultSetCount() == 0, "sin resultados ni conexiones pendientes");
    printf("[TEST] FIN: %d fallos, %d comprobaciones", testFailures, testChecks);
    testStage = 99;
}
public OnAuthPasswordHashed(playerid, session, bool:registered, epoch, jobId)
{
    if (session != g_Session[playerid]) testStaleHashSeen = true;
    return CoreAuthPasswordHashed(playerid, session, registered, epoch, jobId);
}
public OnAuthPasswordVerified(playerid, bool:success, session, accountId, epoch, jobId)
{
    if (session != g_Session[playerid]) testStaleVerifySeen = true;
    return CoreAuthPasswordVerified(playerid, success, session, accountId, epoch, jobId);
}
public OnGameModeInit()
{
    bcrypt_set_thread_limit(2);
    InitAuthCef();
    g_DatabaseReady = OpenAuthDatabase();
    Check(g_DatabaseReady, "abrir base y tabla de bloqueos");
    Check(!IsValidNewPassword("1234567") && IsValidNewPassword("12345678"), "minimo de ocho caracteres");
    new tooLong[74];
    for (new index = 0; index < 73; index++) tooLong[index] = 'a';
    Check(!IsValidNewPassword(tooLong), "rechazar mas de 72 caracteres");
    Check(!IsBcryptHash("hash_invalido"), "rechazar hashes corruptos");
    if (!g_DatabaseReady) { FinishTests(); return 1; }
    // Un campo truncado no debe convertirse en un hash aparentemente valido.
    new legacyHash[65], query[512];
    SHA256_Hash("old4", "TruncatedLegacy", legacyHash, sizeof legacyHash);
    format(query, sizeof query,
        "INSERT INTO accounts(username,password) VALUES ('TruncatedLegacy','%q' || 'extra')", legacyHash);
    Check(ExecuteAuthQuery(query), "preparar hash SHA256 con sufijo corrupto");
    format(g_Auth[9][authName], MAX_PLAYER_NAME + 1, "%s", "TruncatedLegacy");
    Check(!LoadAuthAccount(9), "rechazar SHA256 truncado al cargar cuenta");
    format(query, sizeof query,
        "INSERT INTO accounts(username,password) VALUES ('EmbeddedNullLegacy','%q' || char(0) || 'extra')", legacyHash);
    Check(ExecuteAuthQuery(query), "preparar hash con terminador incrustado");
    format(g_Auth[9][authName], MAX_PLAYER_NAME + 1, "%s", "EmbeddedNullLegacy");
    Check(!LoadAuthAccount(9), "rechazar hash con datos despues del terminador");
    format(query, sizeof query,
        "INSERT INTO accounts(username,password) VALUES ('ExactLegacy','%q')", legacyHash);
    Check(ExecuteAuthQuery(query), "preparar SHA256 completo sin truncamiento");
    format(g_Auth[9][authName], MAX_PLAYER_NAME + 1, "%s", "ExactLegacy");
    Check(LoadAuthAccount(9) && IsLegacyHash(g_Auth[9][authHash]), "conservar compatibilidad con SHA256 de 64 bytes");
    Check(DB_GetDatabaseResultSetCount() == 0, "rechazar hashes corruptos sin filtrar resultados SQL");
    SetTestPlayer(0, "VentaSecure");
    Check(g_Auth[0][authState] == AUTH_REGISTER, "cuenta nueva solicita registro");
    SubmitTestDialog(0, DIALOG_REGISTER, "1234567");
    Check(g_Auth[0][authState] == AUTH_REGISTER, "dialogo rechaza contrasena corta");
    SubmitTestDialog(0, DIALOG_REGISTER, "ClaveSegura_246");
    Check(g_Auth[0][authState] == AUTH_CREATING, "registro asincrono");
    testStage = 1;
    SetTimer("RunSecureStage", 50, true);
    return 1;
}
stock CountPendingJobs()
{
    new count;
    for (new index = 0; index < MAX_AUTH_PENDING_JOBS; index++)
        if (g_AuthJobs[index][authJobId]) count++;
    return count;
}
stock BeginLimitsTests()
{
    Check(CountPendingJobs() == 0, "callbacks anteriores liberaron todas sus plazas");
    testSharedIP = true;
    for (new index = 0; index < AUTH_IP_REQUEST_LIMIT; index++)
    {
        new name[25];
        format(name, sizeof name, "RateRequest%d", index);
        SetTestPlayer(30 + index, name);
        new jobId = ReserveAuthJob(30 + index, AUTH_JOB_HASH);
        Check(jobId > 0, "IP permite una de sus primeras seis solicitudes");
        Check(FinishAuthJob(g_AuthEpoch, jobId, AUTH_JOB_HASH), "liberar trabajo reservado");
        DisconnectTestPlayer(30 + index);
    }
    SetTestPlayer(36, "RateBlocked");
    Check(ReserveAuthJob(36, AUTH_JOB_HASH) == 0 && g_Auth[36][authState] == AUTH_CLOSING,
        "septima solicitud de IP bloqueada aunque cambie jugador y nombre");
    Check(CountPendingJobs() == 0, "rechazo por IP no reserva una plaza");
    DisconnectTestPlayer(36);
    new oldEpoch = g_AuthEpoch;
    DB_Close(g_SQL); g_SQL = DB:0;
    Check(OpenAuthDatabase() && g_AuthEpoch != oldEpoch, "generacion cambia al cargar la base de nuevo");
    SetTestPlayer(36, "RateAfterRestart");
    Check(ReserveAuthJob(36, AUTH_JOB_HASH) == 0, "limite por IP persiste al reabrir base");
    new query[256];
    format(query, sizeof query, "UPDATE auth_ip_limits SET window_started=%d WHERE ip='198.51.100.1'",
        gettime() - AUTH_IP_WINDOW_SECONDS);
    Check(ExecuteAuthQuery(query), "simular vencimiento de la ventana IP");
    SetTestPlayer(36, "RateExpired");
    new jobId = ReserveAuthJob(36, AUTH_JOB_HASH);
    Check(jobId > 0 && FinishAuthJob(g_AuthEpoch, jobId, AUTH_JOB_HASH), "IP puede solicitar tras vencer minuto");
    DisconnectTestPlayer(36);
    testSharedIP = false;

    SetTestPlayer(0, "VentaSecure");
    jobId = ReserveAuthJob(0, AUTH_JOB_VERIFY);
    Check(jobId > 0, "reservar verificacion identificada");
    g_Auth[0][authState] = AUTH_VERIFYING;
    CoreAuthPasswordVerified(0, true, g_Session[0], testAccountId, oldEpoch, jobId);
    Check(CountPendingJobs() == 1 && g_Auth[0][authState] == AUTH_VERIFYING,
        "callback de generacion anterior no libera ni autentica nuevo trabajo");
    CoreAuthPasswordHashed(0, g_Session[0], true, g_AuthEpoch, jobId);
    Check(CountPendingJobs() == 1, "callback de tipo incorrecto no libera plaza");
    CoreAuthPasswordVerified(0, true, g_Session[0], testAccountId, g_AuthEpoch, jobId + 100);
    Check(CountPendingJobs() == 1 && g_Auth[0][authState] == AUTH_VERIFYING, "callback con token incorrecto ignorado");
    Check(FinishAuthJob(g_AuthEpoch, jobId, AUTH_JOB_VERIFY), "callback valido libera plaza una vez");
    Check(!FinishAuthJob(g_AuthEpoch, jobId, AUTH_JOB_VERIFY), "no liberar dos veces la misma plaza");
    CoreAuthPasswordVerified(0, false, g_Session[0], testAccountId, g_AuthEpoch, jobId);
    new failures, lockedUntil;
    Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 0,
        "callback repetido no contabiliza otro fallo");
    DisconnectTestPlayer(0);

    for (new index = 0; index < MAX_AUTH_PENDING_JOBS; index++)
    {
        new name[25];
        format(name, sizeof name, "Queued%d", index);
        SetTestPlayer(10 + index, name);
        SubmitTestDialog(10 + index, DIALOG_REGISTER, "ClaveQueue_246");
        Check(g_Auth[10 + index][authState] == AUTH_CREATING, "encolar hash bcrypt real dentro de capacidad");
        DisconnectTestPlayer(10 + index);
    }
    Check(CountPendingJobs() == MAX_AUTH_PENDING_JOBS, "desconectar no libera ninguno de los 16 trabajos pendientes");
    SetTestPlayer(26, "QueueOverflow");
    SubmitTestDialog(26, DIALOG_REGISTER, "ClaveQueue_246");
    Check(g_Auth[26][authState] == AUTH_CLOSING && CountPendingJobs() == MAX_AUTH_PENDING_JOBS,
        "solicitud diecisiete rechazada sin encolarse");
    DisconnectTestPlayer(26);
    testStage = 10;
}

stock BeginCefTests()
{
    SetTestPlayer(9, "CefDraft");
    Check(!g_AuthCef[9][cefBrowser] && !g_AuthCef[9][cefLoaded], "cliente sin CEF conserva acceso clasico");
    OnCefReady(9);
    new browserid = g_AuthCef[9][cefBrowser];
    Check(browserid > 0 && !g_AuthCef[9][cefLoaded] && testCefCreates > 0, "crear browser tras descargar recursos");
    new emits = testCefStates;
    OnAuthCefReady(9, browserid, g_Session[9] + 1, g_AuthEpoch);
    Check(!g_AuthCef[9][cefLoaded] && testCefStates == emits, "HTML de sesion antigua no activa interfaz");
    OnAuthCefReady(9, browserid, g_Session[9], g_AuthEpoch + 1);
    Check(!g_AuthCef[9][cefLoaded], "HTML de generacion antigua no activa interfaz");
    OnAuthCefReady(9, browserid + 1, g_Session[9], g_AuthEpoch);
    Check(!g_AuthCef[9][cefLoaded], "browser ajeno no activa interfaz");
    OnAuthCefReady(9, browserid, g_Session[9], g_AuthEpoch);
    Check(g_AuthCef[9][cefLoaded] && !g_AuthCef[9][cefLoadTimer] && testCefStates > emits, "HTML confirmado recibe estado y cancela timeout");
    OnAuthCefReady(9, browserid, g_Session[9], g_AuthEpoch);
    Check(testCefStates == emits + 1, "ready repetido no emite estado ilimitadamente");
    SubmitTestDialog(9, DIALOG_REGISTER, "ClaveCef_246");
    Check(CountPendingJobs() == 0, "dialogo oculto no puede enviar acceso paralelo");
    OnAuthCefSubmit(9, browserid, g_Session[9] + 1, g_AuthEpoch, "ClaveCef_246");
    OnAuthCefSubmit(9, browserid, g_Session[9], g_AuthEpoch + 1, "ClaveCef_246");
    OnAuthCefSubmit(9, browserid + 1, g_Session[9], g_AuthEpoch, "ClaveCef_246");
    Check(CountPendingJobs() == 0 && g_Auth[9][authState] == AUTH_REGISTER, "eventos de otro browser o sesion no encolan bcrypt");
    OnAuthCefSubmit(9, browserid, g_Session[9], g_AuthEpoch, "short");
    Check(CountPendingJobs() == 0 && g_Auth[9][authState] == AUTH_REGISTER, "registro CEF aplica minimo de ocho caracteres");
    new nonAscii[9] = "abcdefg";
    nonAscii[7] = 233;
    OnAuthCefSubmit(9, browserid, g_Session[9], g_AuthEpoch, nonAscii);
    Check(CountPendingJobs() == 0, "CEF rechaza conversion ambigua de contrasenas entre plataformas");
    OnAuthCefFallback(9, browserid, g_Session[9], g_AuthEpoch);
    Check(g_AuthCef[9][cefDisabled] && !g_AuthCef[9][cefBrowser] && !g_AuthCef[9][cefLoaded], "acceso clasico cierra CEF y restaura transporte");
    OnAuthCefSubmit(9, browserid, g_Session[9], g_AuthEpoch, "ClaveCef_246");
    Check(CountPendingJobs() == 0, "CEF cerrado no puede enviar contrasena");
    OnCefReady(9);
    Check(!g_AuthCef[9][cefBrowser], "ready repetido respeta eleccion de acceso clasico");
    SetTestPlayer(9, "CefDraft");
    OnCefReady(9);
    new nextBrowser = g_AuthCef[9][cefBrowser];
    Check(nextBrowser != browserid && !g_AuthCef[9][cefDisabled], "reconectar usa browser distinto y limpia preferencias");
    KillTimer(g_AuthCef[9][cefLoadTimer]);
    AuthCefLoadTimeout(9, g_Session[9], g_AuthEpoch, nextBrowser);
    Check(g_AuthCef[9][cefDisabled] && !g_AuthCef[9][cefBrowser], "HTML que no carga vuelve a dialogos");
    SetTestPlayer(9, "CefDraft");
    OnCefReady(9);
    nextBrowser = g_AuthCef[9][cefBrowser];
    OnCefBrowserCreated(9, nextBrowser, false, E_CEF_CREATE_STATUS:0, "prueba");
    Check(!g_AuthCef[9][cefBrowser] && g_AuthCef[9][cefDisabled], "fallo al crear browser vuelve a dialogos");
    SetTestPlayer(9, "CefDraft");
    OnCefReady(9);
    nextBrowser = g_AuthCef[9][cefBrowser];
    OnAuthCefReady(9, nextBrowser, g_Session[9], g_AuthEpoch);
    OnAuthCefCancel(9, nextBrowser, g_Session[9], g_AuthEpoch);
    Check(g_Auth[9][authState] == AUTH_CLOSING && !g_AuthCef[9][cefBrowser], "cancelar CEF cierra acceso y limpia browser");
    SetTestPlayer(9, "CefReal");
    OnCefReady(9);
    nextBrowser = g_AuthCef[9][cefBrowser];
    OnAuthCefReady(9, nextBrowser, g_Session[9], g_AuthEpoch);
    OnAuthCefSubmit(9, nextBrowser, g_Session[9], g_AuthEpoch, "ClaveCef_246");
    Check(g_Auth[9][authState] == AUTH_CREATING && CountPendingJobs() == 1, "registro HTML usa bcrypt real");
    OnAuthCefSubmit(9, nextBrowser, g_Session[9], g_AuthEpoch, "ClaveCef_246");
    Check(CountPendingJobs() == 1, "submit HTML duplicado no reserva otro trabajo");
    testStage = 14;
}

public RunSecureStage()
{
    if (testStage == 99) return 1;
    testTicks++;
    if (testTicks > 1200) { Check(false, "tiempo limite de pruebas"); FinishTests(); return 1; }
    new failures, lockedUntil;
    switch (testStage)
    {
        case 1:
        {
            if (g_Auth[0][authState] != AUTH_LOGGED_IN) return 1;
            testAccountId = g_Auth[0][authAccountId];
            Check(testAccountId > 0, "registro bcrypt permite acceso");
            SetTestPlayer(0, "ventasecure");
            Check(IsBcryptHash(g_Auth[0][authHash]), "guardar bcrypt de 60 caracteres");
            Check(strcmp(g_Auth[0][authName], "VentaSecure") == 0, "recuperar nombre original");
            Check(ExecuteAuthQuery("INSERT INTO accounts(username,password) SELECT 'EmbeddedNullBcrypt',password || char(0) || 'extra' FROM accounts WHERE username='VentaSecure'"),
                "preparar bcrypt real con datos tras terminador");
            format(g_Auth[9][authName], MAX_PLAYER_NAME + 1, "%s", "EmbeddedNullBcrypt");
            Check(!LoadAuthAccount(9), "rechazar bcrypt con datos ocultos tras terminador");
            SubmitTestDialog(0, DIALOG_LOGIN, "ClaveIncorrecta");
            Check(g_Auth[0][authState] == AUTH_VERIFYING, "verificacion asincrona");
            SubmitTestDialog(0, DIALOG_LOGIN, "ClaveSegura_246");
            Check(g_Auth[0][authState] == AUTH_VERIFYING, "ignorar respuesta repetida mientras verifica");
            DisconnectTestPlayer(0);
            testStage = 2;
        }
        case 2:
        {
            if (!GetAuthLimit(testAccountId, failures, lockedUntil) || failures != 1) return 1;
            Check(failures == 1 && lockedUntil == 0, "contar fallo terminado tras desconectar");
            SetTestPlayer(1, "VentaSecure");
            Check(CheckAuthAccess(1), "primer fallo permite nuevo intento");
            SubmitTestDialog(1, DIALOG_LOGIN, "OtraIncorrecta");
            testStage = 3;
        }
        case 3:
        {
            if (g_Auth[1][authState] != AUTH_LOGIN) return 1;
            Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 2, "segundo fallo conservado por cuenta");
            DisconnectTestPlayer(1);
            SetTestPlayer(2, "ventasecure");
            Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 2, "reconectar no reinicia intentos");
            SubmitTestDialog(2, DIALOG_LOGIN, "TerceraIncorrecta");
            testStage = 4;
        }
        case 4:
        {
            if (g_Auth[2][authState] != AUTH_CLOSING) return 1;
            Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 3
                && lockedUntil >= gettime() + LOGIN_LOCK_SECONDS - 5, "tercer fallo bloquea cinco minutos");
            DisconnectTestPlayer(2);
            DB_Close(g_SQL); g_SQL = DB:0;
            Check(OpenAuthDatabase(), "reabrir base con bloqueo guardado");
            SetTestPlayer(3, "VentaSecure");
            Check(!CheckAuthAccess(3) && g_Auth[3][authState] == AUTH_CLOSING, "bloqueo persiste al reiniciar y reconectar");
            Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 3, "conservar fallos tras reabrir base");
            new query[256];
            format(query, sizeof query, "UPDATE auth_limits SET locked_until=%d WHERE account_id=%d", gettime() - 1, testAccountId);
            Check(ExecuteAuthQuery(query), "simular vencimiento de bloqueo");
            Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 0 && lockedUntil == 0, "desbloqueo automatico al vencer");
            Check(RecordAuthFailure(testAccountId), "guardar fallo antes de login correcto");
            SetTestPlayer(3, "VentaSecure");
            SubmitTestDialog(3, DIALOG_LOGIN, "ClaveSegura_246");
            testStage = 5;
        }
        case 5:
        {
            if (g_Auth[3][authState] != AUTH_LOGGED_IN) return 1;
            Check(GetAuthLimit(testAccountId, failures, lockedUntil) && failures == 0 && lockedUntil == 0, "login correcto limpia intentos");
            new legacyHash[65], query[512];
            SHA256_Hash("old4", "CuentaAnterior", legacyHash, sizeof legacyHash);
            format(query, sizeof query, "INSERT INTO accounts(username,password) VALUES ('CuentaAnterior','%q')", legacyHash);
            Check(ExecuteAuthQuery(query), "preparar cuenta SHA256 anterior");
            SetTestPlayer(4, "cuentaanterior");
            Check(IsLegacyHash(g_Auth[4][authHash]), "admitir cuenta anterior sin borrarla");
            SubmitTestDialog(4, DIALOG_LOGIN, "old4");
            Check(g_Auth[4][authState] == AUTH_UPGRADING, "migrar despues de comprobar clave anterior");
            testStage = 6;
        }
        case 6:
        {
            if (g_Auth[4][authState] != AUTH_LOGGED_IN) return 1;
            SetTestPlayer(4, "CuentaAnterior");
            Check(IsBcryptHash(g_Auth[4][authHash]) && !IsLegacyHash(g_Auth[4][authHash]), "cuenta anterior convertida a bcrypt");
            SubmitTestDialog(4, DIALOG_LOGIN, "old4");
            testStage = 7;
        }
        case 7:
        {
            if (g_Auth[4][authState] != AUTH_LOGGED_IN) return 1;
            Check(true, "volver a entrar con cuenta migrada");
            SetTestPlayer(5, "GhostRegister");
            testStaleHashSeen = false;
            SubmitTestDialog(5, DIALOG_REGISTER, "ClaveGhost_135");
            DisconnectTestPlayer(5);
            SetTestPlayer(5, "NuevaSesion");
            testStage = 8;
        }
        case 8:
        {
            if (!testStaleHashSeen) return 1;
            Check(g_Auth[5][authState] == AUTH_REGISTER && strcmp(g_Auth[5][authName], "NuevaSesion") == 0, "hash tardio no cambia otra sesion");
            new DBResult:result = DB_ExecuteQuery(g_SQL, "SELECT COUNT(*) AS total FROM accounts WHERE username='GhostRegister'");
            Check(result != DBResult:0, "consultar registro cancelado");
            if (result != DBResult:0) { Check(DB_GetFieldIntByName(result, "total") == 0, "no registrar jugador desconectado"); DB_FreeResultSet(result); }
            SetTestPlayer(5, "VentaSecure");
            testStaleVerifySeen = false;
            SubmitTestDialog(5, DIALOG_LOGIN, "ClaveSegura_246");
            DisconnectTestPlayer(5);
            SetTestPlayer(5, "OtraSesion");
            testStage = 9;
        }
        case 9:
        {
            if (!testStaleVerifySeen) return 1;
            Check(g_Auth[5][authState] == AUTH_REGISTER && strcmp(g_Auth[5][authName], "OtraSesion") == 0, "verificacion tardia no autentica otra sesion");
            Check(DB_GetDatabaseResultSetCount() == 0, "liberar resultados SQL");
            BeginLimitsTests();
        }
        case 10:
        {
            if (CountPendingJobs() != 0) return 1;
            Check(true, "los 16 callbacks reales liberan capacidad tras desconectar");
            new DBResult:result = DB_ExecuteQuery(g_SQL, "SELECT COUNT(*) AS total FROM accounts WHERE username LIKE 'Queued%'");
            Check(result != DBResult:0 && DB_GetFieldIntByName(result, "total") == 0,
                "ninguno de los registros desconectados crea cuenta");
            if (result != DBResult:0) DB_FreeResultSet(result);
            Check(ExecuteAuthQuery("INSERT INTO accounts(username,password) SELECT 'DeletedDuringVerify',password FROM accounts WHERE username='VentaSecure'"),
                "crear cuenta temporal para reproducir borrado");
            SetTestPlayer(6, "DeletedDuringVerify");
            SubmitTestDialog(6, DIALOG_LOGIN, "ClaveSegura_246");
            Check(g_Auth[6][authState] == AUTH_VERIFYING, "borrado se prueba durante bcrypt real");
            new query[128];
            format(query, sizeof query, "DELETE FROM accounts WHERE id=%d", g_Auth[6][authAccountId]);
            Check(ExecuteAuthQuery(query), "eliminar cuenta mientras verifica");
            testStage = 11;
        }
        case 11:
        {
            if (CountPendingJobs() != 0) return 1;
            Check(g_Auth[6][authState] == AUTH_CLOSING, "cuenta eliminada durante verificacion no inicia sesion");
            Check(!UpdateAuthActivity(g_Auth[6][authAccountId], "192.0.2.7", "hash_no_existente"),
                "UPDATE de cero cuentas devuelve fallo");
            DisconnectTestPlayer(6);
            Check(ExecuteAuthQuery("INSERT INTO accounts(username,password) SELECT 'ChangedDuringVerify',password FROM accounts WHERE username='VentaSecure'"),
                "preparar cambio de contrasena durante verificacion");
            SetTestPlayer(7, "ChangedDuringVerify");
            SubmitTestDialog(7, DIALOG_LOGIN, "ClaveSegura_246");
            Check(g_Auth[7][authState] == AUTH_VERIFYING, "cambio de clave se prueba durante bcrypt real");
            new query[256];
            format(query, sizeof query,
                "UPDATE accounts SET password=(SELECT password FROM accounts WHERE username='CuentaAnterior') WHERE id=%d",
                g_Auth[7][authAccountId]);
            Check(ExecuteAuthQuery(query), "cambiar hash almacenado mientras verifica");
            testStage = 12;
        }
        case 12:
        {
            if (CountPendingJobs() != 0) return 1;
            Check(g_Auth[7][authState] == AUTH_CLOSING, "contrasena cambiada invalida resultado bcrypt anterior");
            DisconnectTestPlayer(7);
            new legacyHash[65], query[256];
            SHA256_Hash("old4", "LegacyDeleted", legacyHash, sizeof legacyHash);
            format(query, sizeof query, "INSERT INTO accounts(username,password) VALUES ('LegacyDeleted','%q')", legacyHash);
            Check(ExecuteAuthQuery(query), "preparar cuenta anterior para borrado durante migracion");
            SetTestPlayer(8, "LegacyDeleted");
            SubmitTestDialog(8, DIALOG_LOGIN, "old4");
            Check(g_Auth[8][authState] == AUTH_UPGRADING, "migracion bcrypt real en curso");
            format(query, sizeof query, "DELETE FROM accounts WHERE id=%d", g_Auth[8][authAccountId]);
            Check(ExecuteAuthQuery(query), "eliminar cuenta durante migracion");
            testStage = 13;
        }
        case 13:
        {
            if (CountPendingJobs() != 0) return 1;
            Check(g_Auth[8][authState] == AUTH_CLOSING, "migracion de cuenta eliminada no concede acceso");
            DisconnectTestPlayer(8);
            BeginCefTests();
        }
        case 14:
        {
            if (g_Auth[9][authState] != AUTH_LOGGED_IN) return 1;
            Check(!g_AuthCef[9][cefBrowser] && !g_AuthCef[9][cefLoadTimer] && testCefDestroys > 0,
                "registro CEF correcto destruye UI y timers");
            SetTestPlayer(9, "CefReal");
            Check(IsBcryptHash(g_Auth[9][authHash]), "registro CEF guardo bcrypt en SQLite");
            OnCefReady(9);
            new browserid = g_AuthCef[9][cefBrowser];
            OnAuthCefReady(9, browserid, g_Session[9], g_AuthEpoch);
            OnAuthCefSubmit(9, browserid, g_Session[9], g_AuthEpoch, "OtraClave_246");
            Check(g_Auth[9][authState] == AUTH_VERIFYING, "login HTML usa verificacion bcrypt real");
            testStage = 15;
        }
        case 15:
        {
            if (g_Auth[9][authState] != AUTH_LOGIN) return 1;
            Check(GetAuthLimit(g_Auth[9][authAccountId], failures, lockedUntil) && failures == 1,
                "fallo HTML aplica limites por cuenta existentes");
            OnAuthCefSubmit(9, g_AuthCef[9][cefBrowser], g_Session[9], g_AuthEpoch, "ClaveCef_246");
            testStage = 16;
        }
        case 16:
        {
            if (g_Auth[9][authState] != AUTH_LOGGED_IN) return 1;
            Check(GetAuthLimit(g_Auth[9][authAccountId], failures, lockedUntil) && failures == 0,
                "login HTML correcto limpia intentos");
            Check(!g_AuthCef[9][cefBrowser] && !g_AuthCef[9][cefLoaded], "login HTML correcto libera interfaz");
            DisconnectTestPlayer(9);
            Check(CountPendingJobs() == 0 && DB_GetDatabaseResultSetCount() == 0, "sin trabajos ni resultados SQL pendientes al terminar");
            FinishTests();
        }
    }
    return 1;
}
