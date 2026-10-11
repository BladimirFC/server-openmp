// Adaptador HTML: la autorizacion y bcrypt siguen en ProcessAuthInput.
#include <cef>

#define AUTH_CEF_LOAD_TIMEOUT (8000)

enum E_AUTH_CEF_DATA
{
    bool:cefReady,
    bool:cefDisabled,
    bool:cefLoaded,
    cefBrowser,
    cefLoadTimer
}
new g_AuthCef[MAX_PLAYERS][E_AUTH_CEF_DATA];
new g_NextCefBrowser;

forward AuthCefLoadTimeout(playerid, session, epoch, browserid);
forward OnAuthCefReady(playerid, browserid, session, epoch);
forward OnAuthCefSubmit(playerid, browserid, session, epoch, const password[]);
forward OnAuthCefCancel(playerid, browserid, session, epoch);
forward OnAuthCefFallback(playerid, browserid, session, epoch);

stock InitAuthCef()
{
    CEF_AddResource("auth");
    CEF_RegisterEvent("auth:ready", "OnAuthCefReady", Argument_Integer, Argument_Integer);
    CEF_RegisterEvent("auth:submit", "OnAuthCefSubmit", Argument_Integer, Argument_Integer, Argument_String);
    CEF_RegisterEvent("auth:cancel", "OnAuthCefCancel", Argument_Integer, Argument_Integer);
    CEF_RegisterEvent("auth:fallback", "OnAuthCefFallback", Argument_Integer, Argument_Integer);
}

stock CloseAuthCef(playerid)
{
    if (g_AuthCef[playerid][cefLoadTimer])
    {
        KillTimer(g_AuthCef[playerid][cefLoadTimer]);
        g_AuthCef[playerid][cefLoadTimer] = 0;
    }
    if (g_AuthCef[playerid][cefBrowser] && IsPlayerConnected(playerid))
    {
        CEF_FocusBrowser(playerid, g_AuthCef[playerid][cefBrowser], false);
        CEF_ToggleChatInput(playerid, true);
        CEF_DestroyBrowser(playerid, g_AuthCef[playerid][cefBrowser]);
    }
    g_AuthCef[playerid][cefBrowser] = 0;
    g_AuthCef[playerid][cefLoaded] = false;
}

stock ResetAuthCef(playerid)
{
    CloseAuthCef(playerid);
    static const emptyCef[E_AUTH_CEF_DATA];
    g_AuthCef[playerid] = emptyCef;
}

stock bool:IsAuthCefEvent(playerid, browserid, session, epoch)
{
    if (!IsCurrentSession(playerid, session) || epoch != g_AuthEpoch || !g_DatabaseReady) return false;
    return browserid > 0 && browserid == g_AuthCef[playerid][cefBrowser]
        && g_AuthCef[playerid][cefReady] && !g_AuthCef[playerid][cefDisabled]
        && g_Auth[playerid][authState] != AUTH_LOGGED_IN && g_Auth[playerid][authState] != AUTH_CLOSING;
}

stock SendAuthCefState(playerid, const message[] = "")
{
    new bool:register = g_Auth[playerid][authState] == AUTH_REGISTER || g_Auth[playerid][authState] == AUTH_CREATING;
    new bool:busy = g_Auth[playerid][authState] != AUTH_REGISTER && g_Auth[playerid][authState] != AUTH_LOGIN;
    CEF_EmitEvent(playerid, g_AuthCef[playerid][cefBrowser], "auth:state",
        CEF_STR(g_Auth[playerid][authName]), CEF_BOOL(register), CEF_BOOL(busy), CEF_STR(message));
}

stock bool:ShowAuthCef(playerid, const message[])
{
    if (!g_AuthCef[playerid][cefReady] || g_AuthCef[playerid][cefDisabled]) return false;
    if (!g_AuthCef[playerid][cefBrowser])
    {
        g_NextCefBrowser = g_NextCefBrowser >= 2147483646 ? 1 : g_NextCefBrowser + 1;
        g_AuthCef[playerid][cefBrowser] = g_NextCefBrowser;
        new url[128]; // Caracteres; ruta local y generacion/sesion, nunca contrasenas.
        format(url, sizeof url, "http://cef/auth/index.html?session=%d&epoch=%d", g_Session[playerid], g_AuthEpoch);
        CEF_CreateBrowser(playerid, g_NextCefBrowser, url, true, true);
        g_AuthCef[playerid][cefLoadTimer] = SetTimerEx("AuthCefLoadTimeout", AUTH_CEF_LOAD_TIMEOUT,
            false, "iiii", playerid, g_Session[playerid], g_AuthEpoch, g_NextCefBrowser);
    }
    if (!g_AuthCef[playerid][cefLoaded]) return false;
    HidePlayerDialog(playerid);
    SendAuthCefState(playerid, message);
    return true;
}

