--[[
    FearzMineV3 - VERSION ANDROID (v3 - sin ImGui)
    Autor original: Fearz
    Adaptación: MoonLoader/MoonetLoader Android

    Cambios vs PC:
    - imgui ELIMINADO (no disponible en moonetloader)
      → Reemplazado por menú de texto en chat (/minefearzmenu)
    - vkeys / setVirtualKeyDown ELIMINADOS (no existen en Android)
      → Respuestas Y/N/ALT usan sampSendChat()
      → Interacción con nodo usa setGameKeyState()
    - isSampLoaded() envuelto en pcall por compatibilidad
    - encoding simplificado (UTF-8 nativo Android)
--]]

script_name("FearzMineV3-Android")
script_author("Fearz")

local ev = require("lib.samp.events")

-- ══════════════════════════════════════
--  Estado del bot
-- ══════════════════════════════════════
local botActivo      = false
local estado         = 0
local detectarLetras = false
local teclaPulsada   = false
local teclaPendiente = nil

-- Debug: cambiar a true para ver qué eventos de textdraw llegan
local DEBUG_TD = false

-- Modo interacción: "gamekey" o "chat"
-- Si el nodo no responde con gamekey, cambia a "chat" con /minefearzmodo
local modoInteraccion = "gamekey"

-- ══════════════════════════════════════
--  Puntos (sin cambios del original)
-- ══════════════════════════════════════
local puntos_minado = {
    {1334.4513, 1382.4972, 11.4152},
    {1340.4071, 1382.3357, 11.4243}
}
local punto_descarga = {1314.6938, 1348.4990, 10.8284}
local rutas_desvio = {
    {1328.7784, 1362.3887, 10.8284},
    {1334.3768, 1373.3978, 11.0549}
}

-- ══════════════════════════════════════
--  Tiempos (sin cambios del original)
-- ══════════════════════════════════════
local tiempo_minado   = 11000
local tiempo_descarga = 3500
local tiempo_pulsarN  = 1000
local tiempo_tecla    = 400

-- ══════════════════════════════════════
--  Estados
-- ══════════════════════════════════════
local STATUS = {
    IDLE            = 0,
    GO_TO_MINE      = 1,
    PRESS_N         = 2,
    MINING_WAIT     = 3,
    WAIT_FOR_LETTER = 4,
    GO_TO_DESVIO    = 5,
    DESCARGANDO     = 6,
    RETURNING       = 7
}

-- ══════════════════════════════════════
--  Interacción con nodo de minería
--  (reemplaza pulsarTeclaVK VK_N del PC)
-- ══════════════════════════════════════
local function simularInteraccionMinado(ms)
    if modoInteraccion == "chat" then
        sampSendChat("N")
        wait(ms)
    else
        setGameKeyState(16, 255)
        wait(ms)
        setGameKeyState(16, 0)
    end
end

-- ══════════════════════════════════════
--  Responder textdraw Y/N/ALT por chat
--  (reemplaza setVirtualKeyDown del PC)
-- ══════════════════════════════════════
local function responderTextdraw(texto)
    wait(tiempo_tecla)
    sampSendChat(texto)
    wait(tiempo_tecla)
end

-- ══════════════════════════════════════
--  Mover personaje (igual que PC)
-- ══════════════════════════════════════
local function moverA(x, y, z, sprint, continuo)
    repeat
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        local angulo = getHeadingFromVector2d(x - px, y - py)
        setCameraPositionUnfixed(-0.3, math.rad(angulo) + 4.7)
        setGameKeyState(1, -255)
        if sprint then setGameKeyState(16, 255) end
        wait(0)
    until getDistanceBetweenCoords3d(x, y, z, px, py, pz) < 1.0 or not botActivo

    if not continuo then
        setGameKeyState(1, 0)
        setGameKeyState(16, 0)
    end
end