stock UseClassicAuth(playerid)
{
    g_AuthCef[playerid][cefDisabled] = true;
    CloseAuthCef(playerid);
    ShowAuthDialog(playerid);
}

public OnCefInitialize(playerid, bool:success, E_CEF_INIT_REASON:reason, const message[])
{
    #pragma unused reason, message
    if (playerid < 0 || playerid >= MAX_PLAYERS) return 1;
    if (!IsCurrentSession(playerid, g_Session[playerid])) return 1;
    if (!success)
    {
        g_AuthCef[playerid][cefReady] = false;
        UseClassicAuth(playerid);
    }
    return 1;
}

public OnCefReady(playerid)
{
    if (playerid < 0 || playerid >= MAX_PLAYERS) return 1;
    if (!IsCurrentSession(playerid, g_Session[playerid]) || !g_DatabaseReady) return 1;
    g_AuthCef[playerid][cefReady] = true;
    if (g_Auth[playerid][authState] == AUTH_LOGIN || g_Auth[playerid][authState] == AUTH_REGISTER)
        ShowAuthDialog(playerid);
    return 1;
}

public OnCefBrowserCreated(playerid, browserid, bool:success, E_CEF_CREATE_STATUS:code, const reason[])
{
    #pragma unused code, reason
    if (playerid < 0 || playerid >= MAX_PLAYERS) return 1;
    if (!IsAuthCefEvent(playerid, browserid, g_Session[playerid], g_AuthEpoch)) return 1;
    if (!success) UseClassicAuth(playerid);
    // El HTML confirma auth:ready; crear el browser no demuestra que el JS cargo.
    return 1;
}

public OnAuthCefReady(playerid, browserid, session, epoch)
{
    if (!IsAuthCefEvent(playerid, browserid, session, epoch)) return 1;
    if (g_AuthCef[playerid][cefLoaded]) return 1;
    g_AuthCef[playerid][cefLoaded] = true;
    if (g_AuthCef[playerid][cefLoadTimer]) KillTimer(g_AuthCef[playerid][cefLoadTimer]);
    g_AuthCef[playerid][cefLoadTimer] = 0;
    HidePlayerDialog(playerid);
    SendAuthCefState(playerid);
    return 1;
}

public OnAuthCefSubmit(playerid, browserid, session, epoch, const password[])
{
    if (!IsAuthCefEvent(playerid, browserid, session, epoch) || !g_AuthCef[playerid][cefLoaded]) return 1;
    if (g_Auth[playerid][authState] != AUTH_LOGIN && g_Auth[playerid][authState] != AUTH_REGISTER) return 1;
    if (strlen(password) > MAX_PASSWORD_LENGTH)
    {
        SendAuthCefState(playerid, "La contrasena no puede superar 72 caracteres.");
        return 1;
    }
    // El componente usa ANSI en Windows y UTF-8 en Linux. ASCII evita cambiar la clave.
    for (new index = 0; password[index]; index++)
        if (password[index] < 32 || password[index] > 126)
        {
            SendAuthCefState(playerid, "Para esta contrasena usa Acceso clasico.");
            return 1;
        }
    new dialogid = g_Auth[playerid][authState] == AUTH_REGISTER ? DIALOG_REGISTER : DIALOG_LOGIN;
    ProcessAuthInput(playerid, dialogid, true, password);
    if (g_AuthCef[playerid][cefLoaded] && (g_Auth[playerid][authState] == AUTH_CREATING
        || g_Auth[playerid][authState] == AUTH_VERIFYING || g_Auth[playerid][authState] == AUTH_UPGRADING))
        SendAuthCefState(playerid);
    return 1;
}

public OnAuthCefCancel(playerid, browserid, session, epoch)
{
    if (IsAuthCefEvent(playerid, browserid, session, epoch) && g_AuthCef[playerid][cefLoaded])
        CloseAuth(playerid, "Has cancelado el acceso al servidor.");
    return 1;
}

public OnAuthCefFallback(playerid, browserid, session, epoch)
{
    if (!IsAuthCefEvent(playerid, browserid, session, epoch) || !g_AuthCef[playerid][cefLoaded]) return 1;
    if (g_Auth[playerid][authState] == AUTH_LOGIN || g_Auth[playerid][authState] == AUTH_REGISTER)
        UseClassicAuth(playerid);
    return 1;
}

public AuthCefLoadTimeout(playerid, session, epoch, browserid)
{
    if (!IsAuthCefEvent(playerid, browserid, session, epoch)) return 1;
    g_AuthCef[playerid][cefLoadTimer] = 0;
    if (!g_AuthCef[playerid][cefLoaded]) UseClassicAuth(playerid);
    return 1;
}