-- ══════════════════════════════════════
--  Detectar letras en textdraws
-- ══════════════════════════════════════
local function procesarCambio(text)
    local limpio = text:gsub("{.-}", ""):gsub("~.-~", ""):gsub("%s+", ""):upper()
    if not teclaPulsada then
        if     limpio == "ALT" then teclaPendiente = "ALT"
        elseif limpio == "Y"   then teclaPendiente = "Y"
        elseif limpio == "N"   then teclaPendiente = "N"
        end
    end
end

function ev.onTextDrawSetString(id, text)
    if DEBUG_TD then sampAddChatMessage("{888888}[TD SetString] id="..id.." text="..tostring(text), -1) end
    if botActivo and detectarLetras then procesarCambio(text) end
end
function ev.onPlayerTextDrawSetString(id, text)
    if DEBUG_TD then sampAddChatMessage("{888888}[TD PlayerSetString] id="..id.." text="..tostring(text), -1) end
    if botActivo and detectarLetras then procesarCambio(text) end
end
function ev.onShowTextDraw(textdrawId, textdrawData)
    if DEBUG_TD then
        sampAddChatMessage("{888888}[TD Show] id="..tostring(textdrawId).." text="..tostring(textdrawData and textdrawData.text or "nil"), -1)
        for k, v in pairs(textdrawData or {}) do
            sampAddChatMessage("{888888}  "..tostring(k).." = "..tostring(v), -1)
        end
    end
    if botActivo and detectarLetras and textdrawData and textdrawData.text then
        procesarCambio(textdrawData.text)
    end
end
function ev.onShowPlayerTextDraw(textdrawId, textdrawData)
    if DEBUG_TD then
        sampAddChatMessage("{888888}[TD PlayerShow] id="..tostring(textdrawId).." text="..tostring(textdrawData and textdrawData.text or "nil"), -1)
        for k, v in pairs(textdrawData or {}) do
            sampAddChatMessage("{888888}  "..tostring(k).." = "..tostring(v), -1)
        end
    end
    if botActivo and detectarLetras and textdrawData and textdrawData.text then
        procesarCambio(textdrawData.text)
    end
end

-- ══════════════════════════════════════
--  Validación
-- ══════════════════════════════════════
local function puedeIniciar()
    if getActiveInterior() == 0 then
        sampAddChatMessage("{FF0000}[FearzMine]: No estas en una mineria privada", -1)
        return false
    end
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    if getDistanceBetweenCoords3d(px, py, pz,
        puntos_minado[1][1], puntos_minado[1][2], puntos_minado[1][3]) > 15.0 then
        sampAddChatMessage("{FF0000}[FearzMine]: No estas cerca del punto de mineral", -1)
        return false
    end
    return true
end

local function obtenerPuntoMinadoAleatorio()
    return puntos_minado[math.random(1, #puntos_minado)]
end

-- ══════════════════════════════════════
--  Menú en chat (reemplaza ImGui)
-- ══════════════════════════════════════
local function mostrarMenu()
    local estadoBot = botActivo and "{00FF00}ACTIVO" or "{FF0000}INACTIVO"
    local estadoModo = modoInteraccion == "gamekey" and "{00CCFF}GAMEKEY" or "{FFFF00}CHAT"
    sampAddChatMessage("{FFFFFF}╔══════════════════════════╗", -1)
    sampAddChatMessage("{FFFFFF}║  {00CCFF}FearzMine Android Menu   {FFFFFF}║", -1)
    sampAddChatMessage("{FFFFFF}╠══════════════════════════╣", -1)
    sampAddChatMessage("{FFFFFF}║ Bot: " .. estadoBot .. "                {FFFFFF}║", -1)
    sampAddChatMessage("{FFFFFF}║ Modo: " .. estadoModo .. "             {FFFFFF}║", -1)
    sampAddChatMessage("{FFFFFF}╠══════════════════════════╣", -1)
    sampAddChatMessage("{FFFFFF}║ {FFFF00}/minefearz   {FFFFFF}- ON/OFF bot    ║", -1)
    sampAddChatMessage("{FFFFFF}║ {FFFF00}/minefearzmodo {FFFFFF}- gamekey/chat ║", -1)
    sampAddChatMessage("{FFFFFF}╚══════════════════════════╝", -1)
end

-- ══════════════════════════════════════
--  MAIN
-- ══════════════════════════════════════
function main()
    -- Espera SAMP con compatibilidad moonetloader
    local intentos = 0
    repeat
        wait(500)
        intentos = intentos + 1
        if intentos > 120 then return end
    until pcall(sampAddChatMessage, "", -1)

    wait(500)
    sampAddChatMessage("{00FF00}[FearzMine Android] Cargado. Usa /minefearz o /minefearzmenu", -1)

    -- Activar / desactivar bot
    sampRegisterChatCommand("minefearz", function()
        if botActivo then
            botActivo      = false
            estado         = STATUS.IDLE
            detectarLetras = false
            teclaPendiente = nil
            setGameKeyState(1, 0)
            setGameKeyState(16, 0)
            sampAddChatMessage("{FF0000}[FearzMine OFF]", -1)
        else
            if not puedeIniciar() then return end
            botActivo      = true
            estado         = STATUS.GO_TO_MINE
            detectarLetras = false
            teclaPulsada   = false
            teclaPendiente = nil
            sampAddChatMessage("{00FF00}[FearzMine ON]", -1)
        end
    end)

    -- Menú en chat (reemplaza ImGui)
    sampRegisterChatCommand("minefearzmenu", function()
        mostrarMenu()
    end)

    -- Cambiar modo de interacción con el nodo
    sampRegisterChatCommand("minefearzmodo", function()
        if modoInteraccion == "gamekey" then
            modoInteraccion = "chat"
            sampAddChatMessage("{FFFF00}[FearzMine]: Modo CHAT activado (envia 'N' por chat)", -1)
        else
            modoInteraccion = "gamekey"
            sampAddChatMessage("{00CCFF}[FearzMine]: Modo GAMEKEY activado (setGameKeyState)", -1)
        end
    end)

    -- ══════════════════════════════════
    --  Bucle principal
    -- ══════════════════════════════════
    while true do
        wait(0)

        if teclaPendiente then
            responderTextdraw(teclaPendiente)
            teclaPulsada   = true
            teclaPendiente = nil
        end

        if botActivo then
            if estado == STATUS.GO_TO_MINE then
                moverA(puntos_minado[1][1], puntos_minado[1][2], puntos_minado[1][3], true)
                estado = STATUS.PRESS_N

            elseif estado == STATUS.PRESS_N then
                simularInteraccionMinado(tiempo_pulsarN)
                estado = STATUS.MINING_WAIT

            elseif estado == STATUS.MINING_WAIT then
                detectarLetras = true
                wait(tiempo_minado)
                estado = STATUS.WAIT_FOR_LETTER

            elseif estado == STATUS.WAIT_FOR_LETTER then
                detectarLetras = false
                estado = STATUS.GO_TO_DESVIO

            elseif estado == STATUS.GO_TO_DESVIO then
                moverA(rutas_desvio[2][1], rutas_desvio[2][2], rutas_desvio[2][3], true, true)
                moverA(rutas_desvio[1][1], rutas_desvio[1][2], rutas_desvio[1][3], true, true)
                moverA(punto_descarga[1],  punto_descarga[2],  punto_descarga[3],  true)
                estado = STATUS.DESCARGANDO

            elseif estado == STATUS.DESCARGANDO then
                wait(tiempo_descarga)
                estado = STATUS.RETURNING

            elseif estado == STATUS.RETURNING then
                moverA(rutas_desvio[1][1], rutas_desvio[1][2], rutas_desvio[1][3], true, true)
                moverA(rutas_desvio[2][1], rutas_desvio[2][2], rutas_desvio[2][3], true, true)
                local punto = obtenerPuntoMinadoAleatorio()
                moverA(punto[1], punto[2], punto[3], true)
                teclaPulsada = false
                estado = STATUS.PRESS_N
            end
        end
    end
end
