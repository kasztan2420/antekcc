script_name('antek.cc')
script_author('antek')
script_version('1.2.0')
script_description('antek.cc: Tracker, Graffiti, Kasyno, Gornik, Bilard, SAMPGPT, Strefy, Statuetki w jednym menu. SF.lua + SAMP-API + mimgui')
script_properties('work-in-pause')

-- Plik celowo w 100% ASCII: kodowanie pliku nie ma znaczenia dla MoonLoadera.
-- Dane: moonloader\config\antek\*.json (+ pliki SAMPGPT: moonloader\config\sampgpt_*.txt).
-- Przy pierwszym starcie importuje stare ustawienia: TagBlips.json, pooltracer.lua, PlayerTracker_*.txt.

pcall(require, 'moonloader')

local ffi = require 'ffi'
local bit = require 'bit'

local A = {
    VERSION = '1.2',
    ffi = ffi,
    bit = bit,
    mods = {},          -- id -> modul
    order = {},         -- kolejnosc zakladek
    menuOpen = false,
    drawOk = true,      -- false w menu pauzy (nic nie rysujemy na menu GTA)
}

local json = {}
do
    local ESCAPE_OUT = {
        ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
        ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
    }
    local function esc(s)
        s = s:gsub('[%c"\\]', function(c)
            return ESCAPE_OUT[c] or string.format('\\u%04x', c:byte())
        end)
        return '"' .. s .. '"'
    end

    local function is_array(t)
        local n = 0
        for k in pairs(t) do
            if type(k) ~= 'number' or k <= 0 or k % 1 ~= 0 then return false end
            n = n + 1
        end
        if n == 0 then return false end
        for i = 1, n do
            if t[i] == nil then return false end
        end
        return true
    end

    local encode
    encode = function(v)
        local tv = type(v)
        if tv == 'nil' then return 'null' end
        if tv == 'boolean' then return v and 'true' or 'false' end
        if tv == 'number' then
            if v ~= v or v == math.huge or v == -math.huge then return 'null' end
            if v % 1 == 0 and math.abs(v) < 1e15 then return string.format('%d', v) end
            return string.format('%.14g', v)
        end
        if tv == 'string' then return esc(v) end
        if tv == 'table' then
            local out = {}
            if is_array(v) then
                for i = 1, #v do out[i] = encode(v[i]) end
                return '[' .. table.concat(out, ',') .. ']'
            end
            for k, val in pairs(v) do
                local tval = type(val)
                if tval ~= 'function' and tval ~= 'userdata' and tval ~= 'thread' then
                    out[#out + 1] = esc(tostring(k)) .. ':' .. encode(val)
                end
            end
            return '{' .. table.concat(out, ',') .. '}'
        end
        return 'null'
    end

    local function fail(pos, msg) error('JSON: ' .. msg .. ' (pozycja ' .. tostring(pos) .. ')', 0) end
    local function skip_ws(str, pos) return str:find('[^ \t\r\n]', pos) or (#str + 1) end

    local function utf8_char(cp)
        if cp < 0x80 then return string.char(cp) end
        if cp < 0x800 then
            return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
        end
        if cp < 0x10000 then
            return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
        end
        return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
            0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end

    local ESCAPE_IN = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

    local function parse_string(str, pos)
        local buf = {}
        local i = pos + 1
        while true do
            local s = str:find('["\\]', i)
            if not s then fail(pos, 'niezamkniety string') end
            if s > i then buf[#buf + 1] = str:sub(i, s - 1) end
            if str:sub(s, s) == '"' then return table.concat(buf), s + 1 end
            local c = str:sub(s + 1, s + 1)
            if c == 'u' then
                local cp = tonumber(str:sub(s + 2, s + 5), 16)
                if not cp then fail(s, 'zle \\u') end
                local nxt = s + 6
                if cp >= 0xD800 and cp <= 0xDBFF and str:sub(nxt, nxt + 1) == '\\u' then
                    local lo = tonumber(str:sub(nxt + 2, nxt + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
                        nxt = nxt + 6
                    end
                end
                buf[#buf + 1] = utf8_char(cp)
                i = nxt
            else
                local r = ESCAPE_IN[c]
                if not r then fail(s, 'zly escape') end
                buf[#buf + 1] = r
                i = s + 2
            end
        end
    end

    local parse
    parse = function(str, pos)
        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == '{' then
            local obj = {}
            pos = skip_ws(str, pos + 1)
            if str:sub(pos, pos) == '}' then return obj, pos + 1 end
            while true do
                pos = skip_ws(str, pos)
                if str:sub(pos, pos) ~= '"' then fail(pos, 'oczekiwano klucza') end
                local key
                key, pos = parse_string(str, pos)
                pos = skip_ws(str, pos)
                if str:sub(pos, pos) ~= ':' then fail(pos, "oczekiwano ':'") end
                local val
                val, pos = parse(str, pos + 1)
                obj[key] = val
                pos = skip_ws(str, pos)
                local d = str:sub(pos, pos)
                if d == '}' then return obj, pos + 1 end
                if d ~= ',' then fail(pos, "oczekiwano ',' lub '}'") end
                pos = pos + 1
            end
        elseif c == '[' then
            local arr, n = {}, 0
            pos = skip_ws(str, pos + 1)
            if str:sub(pos, pos) == ']' then return arr, pos + 1 end
            while true do
                local val
                val, pos = parse(str, pos)
                n = n + 1
                arr[n] = val
                pos = skip_ws(str, pos)
                local d = str:sub(pos, pos)
                if d == ']' then return arr, pos + 1 end
                if d ~= ',' then fail(pos, "oczekiwano ',' lub ']'") end
                pos = pos + 1
            end
        elseif c == '"' then
            return parse_string(str, pos)
        elseif str:sub(pos, pos + 3) == 'true' then
            return true, pos + 4
        elseif str:sub(pos, pos + 4) == 'false' then
            return false, pos + 5
        elseif str:sub(pos, pos + 3) == 'null' then
            return nil, pos + 4
        end
        local s, e = str:find('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
        if not s then fail(pos, 'nieoczekiwany znak') end
        local num = tonumber(str:sub(s, e))
        if not num then fail(pos, 'zla liczba') end
        return num, e + 1
    end

    function json.encode(v)
        return encode(v)
    end

    function json.decode(str)
        str = tostring(str or ''):gsub('^\239\187\191', '')
        local v, pos = parse(str, 1)
        pos = skip_ws(str, pos)
        if pos <= #str then fail(pos, 'smieci na koncu') end
        return v
    end
end

A.json = json

-- ============================================================================
-- CORE: pomocnicze
-- ============================================================================
do
local floor, max, min = math.floor, math.max, math.min

-- wolane setki razy na klatke: bez pcall i bez sprawdzania typu przy kazdym wywolaniu
local clockFn = os.clock
if type(localClock) == 'function' then
    local ok, t = pcall(localClock)
    if ok and type(t) == 'number' then clockFn = localClock end
end
function A.now() return clockFn() end

function A.trim(s)
    s = tostring(s or '')
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

function A.readFile(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local d = f:read('*a')
    f:close()
    return d
end

function A.writeFile(path, data)
    local f = io.open(path, 'wb')
    if not f then return false end
    local ok = f:write(data)
    f:close()
    return ok ~= nil
end

function A.fileExists(path)
    if type(doesFileExist) == 'function' then
        local ok, r = pcall(doesFileExist, path)
        if ok then return r == true end
    end
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    return false
end

function A.log(tag, msg)
    print('[' .. tostring(tag) .. '] ' .. tostring(msg))
end

A.WD  = getWorkingDirectory()
A.DIR = A.WD .. '\\config\\antek'

function A.mkdir(path)
    if type(createDirectory) == 'function' then
        pcall(createDirectory, path)
        return
    end
    pcall(function() ffi.C.CreateDirectoryA(path, nil) end)
end

function A.ensureDirs()
    A.mkdir(A.WD .. '\\config')
    A.mkdir(A.DIR)
end

function A.deepCopy(t)
    local r = {}
    for k, v in pairs(t) do r[k] = type(v) == 'table' and A.deepCopy(v) or v end
    return r
end

-- nadpisuje tylko klucze istniejace w base i tylko tym samym typem
function A.overlay(base, over)
    for k, v in pairs(over) do
        local b = base[k]
        if type(b) == 'table' and type(v) == 'table' then
            A.overlay(b, v)
        elseif b ~= nil and type(b) == type(v) then
            base[k] = v
        end
    end
end

function A.clamp(v, lo, hi)
    if hi < lo then hi = lo end
    return max(lo, min(hi, v))
end

-- Zapis: plik.tmp -> rename (crash gry w trakcie zapisu nie zostawia ucietego JSON-a).
-- A.saveJson tylko koduje i odklada; na dysk trafia w A.flushSaves (main co 0.5 s + przy wyladowaniu),
-- wiec suwak przeciagany w menu nie pisze pliku co klatke, a identyczna tresc nie jest zapisywana wcale.
local pendingSaves, lastSaved = {}, {}

local function writeAtomic(path, s)
    local tmp = path .. '.tmp'
    if not A.writeFile(tmp, s) then
        A.ensureDirs()
        if not A.writeFile(tmp, s) then return false end
    end
    os.remove(path)
    if os.rename(tmp, path) then return true end
    os.remove(tmp)
    return A.writeFile(path, s)
end

function A.loadJson(path)
    local d = A.readFile(path)
    if not d or d == '' then
        d = A.readFile(path .. '.tmp')                  -- crash miedzy remove a rename
        if not d or d == '' then return nil end
    end
    local ok, t = pcall(json.decode, d)
    if ok and type(t) == 'table' then
        lastSaved[path] = d
        return t
    end
    os.remove(path .. '.bak')
    os.rename(path, path .. '.bak')
    A.log('antek.cc', 'uszkodzony plik ' .. path .. ' (kopia w .bak): ' .. tostring(t))
    return nil
end

function A.saveJson(path, t)
    local ok, s = pcall(json.encode, t)
    if not ok then
        A.log('antek.cc', 'json.encode: ' .. tostring(s))
        return false
    end
    pendingSaves[path] = lastSaved[path] ~= s and s or nil
    return true
end

function A.flushSaves()
    for path, s in pairs(pendingSaves) do
        pendingSaves[path] = nil
        if writeAtomic(path, s) then
            lastSaved[path] = s
        else
            A.log('antek.cc', 'nie moge zapisac ' .. path)
        end
    end
end

-- ---------------------------------------------------------------- kodowanie
-- Gra = CP1250, mimgui = UTF-8. Mapujemy polskie litery, reszta -> '?'.
local CP2U = {
    [0xA5] = 0x0104, [0xB9] = 0x0105, [0xC6] = 0x0106, [0xE6] = 0x0107,
    [0xCA] = 0x0118, [0xEA] = 0x0119, [0xA3] = 0x0141, [0xB3] = 0x0142,
    [0xD1] = 0x0143, [0xF1] = 0x0144, [0xD3] = 0x00D3, [0xF3] = 0x00F3,
    [0x8C] = 0x015A, [0x9C] = 0x015B, [0x8F] = 0x0179, [0x9F] = 0x017A,
    [0xAF] = 0x017B, [0xBF] = 0x017C,
}
A.CP1250 = CP2U
-- tabele dla gsub (brak w tabeli -> '?'), zamiast nowej closure przy kazdym wywolaniu
local unknownQ = { __index = function() return '?' end }
local CP2U8, U82CP = setmetatable({}, unknownQ), setmetatable({}, unknownQ)
for b, cp in pairs(CP2U) do
    local u = string.char(0xC0 + floor(cp / 64), 0x80 + cp % 64)
    CP2U8[string.char(b)] = u
    U82CP[u] = string.char(b)
end

function A.u8(s)
    s = tostring(s or '')
    if not s:find('[\128-\255]') then return s end
    return (s:gsub('[\128-\255]', CP2U8))
end

function A.cp(s)
    s = tostring(s or '')
    if not s:find('[\128-\255]') then return s end
    s = s:gsub('[\192-\223][\128-\191]', U82CP)
    return (s:gsub('[\224-\255][\128-\191]*', '?'))
end

function A.stripColors(s)
    return (tostring(s or ''):gsub('{%x%x%x%x%x%x}', ''))
end

end -- pomocnicze

-- ============================================================================
-- CORE: biblioteki (SF.lua, SAMP-API, mimgui, samp.events)
-- ============================================================================
do
local function exportModule(mod)
    if type(mod) ~= 'table' then return end
    for k, v in pairs(mod) do
        if type(k) == 'string' and type(v) == 'function' and rawget(_G, k) == nil then _G[k] = v end
    end
end

function A.loadSF()
    if A.sf then return true end
    if type(sampAddChatMessage) == 'function' and type(sampGetChatString) == 'function' then
        A.sf = true
        return true
    end
    for _, name in ipairs({ 'sflua', 'SFlua', 'SF', 'sf', 'sflua.init', 'SFlua.init' }) do
        local ok, mod = pcall(require, name)
        if ok then
            exportModule(mod)
            A.sf = true
            return true
        end
        local msg = tostring(mod)
        if not msg:find("module '" .. name .. "' not found", 1, true) then A.sfErr = msg end
    end
    local init = A.WD .. '\\lib\\SFlua\\init.lua'
    if A.fileExists(init) then
        local ok, mod = pcall(dofile, init)
        if ok then
            exportModule(mod)
            A.sf = true
            return true
        end
        A.sfErr = tostring(mod)
    end
    A.sfErr = A.sfErr or 'nie znaleziono SF.lua w moonloader\\lib'
    return false
end
A.loadSF()

local okSA, sampapi = pcall(require, 'sampapi')
A.sampapi = okSA and type(sampapi) == 'table' and sampapi or nil
if not A.sampapi then A.sampapiErr = tostring(sampapi) end

local okIm, imgui = pcall(require, 'mimgui')
A.imgui = okIm and type(imgui) == 'table' and imgui or nil
if not A.imgui then A.imguiErr = tostring(imgui) end
end -- biblioteki

-- ============================================================================
-- CORE: konfiguracja glowna
-- ============================================================================
A.CORE_FILE = A.DIR .. '\\antek.json'
A.cfg = {
    menuKey    = 0x2D,     -- Insert
    menuMods   = 0,        -- 1 Ctrl, 2 Shift, 4 Alt
    panicKey   = 0,        -- 0 = nieustawiony
    panicMods  = 0,
    jitOff     = true,     -- jak w SAMPGPT: JIT wylaczony (stabilnosc z SF.lua)
    chatPollMs = 50,
    tab        = 'tracker',
    modules    = { tracker = true, graffiti = true, statuetki = true, walizki = true, strefy = true, pool = true,
                   gpt = true, autoy = true, karta = true, gornik = true },
    hud        = {},       -- id -> { fx, fy }
}

function A.loadCore()
    local t = A.loadJson(A.CORE_FILE)
    if not t then return false end
    local hud, mods = t.hud, t.modules
    t.hud, t.modules = nil, nil
    A.overlay(A.cfg, t)
    if type(hud) == 'table' then
        for k, v in pairs(hud) do
            if type(v) == 'table' and tonumber(v[1]) and tonumber(v[2]) then
                A.cfg.hud[k] = { tonumber(v[1]), tonumber(v[2]) }
            end
        end
    end
    -- kazdy zapisany przelacznik (overlay pomijal moduly spoza listy domyslnej - np. wylaczony gornik wracal po restarcie)
    if type(mods) == 'table' then
        for k, v in pairs(mods) do
            if type(k) == 'string' and type(v) == 'boolean' then A.cfg.modules[k] = v end
        end
    end
    return true
end

function A.saveCore()
    return A.saveJson(A.CORE_FILE, A.cfg)
end

A.ensureDirs()
A.loadCore()
-- v1.4: stan modulow z configu jest respektowany (wczesniej wymuszalismy ON przy kazdym starcie)
A.saveCore()

-- samp.events tylko gdy bilard wlaczony (kazde RPC przechodzi wtedy przez Lua)
if A.cfg.modules.pool ~= false then
    local ok, ev = pcall(require, 'lib.samp.events')
    A.sev = ok and type(ev) == 'table' and ev or nil
end

-- ============================================================================
-- CORE: SA-MP, czat, stan wejscia
-- ============================================================================
do
local sa = A.sampapi
local netgame, inputApi, dialogApi, chatApi
if sa then
    local ok
    ok, netgame = pcall(sa.require, 'CNetGame', true);  if not ok then netgame = nil end
    ok, inputApi = pcall(sa.require, 'CInput', true);   if not ok then inputApi = nil end
    ok, dialogApi = pcall(sa.require, 'CDialog', true); if not ok then dialogApi = nil end
    ok, chatApi = pcall(sa.require, 'CChat', true);     if not ok then chatApi = nil end
end
A.netgameApi = netgame

local ENTRY_DEBUG = 8
pcall(function() ENTRY_DEBUG = ffi.C.ENTRY_TYPE_DEBUG end)

function A.sampReady()
    if type(isSampAvailable) == 'function' then
        local ok, r = pcall(isSampAvailable)
        return ok and r == true
    end
    if type(netgame) == 'table' and type(netgame.RefNetGame) == 'function' then
        local ok, ng = pcall(netgame.RefNetGame)
        return ok and ng ~= nil
    end
    return false
end

local function refFlag(api, refName, field)
    if type(api) ~= 'table' or type(api[refName]) ~= 'function' then return false end
    local ok, v = pcall(function()
        local p = api[refName]()
        if p == nil then return false end
        local okF, val = pcall(function() return p[field] end)
        if not okF then
            p = p[0]
            if p == nil then return false end
            val = p[field]
        end
        return val ~= 0 and val ~= false
    end)
    return ok and v or false
end

local function sfFlag(name)
    local f = _G[name]
    if type(f) ~= 'function' then return nil end
    local ok, v = pcall(f)
    return ok and v == true
end

function A.chatInputActive()
    local c = sfFlag('sampIsChatInputActive')
    if c == nil then c = refFlag(inputApi, 'RefInputBox', 'm_bEnabled') end
    return c
end

function A.dialogActive()
    local d = sfFlag('sampIsDialogActive')
    if d == nil then d = refFlag(dialogApi, 'RefDialog', 'm_bIsActive') end
    return d
end

function A.pauseActive()
    if type(isPauseMenuActive) ~= 'function' then return false end
    local ok, r = pcall(isPauseMenuActive)
    return ok and r == true
end

-- gracz cos wpisuje / ma dialog / menu pauzy: skroty ignorowane
function A.inputBlocked()
    return A.pauseActive() or A.chatInputActive() or A.dialogActive()
end

-- '%' potrafi wywalic gre, jesli funkcja czatu traktuje tekst jak format printf
function A.chat(text, color)
    text = tostring(text):gsub('[\r\n\t]+', ' '):gsub('%%', ' proc.')
    color = color or -1
    if A.ready and type(sampAddChatMessage) == 'function' and pcall(sampAddChatMessage, text, color) then return end
    if chatApi and type(chatApi.RefChat) == 'function' then
        local ok = pcall(function() chatApi.RefChat():AddEntry(ENTRY_DEBUG, text, '', color, 0xFFFFFFFF) end)
        if ok then return end
    end
    print(A.stripColors(text))
end

-- okno gry na pierwszym planie (okno nalezy do procesu gry); wolane co klatke przez boty
local pidBuf
local function foreground()
    if not pidBuf then
        A.pid = ffi.C.GetCurrentProcessId()
        pidBuf = ffi.new('uint32_t[1]')
    end
    local h = ffi.C.GetForegroundWindow()
    if h == nil then return false end
    ffi.C.GetWindowThreadProcessId(h, pidBuf)
    return pidBuf[0] == A.pid
end

function A.gameFocused()
    local ok, r = pcall(foreground)
    return not ok or r
end

-- stan Ctrl(1) / Shift(2) / Alt(4)
function A.modState()
    local m = 0
    pcall(function()
        if ffi.C.GetAsyncKeyState(0x11) < 0 then m = m + 1 end
        if ffi.C.GetAsyncKeyState(0x10) < 0 then m = m + 2 end
        if ffi.C.GetAsyncKeyState(0x12) < 0 then m = m + 4 end
    end)
    return m
end

function A.comboHit(vk, mods, wparam)
    return vk ~= nil and vk ~= 0 and wparam == vk and A.modState() == (mods or 0)
end

-- komenda do serwera (zamyka menu); bez SF.lua tylko wpisuje do czatu
function A.sendCommand(cmd)
    if A.setMenu then A.setMenu(false) end
    if type(sampSendChat) == 'function' and pcall(sampSendChat, cmd) then return end
    if type(sampSetChatInputEnabled) == 'function' then
        pcall(sampSetChatInputEnabled, true)
        pcall(sampSetChatInputText, cmd)
    end
end

-- komunikat modulu: {kolor}[tag]{bialy} tekst
function A.say(tag, text, col)
    A.chat('{' .. (col or 'B48CFF') .. '}[' .. tag .. ']{FFFFFF} ' .. tostring(text))
end
end -- samp

-- ============================================================================
-- CORE: FFI (WinAPI) - deklarowane PO zaladowaniu SF.lua, kazda osobno
-- ============================================================================
do
local function cdef(s) pcall(ffi.cdef, s) end

function A.initFFI()
    if A.ffiReady then return end
    cdef[[
        typedef struct {
            uint32_t cb; char *lpReserved; char *lpDesktop; char *lpTitle;
            uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize;
            uint32_t dwXCountChars; uint32_t dwYCountChars; uint32_t dwFillAttribute; uint32_t dwFlags;
            uint16_t wShowWindow; uint16_t cbReserved2; uint8_t *lpReserved2;
            void *hStdInput; void *hStdOutput; void *hStdError;
        } AK_STARTUPINFOA;
    ]]
    cdef[[ typedef struct { void *hProcess; void *hThread; uint32_t dwProcessId; uint32_t dwThreadId; } AK_PROCESS_INFORMATION; ]]
    cdef[[ int CreateProcessA(const char *app, char *cmd, void *pa, void *ta, int inherit, uint32_t flags, void *env, const char *cwd, AK_STARTUPINFOA *si, AK_PROCESS_INFORMATION *pi); ]]
    cdef[[ uint32_t WaitForSingleObject(void *h, uint32_t ms); ]]
    cdef[[ int GetExitCodeProcess(void *h, uint32_t *code); ]]
    cdef[[ int TerminateProcess(void *h, uint32_t code); ]]
    cdef[[ int CloseHandle(void *h); ]]
    cdef[[ uint32_t GetLastError(void); ]]
    cdef[[ int CreateDirectoryA(const char *path, void *security); ]]
    cdef[[ int IsBadReadPtr(const void *lp, uintptr_t ucb); ]]
    cdef[[ void keybd_event(uint8_t vk, uint8_t scan, uint32_t flags, uintptr_t extra); ]]
    cdef[[ int16_t GetAsyncKeyState(int vk); ]]
    cdef[[ uint32_t MapVirtualKeyA(uint32_t code, uint32_t mapType); ]]
    cdef[[ void *GetForegroundWindow(void); ]]
    cdef[[ uint32_t GetWindowThreadProcessId(void *hwnd, uint32_t *pid); ]]
    cdef[[ uint32_t GetCurrentProcessId(void); ]]
    cdef[[ typedef struct { int32_t x; int32_t y; } AK_POINT; ]]
    cdef[[ typedef struct { int32_t l; int32_t t; int32_t r; int32_t b; } AK_RECT; ]]
    cdef[[ int SetCursorPos(int x, int y); ]]
    cdef[[ int ClientToScreen(void *hwnd, AK_POINT *p); ]]
    cdef[[ int GetClientRect(void *hwnd, AK_RECT *r); ]]
    cdef[[ void mouse_event(uint32_t flags, uint32_t dx, uint32_t dy, uint32_t data, uintptr_t extra); ]]
    A.ffiReady = true
end

-- Procesy (curl.exe, powershell.exe) BEZ okna konsoli i BEZ blokowania gry.
A.proc = {}

function A.proc.spawn(cmdline)
    if not A.ffiReady then return nil, 'FFI niegotowe' end
    local ok, p, err = pcall(function()
        local si = ffi.new('AK_STARTUPINFOA')
        si.cb = ffi.sizeof('AK_STARTUPINFOA')
        si.dwFlags = 0x00000001       -- STARTF_USESHOWWINDOW
        si.wShowWindow = 0            -- SW_HIDE
        local pi = ffi.new('AK_PROCESS_INFORMATION')
        local buf = ffi.new('char[?]', #cmdline + 1)
        ffi.copy(buf, cmdline)
        if ffi.C.CreateProcessA(nil, buf, nil, nil, 0, 0x08000000, nil, nil, si, pi) == 0 then -- CREATE_NO_WINDOW
            return nil, 'CreateProcess: kod ' .. tostring(ffi.C.GetLastError())
        end
        ffi.C.CloseHandle(pi.hThread)
        return { h = pi.hProcess }
    end)
    if not ok then return nil, tostring(p) end
    return p, err
end

function A.proc.running(p)
    return p ~= nil and p.h ~= nil and ffi.C.WaitForSingleObject(p.h, 0) == 258 -- WAIT_TIMEOUT
end

-- zamyka uchwyt i zwraca kod wyjscia (zapamietany w p.code)
function A.proc.finish(p)
    if not p then return -1 end
    if p.h == nil then return p.code or -1 end
    local c = ffi.new('uint32_t[1]')
    ffi.C.GetExitCodeProcess(p.h, c)
    ffi.C.CloseHandle(p.h)
    p.h = nil
    p.code = tonumber(c[0])
    return p.code
end

function A.proc.kill(p)
    if not p or p.h == nil then return end
    pcall(function()
        ffi.C.TerminateProcess(p.h, 1)
        ffi.C.CloseHandle(p.h)
    end)
    p.h = nil
end
end -- ffi

-- ============================================================================
-- CORE: watki z nadzorem (SF.lua potrafi zabic watek bledem, ktorego pcall
-- nie lapie: "cannot resume non-suspended coroutine" - wtedy watek jest wznawiany)
-- ============================================================================
do
local workers = {}
A.restarts = 0
A.frameNo = 0          -- licznik klatek petli main

-- modId: watek modulu - gdy modul jest wylaczony, watek tylko spi (zero logiki w tle)
function A.worker(name, body, modId)
    local w = { name = name, fails = 0, nextRestart = 0 }
    w.th = lua_thread.create(function()
        while true do
            while modId and A.cfg.modules[modId] == false do wait(250) end
            local f0 = A.frameNo
            local ok, err = pcall(body)
            if not ok then
                A.log('antek.cc', 'blad w watku ' .. name .. ': ' .. tostring(err))
                wait(1000)
            elseif A.frameNo == f0 then
                wait(0)        -- przebieg bez zadnego wait (np. wczesny return) - inaczej petla zamrozi gre
            end
        end
    end)
    workers[#workers + 1] = w
    return w
end

function A.threadAlive(th)
    local ok, st = pcall(function() return th:status() end)
    if not ok then return true end
    return st ~= 'dead' and st ~= 'error'
end

function A.supervise()
    local t = A.now()
    for _, w in ipairs(workers) do
        if not A.threadAlive(w.th) and t >= w.nextRestart then
            w.fails = w.fails + 1
            A.restarts = A.restarts + 1
            w.nextRestart = t + math.min(10, w.fails)
            A.log('antek.cc', 'watek "' .. w.name .. '" padl (blad SF.lua) - wznawiam (' .. w.fails .. ')')
            pcall(function() w.th:run() end)
        end
    end
end
end -- watki

-- ============================================================================
-- CORE: wspolny odczyt czatu (jeden skaner dla wszystkich modulow)
-- Linia: { text, prefix (bez kolorow), color, key }. Subskrybent dostaje paczke nowych linii.
-- ============================================================================
do
local SIZE, VERIFY = 100, 5
local subs = {}
local prev = nil

function A.onChat(id, fn)
    subs[#subs + 1] = { id = id, fn = fn }
end

local function readLine(i)                 -- i = 0: najnowsza linia
    local t, p, c = sampGetChatString(99 - i)
    t = type(t) == 'string' and t or ''
    p = type(p) == 'string' and p or ''
    return { text = t, prefix = A.stripColors(p), color = c, key = t .. '\31' .. p .. '\31' .. tostring(c) }
end

local function newLines()
    if not prev then
        prev = {}
        for i = 0, SIZE - 1 do prev[i] = readLine(i) end
        return nil
    end
    local c0, c1, c2 = readLine(0), readLine(1), readLine(2)
    if c0.key == prev[0].key and c1.key == prev[1].key and c2.key == prev[2].key then return nil end

    local cache = { [0] = c0, [1] = c1, [2] = c2 }
    local function cur(i)
        local v = cache[i]
        if not v then
            v = readLine(i)
            cache[i] = v
        end
        return v
    end

    local shift = SIZE
    for k = 1, SIZE - 1 do
        local match = true
        for j = 0, math.min(VERIFY, SIZE - k) - 1 do
            if cur(k + j).key ~= prev[j].key then match = false; break end
        end
        if match then shift = k; break end
    end

    local out = {}
    for i = shift - 1, 0, -1 do out[#out + 1] = cur(i) end
    local nxt = {}
    for i = 0, SIZE - 1 do
        if i < shift then nxt[i] = cur(i) else nxt[i] = prev[i - shift] end
    end
    prev = nxt
    return out
end

function A.startChatFeed()
    A.worker('czat', function()
        wait(A.cfg.chatPollMs)
        if type(sampGetChatString) ~= 'function' then wait(1000); return end
        local any = false
        for _, s in ipairs(subs) do
            if A.isOn(s.id) then any = true; break end
        end
        if not any then prev = nil; return end
        local ok, lines = pcall(newLines)
        if not ok then
            A.log('antek.cc', 'odczyt czatu: ' .. tostring(lines))
            prev = nil
            wait(1000)
            return
        end
        if not lines or #lines == 0 then return end
        local t = A.now()                           -- czas odczytu linii (HUD-y licza od niego, nie od przetworzenia)
        for _, l in ipairs(lines) do l.t = t end
        for _, s in ipairs(subs) do
            if A.isOn(s.id) then
                local okS, err = pcall(s.fn, lines)
                if not okS then A.log(s.id, 'czat: ' .. tostring(err)) end
            end
        end
    end)
end
end -- czat

-- ============================================================================
-- CORE: HUD-y przeciagane mysza (gdy menu jest otwarte)
-- ============================================================================
do
local floor, max, min = math.floor, math.max, math.min
A.sw, A.sh = 1920, 1080
A.hud = { rects = {}, drag = nil }

-- zwraca lewy gorny rog pudelka w px; pozycja zapisana jako ulamek ekranu
function A.hudPlace(id, w, h, dfx, dfy)
    local p = A.cfg.hud[id]
    local fx, fy = p and p[1] or dfx, p and p[2] or dfy
    local x = floor(max(0, min(A.sw - w, fx * A.sw)))
    local y = floor(max(0, min(A.sh - h, fy * A.sh)))
    local r = A.hud.rects[id]
    if not r then r = {}; A.hud.rects[id] = r end
    r.x, r.y, r.w, r.h, r.t = x, y, w, h, A.now()
    if A.menuOpen and type(renderDrawBox) == 'function' then
        local c = (A.hud.drag and A.hud.drag.id == id) and 0xFFFFFFFF or 0xFFB48CFF
        renderDrawBox(x - 1, y - 1, w + 2, 1, c)
        renderDrawBox(x - 1, y + h, w + 2, 1, c)
        renderDrawBox(x - 1, y - 1, 1, h + 2, c)
        renderDrawBox(x + w, y - 1, 1, h + 2, c)
    end
    return x, y
end

-- wolane z klatki mimgui (wlasna detekcja klikniecia - nie zalezy od IsMouseClicked)
local mouseWas = false
function A.hudDragFrame()
    local imgui = A.imgui
    local m = imgui.GetMousePos()
    local isDown = imgui.IsMouseDown(0) == true
    local clicked = isDown and not mouseWas
    mouseWas = isDown
    local d = A.hud.drag
    if not d then
        if clicked then
            local okC, cap = pcall(function() return imgui.GetIO().WantCaptureMouse end)
            if okC and cap == true then return end
            local t = A.now()
            for id, r in pairs(A.hud.rects) do
                if t - r.t < 0.5 and m.x >= r.x - 4 and m.x <= r.x + r.w + 4 and m.y >= r.y - 4 and m.y <= r.y + r.h + 4 then
                    A.hud.drag = { id = id, ox = m.x - r.x, oy = m.y - r.y }
                    break
                end
            end
        end
    elseif isDown then
        local r = A.hud.rects[d.id]
        if r then
            local x = max(0, min(A.sw - r.w, m.x - d.ox))
            local y = max(0, min(A.sh - r.h, m.y - d.oy))
            A.cfg.hud[d.id] = { x / A.sw, y / A.sh }
        end
    else
        A.hud.drag = nil
        A.saveCore()
    end
end

function A.hudReset(id)
    if id then A.cfg.hud[id] = nil else A.cfg.hud = {} end
    A.saveCore()
end
end -- hud

-- ============================================================================
-- CORE: moduly
-- ============================================================================
-- modul: { id, title, init(), frame(now), menu(), disable(), terminate(quit) }
function A.register(m)
    A.mods[m.id] = m
    local pos = #A.order + 1
    if m.after then
        for i, o in ipairs(A.order) do
            if o.id == m.after then pos = i + 1 end
        end
    end
    table.insert(A.order, pos, m)
    return m
end

function A.isOn(id)
    local m = A.mods[id]
    return m ~= nil and m.ready == true and A.cfg.modules[id] ~= false
end

function A.initModule(m)
    if m.ready then return true end
    local ok, err = pcall(m.init)
    if ok then
        m.ready = true
        return true
    end
    m.initErr = tostring(err)
    A.log('antek.cc', 'modul ' .. m.id .. ' nie wystartowal: ' .. m.initErr)
    return false
end

-- zmiana z menu (watek mimgui) - init odpalamy w watku skryptu
function A.setModule(id, on)
    A.cfg.modules[id] = on
    A.saveCore()
    local m = A.mods[id]
    if not m then return end
    if on then
        if not m.ready then A.pendingInit = A.pendingInit or {}; A.pendingInit[#A.pendingInit + 1] = m end
    elseif m.ready and m.disable then
        local ok, err = pcall(m.disable)
        if not ok then A.log(id, 'disable: ' .. tostring(err)) end
    end
end

-- ============================================================================
-- CORE: nawigacja - A* po kolizji gry (processLineOfSight / isLineOfSightClear, budynki + obiekty SA-MP)
-- Siatka budowana leniwie, liczona po kawalku co klatke (budzet czasu), krawedzie w cache.
-- Kazdy modul tworzy wlasna instancje (A.newNav) z wlasnymi parametrami: pieszo (gornik), motor (graffiti).
-- ============================================================================
do
local floor, nmax, nmin, nsqrt, nceil = math.floor, math.max, math.min, math.sqrt, math.ceil
local DIRS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }

local function los(x1, y1, z1, x2, y2, z2)
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    if dx * dx + dy * dy + dz * dz < 1e-4 then return true end
    return isLineOfSightClear(x1, y1, z1, x2, y2, z2, true, false, false, true, false)
end

local function ray(x1, y1, z1, x2, y2, z2)
    local dx, dy, dz = x2 - x1, y2 - y1, z2 - z1
    if dx * dx + dy * dy + dz * dz < 1e-4 then return nil end
    local hit, cp = processLineOfSight(x1, y1, z1, x2, y2, z2, true, false, false, true, false, false, false, false)
    if hit and cp then return cp end
    return nil
end

-- srodek obiektu (CPlaceable: macierz +0x14 -> pozycja +0x30, bez macierzy pozycja +0x04);
-- kazdy odczyt sprawdzany IsBadReadPtr - zly wskaznik nie moze wywalic gry; nil = nie da sie odczytac
local function entityPos(ptr)
    local ffi = A.ffi
    if not A.ffiReady or type(ptr) ~= 'number' or ptr < 0x10000 then return nil end
    if ffi.C.IsBadReadPtr(ffi.cast('void*', ptr), 0x18) ~= 0 then return nil end
    local p = ffi.cast('uint8_t*', ptr)
    local m = tonumber(ffi.cast('uint32_t*', p + 0x14)[0])
    local f
    if m >= 0x10000 and ffi.C.IsBadReadPtr(ffi.cast('void*', m + 0x30), 8) == 0 then
        f = ffi.cast('float*', m + 0x30)
    else
        f = ffi.cast('float*', p + 0x04)
    end
    local x, y = f[0], f[1]
    if x ~= x or y ~= y then return nil end
    return x, y
end

local function hpush(h, e)
    local i = #h + 1
    h[i] = e
    while i > 1 do
        local q = floor(i / 2)
        if h[q].f <= h[i].f then break end
        h[i], h[q] = h[q], h[i]
        i = q
    end
end

local function hpop(h)
    local n = #h
    if n == 0 then return nil end
    local top = h[1]
    h[1] = h[n]
    h[n] = nil
    n = n - 1
    local i = 1
    while true do
        local l, r, s = i * 2, i * 2 + 1, i
        if l <= n and h[l].f < h[s].f then s = l end
        if r <= n and h[r].f < h[s].f then s = r end
        if s == i then break end
        h[i], h[s] = h[s], h[i]
        i = s
    end
    return top
end

A.navRay, A.navLos, A.entityPos = ray, los, entityPos

-- precyzyjny zegar (QueryPerformanceCounter) do budzetow czasu na klatke; localClock bywa za malo dokladny
local qpcBuf, qpcFreq, qpcFn = nil, nil, nil
function A.hires()
    if qpcFn then
        qpcFn(qpcBuf)
        return tonumber(qpcBuf[0]) / qpcFreq
    end
    if qpcFreq == nil then
        qpcFreq = false
        pcall(function()
            local ffi = A.ffi
            pcall(ffi.cdef, 'int QueryPerformanceCounter(int64_t *c);')
            pcall(ffi.cdef, 'int QueryPerformanceFrequency(int64_t *f);')
            local f, c = ffi.new('int64_t[1]'), ffi.new('int64_t[1]')
            if ffi.C.QueryPerformanceFrequency(f) ~= 0 and ffi.C.QueryPerformanceCounter(c) ~= 0 and tonumber(f[0]) > 0 then
                qpcBuf, qpcFreq, qpcFn = c, tonumber(f[0]), ffi.C.QueryPerformanceCounter
            end
        end)
        if qpcFn then return A.hires() end
    end
    return os.clock()
end

-- p: CELL, CLEAR, H_LOW, H_MID, H_HIGH, STEP_UP, STEP_DOWN, DIRECT_MAX, MARGIN, MAX_EXP, WEIGHT, BUDGET, CACHE_TTL,
--    opcjonalnie: MID_STEP (max uskok w polowie krawedzi - motor nie wjedzie na wysoki kraweznik),
--    UNKNOWN_FAR (dalej od startu brak ziemi = teren niewczytany, traktowany jak plaski), tag (log),
--    SOFT_CLEAR / SOFT_COST (krawedz blizej sciany niz SOFT_CLEAR kosztuje SOFT_COST razy wiecej - trasa srodkiem)
function A.newNav(p)
    p.edges, p.nEdges, p.cacheAt, p.cacheInt, p.blocks, p.warned, p.seq = {}, 0, -1e9, nil, {}, false, 0
    local N = { p = p, ray = ray, los = los, entityPos = entityPos }

    -- ziemia pod (x, y) w zasiegu kroku od ref; nil = sciana, dziura albo za stromo; 2. wynik: teren niewczytany
    function N.ground(x, y, ref)
        local cp = ray(x, y, ref + p.STEP_UP + 0.3, x, y, ref - p.STEP_DOWN)
        if not cp then
            -- teren daleko (kolizja niewczytana): zakladamy, ze da sie isc, stopniowo w strone wysokosci celu
            if p.UNKNOWN_FAR and p.ox and (x - p.ox) ^ 2 + (y - p.oy) ^ 2 > p.UNKNOWN_FAR ^ 2 then
                local want = p.tgz or ref
                return ref + nmax(-p.STEP_DOWN * 0.8, nmin(p.STEP_UP * 0.8, want - ref)), true
            end
            return nil
        end
        if cp.normal[3] < 0.55 then return nil end
        local g = cp.pos[3]
        if g > ref + p.STEP_UP then return nil end
        return g
    end

    function N.feet(px, py, pz)                       -- pz = srodek postaci (~1 m nad ziemia)
        local cp = ray(px, py, pz, px, py, pz - 2.5)
        if cp then return cp.pos[3], true end
        return pz - 1.0, false
    end

    function N.blocked(x1, y1, x2, y2, now)
        local bl = p.blocks
        for i = #bl, 1, -1 do
            local b = bl[i]
            if now > b.untilT then
                table.remove(bl, i)
            else
                local dx, dy = x2 - x1, y2 - y1
                local l2 = dx * dx + dy * dy
                local t = l2 > 0 and nmax(0, nmin(1, ((b.x - x1) * dx + (b.y - y1) * dy) / l2)) or 0
                local ex, ey = x1 + dx * t - b.x, y1 + dy * t - b.y
                if ex * ex + ey * ey < b.r * b.r then return true end
            end
        end
        return false
    end

    -- przejscie po prostej miedzy dwoma punktami na ziemi: promien nisko, wysoko i (side) dwa po bokach
    function N.seg(x1, y1, z1, x2, y2, z2, side)
        if p.MID_STEP and math.abs(z2 - z1) > p.MID_STEP then
            local gm = N.ground((x1 + x2) / 2, (y1 + y2) / 2, z1)
            if not gm or math.abs(gm - z1) > p.MID_STEP or math.abs(z2 - gm) > p.MID_STEP then return false end
        end
        if not (los(x1, y1, z1 + p.H_LOW, x2, y2, z2 + p.H_LOW)
            and los(x1, y1, z1 + p.H_HIGH, x2, y2, z2 + p.H_HIGH)) then
            return false
        end
        if not side then return true end
        local dx, dy = x2 - x1, y2 - y1
        local l = nsqrt(dx * dx + dy * dy)
        if l < 1e-3 then return true end
        local ox, oy, h = -dy / l * p.CLEAR, dx / l * p.CLEAR, p.H_MID
        return los(x1 + ox, y1 + oy, z1 + h, x2 + ox, y2 + oy, z2 + h)
            and los(x1 - ox, y1 - oy, z1 + h, x2 - ox, y2 - oy, z2 + h)
    end

    -- prosta od (ax, ay) (ziemia az) do (bx, by): ziemia co komorke + promienie; zwraca ok, ziemia w B
    -- pierwszy odcinek bez promieni bocznych (start moze stac przy scianie)
    function N.corridor(ax, ay, az, bx, by, now)
        if N.blocked(ax, ay, bx, by, now) then return false end
        local dx, dy = bx - ax, by - ay
        local n = nmax(1, nceil(nsqrt(dx * dx + dy * dy) / p.CELL))
        local gz, lx, ly = az, ax, ay
        for i = 1, n do
            local x, y = ax + dx * i / n, ay + dy * i / n
            local g = N.ground(x, y, gz)
            if not g or not N.seg(lx, ly, gz, x, y, g, i > 1) then return false end
            gz, lx, ly = g, x, y
        end
        return true, gz
    end

    -- komorka docelowa: blisko celu, na podobnej wysokosci i widac cel albo promien wali w sam cel (np. skale)
    function N.goal(nav, n)
        local dx, dy = nav.tx - n.x, nav.ty - n.y
        if dx * dx + dy * dy > nav.r2 then return false end
        local h = nav.tz - n.gz
        if h < -1.5 or h > 4.5 then return false end
        local z = n.gz + p.H_MID
        local cp = ray(n.x, n.y, z, nav.tx, nav.ty, z)
        if not cp then return true end
        local q = cp.pos
        if (q[1] - nav.tx) ^ 2 + (q[2] - nav.ty) ^ 2 < 1.0 then return true end
        if cp.entity and cp.entity ~= 0 then
            local ok, ex, ey = pcall(entityPos, cp.entity)
            if ok and ex and (ex - nav.tx) ^ 2 + (ey - nav.ty) ^ 2 < 2.25 then return true end
        end
        return false
    end

    -- obie strony krawedzi wolne w odleglosci SOFT_CLEAR?
    local function soft(x1, y1, z1, x2, y2, z2)
        local dx, dy = x2 - x1, y2 - y1
        local l = nsqrt(dx * dx + dy * dy)
        if l < 1e-3 then return true end
        local ox, oy, h = -dy / l * p.SOFT_CLEAR, dx / l * p.SOFT_CLEAR, p.H_MID
        return los(x1 + ox, y1 + oy, z1 + h, x2 + ox, y2 + oy, z2 + h)
            and los(x1 - ox, y1 - oy, z1 + h, x2 - ox, y2 - oy, z2 + h)
    end

    -- ziemia w sasiedniej komorce d (indeks DIRS; nil = nie przejdzie) i mnoznik kosztu.
    -- Cache: p.edges[klucz wezla] = { [d] = ziemia|false, [d + 8] = kara } - bez sklejania stringow per krawedz.
    local function edge(n, d, x, y, now)
        if N.blocked(n.x, n.y, x, y, now) then return nil end
        local row
        if not n.start then                           -- krawedzi ze startu nie cache'ujemy
            row = p.edges[n.key]
            if row then
                local v = row[d]
                if v ~= nil then
                    if not v then return nil end
                    return v, row[d + 8] or 1
                end
            end
        end
        local g, unknown = N.ground(x, y, n.gz)
        local v = (g and N.seg(n.x, n.y, n.gz, x, y, g, not n.start)) and g or false
        local pen = 1
        if v and p.SOFT_CLEAR and not unknown and not soft(n.x, n.y, n.gz, x, y, v) then pen = p.SOFT_COST end
        if not n.start and not unknown then
            if not row then row = {}; p.edges[n.key] = row end
            row[d], p.nEdges = v, p.nEdges + 1
            if pen ~= 1 then row[d + 8] = pen end
        end
        if not v then return nil end
        return v, pen
    end

    -- start A* z pozycji postaci
    local function beginAstar(nav)
        local s = nav.s
        nav.dir = nil
        p.seq = p.seq + 1
        local st = { key = 's' .. p.seq, start = true, x = s.px, y = s.py, gz = s.gz, g = 0,
            ix = floor(s.px / p.CELL), iy = floor(s.py / p.CELL) }
        nav.nodes[st.key] = st
        hpush(nav.open, { f = s.d, key = st.key, g = 0 })
    end

    -- Start planowania jest tani (jeden promien pod postac); test prostej drogi i A* licza sie w N.run
    -- po kawalku, z budzetem czasu na klatke - bez przyciec gry.
    function N.start(px, py, pz, tx, ty, tz, goalR, rock, now)
        local okI, int = pcall(getActiveInterior)
        int = okI and int or 0
        if now - p.cacheAt > p.CACHE_TTL or p.cacheInt ~= int or p.nEdges > 50000 then
            p.edges, p.nEdges, p.cacheAt, p.cacheInt = {}, 0, now, int
        end
        p.ox, p.oy, p.tgz = px, py, tz - 1.0
        local nav = { tx = tx, ty = ty, tz = tz, r2 = goalR * goalR, rock = rock, t0 = A.now(), exp = 0,
            open = {}, nodes = {},
            x1 = nmin(px, tx) - p.MARGIN, x2 = nmax(px, tx) + p.MARGIN,
            y1 = nmin(py, ty) - p.MARGIN, y2 = nmax(py, ty) + p.MARGIN }
        local gz, solid = N.feet(px, py, pz)
        if not solid then                             -- kolizja pod postacia nieczytelna: prosto
            if not p.warned then p.warned = true; A.log(p.tag or 'nav', 'trasa: nie widze ziemi pod postacia - prosto') end
            nav.done, nav.direct = {}, true
            return nav
        end
        local dx, dy = tx - px, ty - py
        local d = nsqrt(dx * dx + dy * dy)
        if d < 0.05 then nav.done = {}; return nav end
        nav.s = { px = px, py = py, gz = gz, d = d }
        if d < p.DIRECT_MAX then                      -- najpierw prosta (dla skaly: do jej skraju)
            local stand = rock and nmin(d, goalR - 0.6) or 0
            local f = (d - stand) / d
            local ex, ey = px + dx * f, py + dy * f
            nav.dir = { i = 0, n = nmax(1, nceil(d * f / p.CELL)), ax = px, ay = py, bx = ex, by = ey, gz = gz, lx = px, ly = py }
        else
            beginAstar(nav)
        end
        return nav
    end

    -- 'run' = licz dalej w nastepnej klatce, 'fail' = brak drogi, tabela = punkty trasy (bez celu)
    function N.run(nav, now)
        if nav.done then return nav.done end
        local t0, CELL = A.hires(), p.CELL
        local steps, STEPS = 0, p.STEP_MAX or 60       -- twardy limit pracy na jedno wywolanie (niezaleznie od zegara)
        local dr = nav.dir
        if dr then                                    -- test prostej drogi, po kawalku
            if dr.i == 0 and N.blocked(dr.ax, dr.ay, dr.bx, dr.by, now) then
                beginAstar(nav)
            else
                local clear = true
                while dr.i < dr.n do
                    dr.i = dr.i + 1
                    local x = dr.ax + (dr.bx - dr.ax) * dr.i / dr.n
                    local y = dr.ay + (dr.by - dr.ay) * dr.i / dr.n
                    local g = N.ground(x, y, dr.gz)
                    if not g or not N.seg(dr.lx, dr.ly, dr.gz, x, y, g, dr.i > 1) then clear = false; break end
                    dr.gz, dr.lx, dr.ly = g, x, y
                    steps = steps + 1
                    if dr.i < dr.n and (steps >= STEPS or A.hires() - t0 > p.BUDGET) then return 'run' end
                end
                if clear and N.goal(nav, { x = dr.bx, y = dr.by, gz = dr.gz }) then
                    nav.done, nav.direct = {}, true
                    return nav.done
                end
                beginAstar(nav)
                if A.hires() - t0 > p.BUDGET then return 'run' end
            end
        end
        while true do
            local e = hpop(nav.open)
            if not e then return 'fail' end
            local n = nav.nodes[e.key]
            if not n.closed and e.g <= n.g then
                n.closed = true
                if not n.start and N.goal(nav, n) then
                    local rev = {}
                    while n and not n.start do
                        rev[#rev + 1] = n
                        n = n.parent
                    end
                    local path, k = {}, #rev
                    for i = k, 1, -1 do
                        local r = rev[i]
                        path[k - i + 1] = { x = r.x, y = r.y, z = r.gz + 1.0 }
                    end
                    return path
                end
                nav.exp = nav.exp + 1
                if nav.exp > p.MAX_EXP then return 'fail' end
                local nodes, tx, ty, W = nav.nodes, nav.tx, nav.ty, p.WEIGHT
                for d = 1, 8 do
                    local dd = DIRS[d]
                    local ix, iy = n.ix + dd[1], n.iy + dd[2]
                    local x, y = (ix + 0.5) * CELL, (iy + 0.5) * CELL
                    if x >= nav.x1 and x <= nav.x2 and y >= nav.y1 and y <= nav.y2 then
                        local gz, pen = edge(n, d, x, y, now)
                        if gz then
                            -- klucz liczbowy (komorka + wysokosc co 0.5 m); |ix|,|iy| < 32768, z w -1024..7168 m
                            local key = ((ix + 32768) * 65536 + iy + 32768) * 16384 + floor(gz * 2 + 0.5) + 2048
                            local m = nodes[key]
                            if not m then
                                m = { key = key, ix = ix, iy = iy, x = x, y = y, gz = gz, g = math.huge }
                                nodes[key] = m
                            end
                            local ddx, ddy, ddz = x - n.x, y - n.y, gz - n.gz
                            local g = n.g + nsqrt(ddx * ddx + ddy * ddy + ddz * ddz) * pen
                            if not m.closed and g < m.g then
                                m.g, m.parent = g, n
                                local hx, hy = tx - x, ty - y
                                hpush(nav.open, { f = g + W * nsqrt(hx * hx + hy * hy), key = key, g = g })
                            end
                        end
                    end
                end
            end
            steps = steps + 1
            if steps >= STEPS or A.hires() - t0 > p.BUDGET then return 'run' end
        end
    end

    return N
end
end -- nawigacja

-- ============================================================================
-- DANE: teleporty serwera (tracker: najblizszy TP, statuetki: gdzie szukac)
-- ============================================================================
A.TELEPORTS = {   -- { komenda, x, y, z }
    { '/LV', 2106.5, 1013.3, 10.8 }, { '/LS', 2435.0, -1666.5, 13.5 }, { '/SF', -1968.6, 294.0, 35.2 },
    { '/Stacja', -1452.9, 1862.5, 32.7 }, { '/Pustynia', 397.2, 2531.4, 16.5 }, { '/LSLot', 1953.5, -2290.1, 13.5 },
    { '/LVLot', 1686.3, 1609.5, 10.8 }, { '/SFLot', -1065.4, 394.9, 14.5 }, { '/G1', 2260.5, 1397.3, 42.8 },
    { '/G2', 2008.1, 1732.2, 18.9 }, { '/G3', 2074.0, 2416.9, 49.5 }, { '/G4', 1700.6, 1194.1, 34.8 },
    { '/G5', 1256.0, -2027.3, 59.5 }, { '/Drift', -300.8, 1525.1, 75.4 }, { '/Drift1', 1962.7, 1778.5, 18.9 },
    { '/Drift2', -1260.3, -1374.9, 119.2 }, { '/Drift3', -574.4, -1053.0, 23.7 }, { '/Stadion', 1354.1, 2154.0, 11.0 },
    { '/Hop', -869.5, 2308.8, 161.5 }, { '/Mulholland', 894.7, -842.2, 86.1 }, { '/Tama', -912.1, 2005.3, 60.9 },
    { '/Miasteczko', -393.5, 2280.5, 40.5 }, { '/StacjaLV', 2849.3, 1290.7, 11.4 }, { '/StacjaLS', 1720.4, -1964.5, 14.1 },
    { '/StacjaSF', -1949.2, 130.8, 25.9 }, { '/Statek2', -1414.8, 1479.6, 7.1 }, { '/Statek3', -1405.2, 509.2, 3.0 },
    { '/Statek4', -2319.1, 1543.4, 18.8 }, { '/Plaza', 318.8, -1796.8, 4.7 }, { '/Plaza2', -2896.9, 144.8, 5.5 },
    { '/Dillimore', 643.0, -605.3, 16.3 }, { '/Richman', 275.1, -1249.4, 73.9 }, { '/Gora', -2292.3, -1629.7, 483.8 },
    { '/Wiezowiec', 1545.9, -1353.6, 329.5 }, { '/Molo', 2290.4, 611.7, 10.8 }, { '/Pole', -181.1, 12.7, 3.1 },
    { '/Rzeka', -2481.3, -286.5, 40.5 }, { '/PKP', 810.3, -1351.9, -0.5 }, { '/Parking', -2488.6, -608.2, 132.6 },
    { '/Port', 2699.5, -2391.0, 13.6 }, { '/Autostrada', -34.4, -2720.8, 41.9 }, { '/Pole2', -382.4, -1362.0, 23.4 },
    { '/EasterBay', -1034.2, -656.4, 32.0 }, { '/Foster', -2017.8, -859.5, 32.2 }, { '/Chinatown', -2209.3, 605.1, 35.2 },
    { '/BurgerShot', -2353.3, 986.5, 50.7 }, { '/Molo2', -1712.6, 1331.3, 7.0 }, { '/LSPD', 1519.2, -1675.4, 13.5 },
    { '/LVPD', 2316.1, 2451.1, 10.8 }, { '/SFPD', -1625.2, 664.2, 7.2 }, { '/Most', -2686.6, 1741.8, 68.0 },
    { '/SzpitalSF', -2641.5, 623.5, 14.5 }, { '/Fern', 981.2, -8.2, 92.4 }, { '/RedCounty', 1555.7, 26.6, 24.2 },
    { '/Palomino', 2401.0, 41.6, 26.3 }, { '/Tipi', -808.2, 1437.4, 13.8 }, { '/FortCarson', -139.4, 1193.1, 19.6 },
    { '/SzpitalLV', 1617.8, 1841.1, 10.8 }, { '/GlenPark', 2047.1, -1182.4, 23.6 }, { '/Bagno', -845.2, -1972.0, 16.1 },
    { '/Farma', -127.1, -178.1, 2.0 }, { '/SzpitalLS', 1182.6, -1324.2, 13.6 }, { '/SzpitalLS2', 2030.2, -1418.0, 17.0 },
    { '/Zatoka', -2501.9, 2417.0, 16.6 }, { '/WH', 1401.1, -19.5, 1000.9 }, { '/Bar', 501.9, -68.0, 998.8 },
    { '/Wyskok', 2083.3, 610.3, 142.1 }, { '/Wyskok2', 2054.4, 1589.6, 150.1 }, { '/Wyskok3', 2009.6, -1446.1, 250.0 },
    { '/Zjazd', -244.8, 630.7, 169.6 }, { '/PodWoda', 1734.9, 523.6, -15.7 }, { '/Atrakcja', 3871.0, 369.0, 1961.1 },
    { '/Odbij', 518.3, 1417.6, 3928.5 }, { '/Statek', 3783.8, -3670.5, -49.8 }, { '/Staw', -3549.0, 110.2, 4.0 },
    { '/Skatepark', -2046.6, -274.4, 35.5 }, { '/Skatepark2', 1858.9, -1381.2, 13.6 }, { '/Spirala', 2091.6, 4206.3, 1242.7 },
    { '/Praca', 2464.3, 2047.5, 10.8 }, { '/Czarownica', 1913.2, -515.7, 25.9 }, { '/Jaskinia', -2831.5, 874.3, 44.1 },
    { '/Zlomowisko', 1261.9, 184.7, 19.4 }, { '/StrasznyDom', -1354.5, -973.7, 195.6 }, { '/Lowisko', 2457.8, -1801.2, 15.5 },
    { '/Gielda', 2490.6, -1746.6, 13.5 }, { '/Las', 2454.5, -1805.0, 16.6 }, { '/Kosciol', 664.2, 1207.7, 11.7 },
    { '/Spedycja', 1279.2, -53.2, 1004.3 }, { '/Pizzeria', -2364.8, -99.1, 35.3 }, { '/Taxi', 1952.3, 2292.2, 10.8 },
    { '/Zamek', 14421.7, 701.4, 41.2 }, { '/Oaza', 2648.6, -5646.8, 15.6 }, { '/Kutry', -1994.0, -2833.7, 4.0 },
    { '/Muzeum', 1295.1, -57.7, 1001.1 }, { '/Kopalnia', -2818.8, 4256.6, 50.4 }, { '/Tartak', -2066.1, -2381.1, 30.6 },
    { '/Salon', -2036.3, 1199.4, 45.5 }, { '/Kasyno', 1240.8, -26.9, 1003.3 }, { '/Wojsko', 150.6, 1874.0, 17.9 },
    { '/Drzewo', -2836.4, 2801.4, 243.5 }, { '/Ekwador', -544.0, 2581.0, 53.5 }, { '/Podziemia', 232.9, 13.5, 2.4 },
    { '/FameMMA', 3685.7, 33.3, 35.2 }, { '/Koloseum', 1653.1, 3526.2, 23.0 }, { '/Skolim', -1452.9, 1862.5, 32.7 },
    { '/Osiedle1', 1431.3, 2590.4, 10.7 }, { '/Osiedle2', 1602.2, 2733.4, 10.7 }, { '/Osiedle3', 1993.9, 2743.3, 10.7 },
    { '/Osiedle4', 1946.4, 939.2, 10.8 }, { '/Osiedle5', 2149.4, 715.6, 10.8 }, { '/Osiedle6', -2612.1, 776.4, 43.0 },
    { '/Osiedle7', 2453.9, -2010.0, 13.4 }, { '/Osiedle8', 2170.0, -1264.6, 23.8 }, { '/Osiedle9', 2311.4, -1229.2, 24.1 },
    { '/Osiedle10', 2170.0, -1264.6, 23.8 },
}

-- ============================================================================
-- DANE: strefy gangowe - punkt przejecia (checkpoint) kazdej strefy, id jak na serwerze (/strefy)
-- ============================================================================
A.GANG_ZONES = {   -- [id] = { x, y, z, nazwa }
    [0] = { 1876.9, -1966.7, 13.1, 'El Corona' }, [1] = { 2052.9, -1905.9, 13.1, 'Willowfield' },
    [2] = { 1726.0, -1974.3, 13.7, 'El Corona' }, [3] = { 1859.0, -1036.4, 23.5, 'Glen Park' },
    [4] = { 2119.9, -1194.1, 23.4, 'Jefferson' }, [5] = { 1990.1, -1556.3, 13.6, 'Idlewood' },
    [6] = { 1920.6, -1790.7, 13.4, 'Idlewood' }, [7] = { 2041.6, -1647.4, 13.5, 'Idlewood' },
    [8] = { 2157.4, -1592.7, 13.9, 'Idlewood' }, [9] = { 1911.0, -1407.6, 13.6, 'Glen Park' },
    [10] = { 2222.9, -1337.5, 24.0, 'Jefferson' }, [11] = { 2248.6, -1093.7, 41.6, 'Las Colinas' },
    [12] = { 2161.1, -1798.6, 13.4, 'Idlewood' }, [13] = { 2449.5, -1765.1, 13.1, 'Ganton' },
    [14] = { 2689.1, -1694.7, 9.4, 'East Beach' }, [15] = { 2677.5, -1546.5, 24.1, 'East Beach' },
    [16] = { 2797.1, -1542.2, 10.9, 'East Beach' }, [17] = { 2524.0, -1531.2, 23.6, 'Wschodnie Los Santos' },
    [18] = { 2317.4, -1526.6, 25.3, 'Wschodnie Los Santos' }, [19] = { 2240.4, -1415.3, 23.8, 'Jefferson' },
    [20] = { 2327.8, -1434.8, 24.0, 'Wschodnie Los Santos' }, [21] = { 2337.1, -1257.3, 28.0, 'Wschodnie Los Santos' },
    [22] = { 2411.8, -1311.8, 24.7, 'Wschodnie Los Santos' }, [23] = { 2546.4, -1329.0, 34.7, 'Wschodnie Los Santos' },
    [24] = { 2680.9, -1329.5, 42.9, 'Los Flores' }, [25] = { 2823.2, -1181.8, 24.8, 'East Beach' },
    [26] = { 2799.1, -1084.9, 30.7, 'Las Colinas' }, [27] = { 2681.9, -1109.8, 69.4, 'Las Colinas' },
    [28] = { 2423.2, -1105.6, 40.9, 'Las Colinas' }, [29] = { 1970.3, -1192.6, 25.7, 'Glen Park' },
    [30] = { 2769.7, -1955.1, 12.9, 'Playa del Seville' }, [31] = { 2531.0, -2010.0, 13.1, 'Willowfield' },
    [32] = { 2286.8, -1675.9, 14.1, 'Ganton' }, [33] = { 2646.6, -2004.7, 13.0, 'Willowfield' },
}

-- ============================================================================
-- MODUL: TRACKER (dawny PlayerTracker 6.1)
-- ============================================================================
A.register((function(A)
local ffi = A.ffi
local floor, sqrt, deg, atan2 = math.floor, math.sqrt, math.deg, math.atan2

local M = { id = 'tracker', title = 'Tracker' }
local FILE = A.DIR .. '\\tracker.json'

local C = {
    target      = '',
    hud         = true,
    showTp      = true,      -- najblizszy teleport serwera przy celu
    maxListId   = 50,        -- lista graczy: ID 0..N
    updateEvery = 0.1,       -- s: pozycja i dystans
    searchEvery = 1.0,       -- s: pelny skan puli, gdy cel offline
    syncFresh   = 3.0,       -- s: waznosc danych synchronizacji po wyjsciu ze streamu
    background  = true,
}

local COL = {
    online = 0xFF00FF00, nodata = 0xFFFFAA00, offline = 0xFFFF0000, text = 0xFFFFFFFF,
    dist = 0xFFFFFF00, dir = 0xFF00FFFF, tp = 0xFFFF00FF, tpInfo = 0xFFFF8800,
}
local DIRS = { 'E', 'NE', 'N', 'NW', 'W', 'SW', 'S', 'SE' }
local ST_PASSENGER, ST_DRIVER = 18, 19
local LINE_H, PAD, BG = 18, 5, 0x99000000

local TELEPORTS = A.TELEPORTS
local TP_N = #TELEPORTS

-- ---------------------------------------------------------------- config
local function save() A.saveJson(FILE, C) end

local function load()
    local t = A.loadJson(FILE)
    if t then
        A.overlay(C, t)
    else
        -- import z PlayerTracker.lua
        local old = A.readFile(A.WD .. '\\PlayerTracker_target.txt')
        if old then C.target = (old:match('^[^\r\n]*') or ''):gsub('%s+', '') end
        local pos = A.readFile(A.WD .. '\\PlayerTracker_pos.txt')
        if pos then
            local a, b = pos:match('(%-?[%d%.]+)%s+(%-?[%d%.]+)')
            a, b = tonumber(a), tonumber(b)
            if a and b and a >= 0 and a <= 1 and b >= 0 and b <= 1 and not A.cfg.hud.tracker then
                A.cfg.hud.tracker = { a, b }
                A.saveCore()
            end
        end
        save()
    end
    C.maxListId = A.clamp(floor(C.maxListId), 1, 1003)
    C.showTp, C.hud, C.background = true, true, true
end

-- ---------------------------------------------------------------- pula graczy (SAMP-API)
local RefNetGame, poolMode = nil, 1

local function getPool()
    if not RefNetGame then return nil end
    local ok, ng = pcall(RefNetGame)
    if not ok or ng == nil then return nil end
    if poolMode == 2 then
        local okD, inner = pcall(function() return ng[0] end)
        if not okD or inner == nil then return nil end
        ng = inner
    end
    local ok2, pool = pcall(function() return ng:GetPlayerPool() end)
    if not ok2 or pool == nil then return nil end
    return pool
end

local function probePool()
    for mode = 1, 2 do
        poolMode = mode
        local p = getPool()
        if p then return p end
    end
    poolMode = 1
    return nil
end

local function nickOf(pool, id)
    if pool:IsConnected(id) == 0 then return nil end
    local p = pool:GetName(id)
    if p == nil then return nil end
    return ffi.string(p)
end

local function largestId(pool, cap)
    local l = pool.m_nLargestId
    if l < 0 or l > 1003 then l = 1003 end
    if cap and l > cap then l = cap end
    return l
end

-- ---------------------------------------------------------------- cel
local TARGET = ''
local S = { id = -1, forceSearch = false, nextSearch = 0, nextUpdate = 0 }

local function setTarget(nick)
    C.target = nick or ''
    TARGET = C.target:lower()
    S.id, S.forceSearch, S.nextUpdate = -1, true, 0
    save()
end
M.setTarget = setTarget

local function resolveTarget(pool, now)
    if TARGET == '' then
        S.id, S.forceSearch = -1, false
        return -1
    end
    if S.id >= 0 then
        local n = nickOf(pool, S.id)
        if n and n:lower() == TARGET then return S.id end
    end
    S.id = -1
    if S.forceSearch or now >= S.nextSearch then
        S.forceSearch = false
        S.nextSearch = now + C.searchEvery
        for id = 0, largestId(pool) do
            local n = nickOf(pool, id)
            if n and n:lower() == TARGET then S.id = id; break end
        end
    end
    return S.id
end

local playerList, listVer, nextList = {}, 0, 0

local function refreshPlayerList()
    local pool = getPool()
    if not pool then return end
    local list = {}
    for id = 0, largestId(pool, C.maxListId) do
        local name = nickOf(pool, id)
        if name then
            list[#list + 1] = {
                id = id, name = name, lower = name:lower(),
                label = string.format('[%d] %s##trk%d', id, A.u8(name), id),
            }
        end
    end
    table.sort(list, function(a, b) return a.lower < b.lower end)
    playerList = list
    listVer = listVer + 1
end

-- ---------------------------------------------------------------- pozycja celu
-- 1) ped w streamie (SF.lua), 2) dane synchronizacji, 3) marker radaru
local track = { id = -1, val = nil, at = -1e9 }
local syncBroken, passengerBroken = false, false

local function syncPosition(rp, id, now)
    local lu = rp.m_lastUpdate
    if track.id ~= id then
        track.id, track.val, track.at = id, lu, -1e9
    elseif lu ~= track.val then
        track.val, track.at = lu, now
    end
    local streamed = rp.m_pPed ~= nil
    if not streamed and now - track.at > C.syncFresh then return nil end

    local st = rp.m_nState
    local v
    if st == ST_PASSENGER and not passengerBroken then
        local ok, p = pcall(function() return rp.m_passengerData.m_position end)
        if ok then v = p else
            passengerBroken = true
            A.log('tracker', 'brak m_passengerData w SAMP-API: ' .. tostring(p))
        end
    end
    if not v then
        v = (st == ST_DRIVER or st == ST_PASSENGER) and rp.m_incarTargetPosition or rp.m_onfootTargetPosition
    end
    local x, y, z = v.x, v.y, v.z
    if x == 0 and y == 0 and z == 0 then return nil end
    return x, y, z, streamed and 'stream' or 'sync'
end

local function targetPosition(pool, id, now)
    if type(sampGetCharHandleBySampPlayerId) == 'function' then
        local ok, found, handle = pcall(sampGetCharHandleBySampPlayerId, id)
        if ok and found and doesCharExist(handle) then
            local x, y, z = getCharCoordinates(handle)
            return x, y, z, 'stream'
        end
    end
    local rp = pool:GetPlayer(id)
    if rp == nil then return nil end
    if not syncBroken then
        local ok, x, y, z, src = pcall(syncPosition, rp, id, now)
        if not ok then
            syncBroken = true
            A.log('tracker', 'pozycja z synchronizacji wylaczona: ' .. tostring(x))
        elseif x then
            return x, y, z, src
        end
    end
    if rp.m_bMarkerState == 0 then return nil end
    local m = rp.m_markerPosition
    return m.x + 0.0, m.y + 0.0, m.z + 0.0, 'marker'
end

local function nearestTeleport(px, py, pz)
    local best, bestSq = nil, math.huge
    for i = 1, TP_N do
        local tp = TELEPORTS[i]
        local dx, dy, dz = tp[2] - px, tp[3] - py, tp[4] - pz
        local sq = dx * dx + dy * dy + dz * dz
        if sq < bestSq then best, bestSq = tp, sq end
    end
    return best, sqrt(bestSq)
end

-- ---------------------------------------------------------------- HUD
local font, fontH = nil, LINE_H
local lines, nLines = {}, 0
local boxW, widthDirty = 0, true
local stKind, stName, stId
local last = { id = -2 }
local info = { tp = nil, dist = nil, src = nil, dir = nil }

local function setLine(i, text, color)
    local l = lines[i]
    if not l then l = { text = '', color = 0 }; lines[i] = l end
    if l.text ~= text then l.text = text; widthDirty = true end
    l.color = color
end

local function setCount(n)
    if nLines ~= n then nLines = n; widthDirty = true end
end

local function showStatus(kind, fmt, color)
    if stKind ~= kind or stName ~= C.target or stId ~= S.id then
        stKind, stName, stId = kind, C.target, S.id
        setLine(1, string.format(fmt, C.target, S.id), color)
        setCount(1)
    end
    last.id = -2
    info.tp, info.dist, info.src = nil, nil, nil
end

local function update(now)
    local pool = getPool()
    if not pool then return showStatus('nopool', 'tracker: brak puli graczy', COL.offline) end
    local id = resolveTarget(pool, now)
    if TARGET == '' then return showStatus('notarget', 'tracker: brak celu', COL.nodata) end
    if id < 0 then return showStatus('offline', '%s  offline', COL.offline) end

    local tx, ty, tz, src = targetPosition(pool, id, now)
    if not tx then
        return showStatus('nodata', '%s [%d]  brak pozycji', COL.nodata)
    end
    stKind = nil
    local mx, my, mz = getCharCoordinates(PLAYER_PED)
    if id == last.id and C.target == last.name and src == last.src and C.showTp == last.showTp
        and tx == last.tx and ty == last.ty and tz == last.tz
        and mx == last.mx and my == last.my and mz == last.mz then
        return
    end
    last.id, last.name, last.src, last.showTp = id, C.target, src, C.showTp
    last.tx, last.ty, last.tz, last.mx, last.my, last.mz = tx, ty, tz, mx, my, mz

    local dx, dy, dz = tx - mx, ty - my, tz - mz
    local dist = sqrt(dx * dx + dy * dy + dz * dz)
    local ang = deg(atan2(dy, dx))
    if ang < 0 then ang = ang + 360 end

    local dir = DIRS[floor((ang + 22.5) / 45) % 8 + 1]
    setLine(1, string.format('{66FF66}%s [%d]  {FFFFFF}%.0f m  {66CCFF}%s', C.target, id, dist, dir), COL.text)
    info.dist, info.src, info.dir = dist, src, dir
    if C.showTp then
        local tp, tpDist = nearestTeleport(tx, ty, tz)
        info.tp = tp
        setLine(2, string.format('{AAAAAA}najblizszy TP  {FF66FF}%s  {AAAAAA}(%.0f m od niego)', tp[1], tpDist), COL.text)
    else
        info.tp = nil
        setLine(2, '', COL.text)
    end
    setCount(2)
end

local hasTextLen = type(renderGetFontDrawTextLength) == 'function'

local function draw()
    if nLines == 0 or not font then return end
    if widthDirty then
        local w = 300
        if hasTextLen then
            w = 0
            for i = 1, nLines do
                local lw = renderGetFontDrawTextLength(font, A.stripColors(lines[i].text))
                if lw > w then w = lw end
            end
        end
        boxW, widthDirty = w, false
    end
    local pad = C.background and PAD or 0
    local bw, bh = boxW + pad * 2, (nLines - 1) * LINE_H + fontH + pad * 2
    local bx, by = A.hudPlace('tracker', bw, bh, 0.78, 0.60)
    if C.background then renderDrawBox(bx, by, bw, bh, BG) end
    for i = 1, nLines do
        local l = lines[i]
        renderFontDrawText(font, l.text, bx + pad, by + pad + (i - 1) * LINE_H, l.color)
    end
end

-- ---------------------------------------------------------------- modul
function M.init()
    load()
    TARGET = C.target:lower()
    S.forceSearch = true
    local api = A.netgameApi
    RefNetGame = type(api) == 'table' and api.RefNetGame or nil
    if A.sampapi then
        pcall(A.sampapi.require, 'CPlayerPool')
        pcall(A.sampapi.require, 'CRemotePlayer')
    end
    if not RefNetGame then error('brak SAMP-API (CNetGame.RefNetGame)') end
    for _ = 1, 40 do
        if probePool() then break end
        wait(250)
    end
    font = renderCreateFont('Arial', 9, 5)
    if type(renderGetFontDrawHeight) == 'function' then fontH = renderGetFontDrawHeight(font) end
end

function M.frame(now)
    if TARGET == '' then return end
    if now >= S.nextUpdate then
        S.nextUpdate = now + C.updateEvery
        update(now)
    end
    if A.drawOk then draw() end
end

function M.status()
    if TARGET == '' then return 'brak celu' end
    if S.id < 0 then return C.target .. ' offline' end
    return string.format('%s [%d]%s', C.target, S.id, info.dist and string.format(' %.0f m', info.dist) or '')
end

-- ---------------------------------------------------------------- menu
local filterBuf = nil
local mCache = { ver = -1, flt = nil, list = {} }

local function getMatches(flt)
    if mCache.ver == listVer and mCache.flt == flt then return mCache.list end
    local fltId = tonumber(flt)
    local out = {}
    for _, p in ipairs(playerList) do
        if flt == '' or p.id == fltId or p.lower:find(flt, 1, true) then out[#out + 1] = p end
    end
    mCache.ver, mCache.flt, mCache.list = listVer, flt, out
    return out
end

function M.menu()
    local im, ui = A.imgui, A.ui
    local now = A.now()
    if now >= nextList then
        nextList = now + 1.0
        pcall(refreshPlayerList)
    end

    ui.cols(function()
        ui.group('Cel', function()
            if TARGET == '' then
                ui.textDim('Wybierz gracza z listy.')
                return
            end
            local online = S.id >= 0
            ui.kv('Gracz', A.u8(C.target), online and 0xFF66FF66 or 0xFFFF6666)
            if online then
                ui.kv('ID', S.id)
                if info.dist then ui.kv('Dystans', string.format('%.0f m  %s', info.dist, info.dir or '')) end
                if info.tp then ui.kv('Najblizszy TP', info.tp[1], 0xFFFF77FF) end
            else
                ui.kv('Status', 'offline', 0xFFFF6666)
            end
            im.Spacing()
            if online and info.tp then
                ui.buttons({
                    { info.tp[1] .. '##trk', function() A.sendCommand(info.tp[1]) end, 'Wpisuje na serwer komende teleportu najblizszego temu graczowi.' },
                    { 'Stop##trk', function() setTarget('') end, 'Przestaje sledzic gracza.' },
                })
            elseif ui.button('Stop##trk') then
                setTarget('')
            end
        end)
        local st, wz = A.mods.statuetki, A.mods.walizki
        if st and st.ready then ui.group('Statuetki', st.menuGroup) end
        if wz and wz.ready then ui.group('Walizki', wz.menuGroup) end
    end, function()
        ui.group('Gracze', function()
            if not filterBuf then filterBuf = im.new.char[32]() end
            local enter = ui.input('##trkfilter', 'szukaj (nick albo ID)', filterBuf, 32, im.InputTextFlags.EnterReturnsTrue)
            local matches = getMatches(A.cp(A.ffi.string(filterBuf)):lower())
            if enter and matches[1] then setTarget(matches[1].name) end
            im.BeginChild('##trklist', im.ImVec2(ui.W, 300), true)
            for _, p in ipairs(matches) do
                if im.Selectable(p.label, p.lower == TARGET) then setTarget(p.name) end
            end
            im.EndChild()
        end)
    end)
end

return M
end)(A))

-- ============================================================================
-- MODUL: GRAFFITI (dawny TagBlips 3.3.0) + timery przejecia
-- ============================================================================
A.register((function(A)
local floor, ceil, sqrt, min, max, abs = math.floor, math.ceil, math.sqrt, math.min, math.max, math.abs

local M = { id = 'graffiti', title = 'Gang' }

local TAGS = {
    {1549.89, -1714.52, 15.10}, {1448.23, -1755.90, 14.52}, {1332.13, -1722.30, 14.19}, {1724.73, -1741.50, 14.10},
    {1767.21, -1617.54, 15.04}, {1799.13, -1708.77, 14.10}, {1498.63, -1207.35, 24.68}, {1732.73, -963.08, 41.44},
    {1746.75, -1359.77, 16.21}, {1519.42, -1010.95, 24.61}, {1687.23, -1239.13, 15.81}, {1783.97, -2156.54, 14.31},
    {1574.71, -2691.88, 13.60}, {1118.91, -2008.24, 75.02}, {1850.01, -1876.84, 14.36}, {1889.24, -1982.51, 15.76},
    {1950.62, -2034.40, 14.09}, {1936.88, -2134.91, 14.22}, {1808.34, -2092.27, 14.22}, {1624.63, -2296.24, 14.31},
    {1071.14, -1863.79, 14.09}, {2065.44, -1897.23, 13.61}, {2763.00, -2012.11, 14.13}, {2379.32, -2166.22, 24.95},
    {2134.33, -2011.20, 10.52}, {2392.36, -1914.57, 14.74}, {2430.33, -1997.91, 14.74}, {2587.32, -2063.52, 4.61},
    {2704.20, -1966.69, 13.76}, {2489.24, -1959.07, 13.76}, {2273.90, -2265.80, 14.56}, {2173.59, -2165.19, 15.30},
    {2273.20, -2529.12, 8.52}, {2704.23, -2144.30, 11.82}, {2794.53, -1906.81, 14.67}, {2812.94, -1942.07, 11.06},
    {2874.50, -1909.38, 8.39}, {2046.41, -1635.84, 13.59}, {2066.43, -1652.48, 14.28}, {2102.20, -1648.76, 13.59},
    {2162.78, -1786.07, 14.19}, {2034.40, -1801.67, 14.55}, {1910.16, -1779.66, 18.75}, {1837.20, -1814.19, 4.34},
    {1837.66, -1640.38, 13.76}, {1959.40, -1577.76, 13.76}, {2074.18, -1579.15, 14.03}, {2182.23, -1467.90, 25.55},
    {2132.23, -1258.09, 24.05}, {2233.95, -1367.62, 24.53}, {2224.77, -1193.06, 25.84}, {2119.20, -1196.62, 24.63},
    {1974.09, -1351.16, 24.56}, {2093.76, -1413.45, 24.12}, {1969.59, -1289.70, 24.56}, {1966.95, -1174.73, 20.04},
    {1911.87, -1064.40, 25.19}, {2281.46, -1118.96, 27.01}, {2239.78, -999.75, 59.76}, {2122.69, -1060.90, 25.39},
    {2062.72, -996.46, 48.27}, {2076.73, -1071.13, 27.61}, {2399.41, -1552.03, 28.75}, {2353.54, -1508.21, 24.75},
    {2394.10, -1468.37, 24.78}, {2841.37, -1312.96, 18.82}, {2820.34, -1190.98, 25.67}, {2766.09, -1197.14, 69.07},
    {2756.01, -1388.13, 39.46}, {2821.23, -1465.09, 16.54}, {2767.78, -1621.19, 11.23}, {2767.76, -1819.95, 12.23},
    {2667.89, -1469.13, 31.68}, {2612.93, -1390.77, 35.43}, {2536.22, -1352.77, 31.09}, {2580.95, -1274.09, 46.59},
    {2603.16, -1197.81, 60.99}, {2542.95, -1363.24, 31.77}, {2462.27, -1541.41, 25.42}, {2522.46, -1478.74, 24.16},
    {2346.52, -1350.78, 24.28}, {2322.45, -1254.41, 22.92}, {2273.02, -1687.43, 14.97}, {2422.91, -1682.30, 13.99},
    {2576.82, -1143.27, 48.20}, {2621.51, -1092.20, 69.80}, {2797.92, -1097.70, 31.06}, {1295.18, -1465.22, 10.28},
    {1271.48, -1662.32, 20.25}, {810.57, -1797.57, 13.62}, {730.45, -1482.01, 2.25}, {947.48, -1466.72, 17.24},
    {944.27, -985.82, 39.30}, {1072.91, -1012.80, 35.52}, {1206.25, -1162.00, 23.88}, {1098.81, -1292.55, 17.14},
    {482.63, -1761.59, 5.91}, {399.01, -2066.88, 11.23}, {466.98, -1283.02, 16.32}, {583.46, -1502.11, 16.00},
}
-- [indeks TAGS] = ID graffiti na serwerze (komplet 100/100, samp.gg); labele 3D i tak to weryfikuja live
local SEED_MAP = {
    [1] = 85, [2] = 86, [3] = 87, [4] = 52, [5] = 55, [6] = 53, [7] = 78, [8] = 71, [9] = 76, [10] = 79,
    [11] = 77, [12] = 42, [13] = 99, [14] = 97, [15] = 47, [16] = 45, [17] = 44, [18] = 41, [19] = 43, [20] = 98,
    [21] = 96, [22] = 46, [23] = 32, [24] = 36, [25] = 40, [26] = 25, [27] = 26, [28] = 35, [29] = 33, [30] = 27,
    [31] = 37, [32] = 39, [33] = 38, [34] = 34, [35] = 30, [36] = 31, [37] = 29, [38] = 2, [39] = 1, [40] = 0,
    [41] = 51, [42] = 50, [43] = 49, [44] = 48, [45] = 54, [46] = 56, [47] = 57, [48] = 58, [49] = 64, [50] = 60,
    [51] = 63, [52] = 65, [53] = 75, [54] = 59, [55] = 74, [56] = 73, [57] = 72, [58] = 68, [59] = 69, [60] = 67,
    [61] = 70, [62] = 66, [63] = 5, [64] = 3, [65] = 4, [66] = 8, [67] = 7, [68] = 9, [69] = 10, [70] = 11,
    [71] = 12, [72] = 28, [73] = 13, [74] = 14, [75] = 20, [76] = 15, [77] = 16, [78] = 19, [79] = 22, [80] = 21,
    [81] = 61, [82] = 62, [83] = 24, [84] = 23, [85] = 17, [86] = 18, [87] = 6, [88] = 84, [89] = 88, [90] = 95,
    [91] = 90, [92] = 89, [93] = 81, [94] = 80, [95] = 82, [96] = 83, [97] = 94, [98] = 93, [99] = 92, [100] = 91,
}

local SERVER_TAGS        = 100
local MAX_LABELS         = 2048
local LABEL_PREFIX       = 'Graffiti gangowe'
local LABEL_MATCH_RADIUS = 3.0
local HUD_PAD            = 4
local BLIP_DISPLAY_BLIP_ONLY = 2
local SAVE_INTERVAL      = 10
local LOG_MAX            = 30

local FILE     = A.DIR .. '\\graffiti.json'
local OLD_FILE = A.WD .. '\\config\\TagBlips.json'

local DEFAULTS = {
    enabled         = true,     -- blipy na radarze
    mode            = 'near',   -- 'near' = maxBlips najblizszych, 'all' = wszystkie
    maxBlips        = 15,
    radius          = 0,        -- [m, 2D] limit w trybie near, 0 = bez limitu
    filter          = 'all',    -- 'all' | 'enemy' | 'paint'
    myGang          = 'CWL',    -- fragment nazwy naszego gangu
    hideInInteriors = true,
    colourUnknown   = 3,        -- brak danych: ID koloru SA albo RGBA 0xRRGGBBAA
    minRadarLum     = 110,
    chatMsgs        = true,     -- komunikaty na czacie (wszystkie)
    notifyChanges   = true,     -- zmiana wlasciciela
    notifyUnlock    = true,     -- cudze graffiti mozna juz przejac
    unlockRange     = 0,        -- [m] powiadomienie o odblokowaniu tylko w tym zasiegu, 0 = wszedzie
    notifyFreshSec  = 300,
    hud             = true,
    hudFontSize     = 10,
    hudSoon         = 2,        -- ile najblizszych odblokowan w HUD (0 = wcale)
    blinkReady      = true,     -- gotowe do przejecia migaja na radarze
    refreshMs       = 500,
    labelScanMs     = 1000,
    autoRefresh     = true,     -- sam otwiera /graffiti w tle i czyta wszystkie strony
    autoRefreshMin  = 3,
    zoneKey         = 0x71,     -- Strefy Bot: F2
    botMode         = 'bike',   -- Strefy Bot: 'bike' (NRG, /nrg) | 'foot'
    botSpeed        = 15,       -- [m/s] max predkosc motoru
    botHud          = true,
    zoneReadyOnly   = true,     -- Strefy Bot: jedz tylko na strefy, ktore wedlug /strefy mozna teraz przejac
}

local TRANSLIT = {
    [0xA5] = 'A', [0xB9] = 'a', [0xC6] = 'C', [0xE6] = 'c', [0xCA] = 'E', [0xEA] = 'e',
    [0xA3] = 'L', [0xB3] = 'l', [0xD1] = 'N', [0xF1] = 'n', [0xD3] = 'O', [0xF3] = 'o',
    [0x8C] = 'S', [0x9C] = 's', [0x8F] = 'Z', [0x9F] = 'z', [0xAF] = 'Z', [0xBF] = 'z',
}

local cfg
local gangSetup
local map, tagOf, mapCount = {}, {}, 0   -- map[tagIdx] = sid, tagOf[sid] = tagIdx
local gangs = {}                         -- gangs[sid] = { o, c, cd (epoch), cdp (dokladnosc s), z, t }
local snapshotAt = 0
local active, activeColour, want = {}, {}, {}
local dist, order = {}, {}
local pendingChanges = {}
local unlockSeen = {}                    -- sid -> cd, dla ktorego juz powiadomiono
local targetIdx
local dirty, saveDirty, poolWarned = true, false, false
local lastDialogText
local font
local events = {}                        -- ostatnie komunikaty (menu)

------------------------------------------------------------------------
-- util
------------------------------------------------------------------------

local function toInt32(v)
    v = v % 0x100000000
    return v >= 0x80000000 and v - 0x100000000 or v
end

local stripColors = A.stripColors

local function clean(s)
    s = stripColors(s):gsub('[\128-\255]', function(c) return TRANSLIT[c:byte()] or '?' end)
    s = s:gsub('%s+', ' ')
    return (s:gsub('^ ', ''):gsub(' $', ''))
end

local function ownerName(raw)
    local n = clean(raw or '')
    local l = n:lower()
    if n == '' or l:find('^brak') or l:find('^nikt') or n == '-' then return '-' end
    return n
end

local function gangTag(owner)
    if not owner or owner == '-' then return 'brak' end
    local last = owner:match('(%S+)$')
    if last and #last <= 5 and last:upper() == last then return last end
    return #owner > 14 and owner:sub(1, 14) or owner
end

local function isMine(owner)
    if cfg.myGang == '' or not owner or owner == '-' then return false end
    return owner:lower():find(cfg.myGang:lower(), 1, true) ~= nil
end

local function brighten(rgb)
    local r, g, b = floor(rgb / 65536) % 256, floor(rgb / 256) % 256, rgb % 256
    local lum = 0.299 * r + 0.587 * g + 0.114 * b
    if lum < cfg.minRadarLum and lum < 255 then
        local k = (cfg.minRadarLum - lum) / (255 - lum)
        r = floor(r + (255 - r) * k + 0.5)
        g = floor(g + (255 - g) * k + 0.5)
        b = floor(b + (255 - b) * k + 0.5)
    end
    return r * 65536 + g * 256 + b
end

local function hex(rgb) return ('%06X'):format(brighten(rgb or 0xFFFFFF)) end

-- 'za 20 minut' / 'za 42 sekundy' / 'Tak' / '... /Spray ...' -> sekundy, dokladnosc [s]
local function parseCooldown(s)
    if not s then return nil end
    if s:find('/Spray', 1, true) or s:find('^%s*Tak') then return 0, 1 end
    local n, unit = s:match('za%s+(%d+)%s*(%a*)')
    n = tonumber(n)
    if not n then return nil end
    unit = unit:lower()
    if unit:find('^sek') then return n, 1 end
    if unit:find('^godz') then return n * 3600, 3600 end
    return n * 60, 60
end

-- czas do przejecia jako tekst; nil = mozna juz teraz
local function timerText(g, now)
    local rem = (g.cd or 0) - now
    if rem <= 0 then return nil end
    if (g.cdp or 60) >= 60 then
        if rem >= 3600 then return ('~%dh %02dm'):format(floor(rem / 3600), floor(rem % 3600 / 60)) end
        return ('~%d min'):format(ceil(rem / 60))
    end
    return ('%d:%02d'):format(floor(rem / 60), rem % 60)
end

local function sampReady()
    return A.ready and type(isSampAvailable) == 'function' and A.sampReady()
end

local function chatBlocked()
    local ok, r = pcall(function() return sampIsChatInputActive() or sampIsDialogActive() end)
    return ok and r
end

local function pushEvent(text)
    events[#events + 1] = os.date('%H:%M:%S ') .. text
    if #events > LOG_MAX then table.remove(events, 1) end
end

local function notify(text)
    pushEvent(text)
    A.log('graffiti', stripColors(text))
    if cfg.chatMsgs then A.say('Graffiti', text, '7FD07F') end
end

local function playerPos()
    if not isPlayerPlaying(PLAYER_HANDLE) then return nil end
    return getCharCoordinates(PLAYER_PED)
end

local function dist2d(idx, px, py)
    local t = TAGS[idx]
    local dx, dy = t[1] - px, t[2] - py
    return sqrt(dx * dx + dy * dy)
end

------------------------------------------------------------------------
-- mapowanie + dane gangow
------------------------------------------------------------------------

local function learnMap(idx, sid, silent)
    if map[idx] == sid then return end
    local prevIdx = tagOf[sid]
    if prevIdx and prevIdx ~= idx then map[prevIdx] = nil; mapCount = mapCount - 1 end
    local prevSid = map[idx]
    if prevSid then tagOf[prevSid] = nil else mapCount = mapCount + 1 end
    map[idx], tagOf[sid] = sid, idx
    saveDirty, dirty = true, true
    if not silent and mapCount == SERVER_TAGS then notify('Mapowanie kompletne (100/100).') end
end

local function setGang(sid, owner, rgb, cdSecs, cdPrec, zone)
    local now = os.time()
    local g = gangs[sid]
    local changed = false
    if not g then
        g = {}
        gangs[sid] = g
        changed = true
    end
    if owner and g.o ~= owner then
        if g.o and now - (g.t or 0) <= cfg.notifyFreshSec then
            pendingChanges[#pendingChanges + 1] = { sid = sid, from = g.o, to = owner }
        end
        g.o = owner
        changed = true
    end
    if rgb and g.c ~= rgb then g.c = rgb; changed = true end
    if cdSecs then
        local cd = cdSecs > 0 and now + cdSecs or 0
        -- "mozna juz" po odliczaniu: zostaw moment odblokowania (dla powiadomienia)
        if cd == 0 and (g.cd or 0) > 0 then cd = min(g.cd, now) end
        -- zgrubny odczyt (minuty) nie psuje dokladnego (sekundy), jesli sie z nim zgadza
        local keep = g.cd and g.cdp and cdPrec > g.cdp and g.cd > now and abs(cd - g.cd) < cdPrec
        if not keep then
            if abs((g.cd or 0) - cd) > 2 then changed = true end
            g.cd, g.cdp = cd, cdPrec
        end
    end
    if zone and zone ~= '' and g.z ~= zone then g.z = zone; changed = true end
    g.t = now
    if changed then saveDirty, dirty = true, true end
end

local function inRange(sid)
    if cfg.unlockRange <= 0 then return true end
    local idx = tagOf[sid]
    if not idx or not isPlayerPlaying(PLAYER_HANDLE) then return false end
    local px, py = getCharCoordinates(PLAYER_PED)
    local t = TAGS[idx]
    return (t[1] - px) ^ 2 + (t[2] - py) ^ 2 <= cfg.unlockRange ^ 2
end

local function flushChanges()
    if #pendingChanges == 0 then return end
    local keep = {}
    for _, c in ipairs(pendingChanges) do
        if inRange(c.sid) then keep[#keep + 1] = c end
    end
    pendingChanges = keep
    local n = #pendingChanges
    if n == 0 then return end
    if cfg.notifyChanges then
        if n <= 3 then
            for _, c in ipairs(pendingChanges) do
                local g = gangs[c.sid]
                notify(('#%d %s: %s -> %s'):format(c.sid, g and g.z or '?', gangTag(c.from), gangTag(c.to)))
            end
        else
            notify(('%d graffiti zmienilo wlasciciela.'):format(n))
        end
    end
    pendingChanges = {}
end

local function tagInfo(idx)
    local sid = map[idx]
    return sid, sid and gangs[sid]
end

local function isPaintable(g) return (g.cd or 0) <= os.time() end

local function isEnemy(g)
    return g and g.o and g.o ~= '-' and cfg.myGang ~= '' and not isMine(g.o)
end

local function isTarget(idx)
    local _, g = tagInfo(idx)
    return isEnemy(g) and isPaintable(g)
end

local function blipColour(idx, phase)
    local _, g = tagInfo(idx)
    if g and g.o and g.o ~= '-' and g.c then
        if phase and cfg.blinkReady and isEnemy(g) and isPaintable(g) then return -1 end -- bialy (RGBA FFFFFFFF)
        return toInt32(brighten(g.c) * 256 + 0xFF)
    end
    return cfg.colourUnknown
end

local function passesFilter(idx)
    if cfg.filter == 'all' then return true end
    local _, g = tagInfo(idx)
    if not g or not g.o then return cfg.filter ~= 'paint' end
    if isMine(g.o) then return false end
    if cfg.filter == 'paint' then return isPaintable(g) end
    return true
end

------------------------------------------------------------------------
-- zrodla: labele 3D (live) i dialog /graffiti (snapshot)
------------------------------------------------------------------------

local function nearestTagIdx(x, y, z)
    local best, bestD2
    for i = 1, #TAGS do
        local t = TAGS[i]
        local dx, dy, dz = t[1] - x, t[2] - y, t[3] - z
        local d2 = dx * dx + dy * dy + dz * dz
        if not bestD2 or d2 < bestD2 then best, bestD2 = i, d2 end
    end
    return best, sqrt(bestD2)
end

-- "Graffiti gangowe - Grove Street (23)\n{FFFFFF}Wlasciciel: {028151}gang CWL\n... za {028151}2 minuty"
local function parseLabel(text)
    local lines = {}
    for l in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
    local zone, sid = clean(lines[1] or ''):match('^' .. LABEL_PREFIX .. ' %- (.-) %((%d+)%)')
    sid = tonumber(sid)
    if not sid then return nil end
    local ownerAt
    for i, l in ipairs(lines) do
        if l:find('ciciel:', 1, true) then ownerAt = i; break end
    end
    if not ownerAt then return nil end
    local ownerRaw = lines[ownerAt]:match('ciciel:%s*(.*)$') or ''
    local cd, cdp
    for i = ownerAt + 1, #lines do
        local a, b = parseCooldown(stripColors(lines[i]))
        if a then cd, cdp = a, b end
    end
    return {
        sid = sid, zone = zone, owner = ownerName(ownerRaw),
        rgb = tonumber(ownerRaw:match('{(%x%x%x%x%x%x)}') or '', 16), cd = cd, cdp = cdp,
    }
end

local function scanLabels()
    if not sampReady() or type(sampIs3dTextDefined) ~= 'function' then return end
    local ok, err = pcall(function()
        for i = 0, MAX_LABELS - 1 do
            if sampIs3dTextDefined(i) then
                local text, _, x, y, z = sampGet3dTextInfoById(i)
                if text and x and text:find(LABEL_PREFIX, 1, true) then
                    local info = parseLabel(text)
                    if info and info.sid < SERVER_TAGS then
                        local idx, d = nearestTagIdx(x, y, z)
                        if d <= LABEL_MATCH_RADIUS then learnMap(idx, info.sid) end
                        setGang(info.sid, info.owner, info.rgb, info.cd, info.cdp, info.zone)
                    end
                end
            end
        end
    end)
    if not ok then A.log('graffiti', 'labele: ' .. tostring(err)) end
    flushChanges()
end

-- wiersz: "0\tIdlewood\t{028151}gang CWL\t{C43030}za 20 minut"
local function parseDialog(text)
    local n = 0
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        local c1, c2, c3, c4 = line:match('^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)')
        local sid = c1 and tonumber(stripColors(c1):match('^%s*(%d+)%s*$'))
        if sid and sid < SERVER_TAGS then
            local cd, cdp = parseCooldown(stripColors(c4))
            setGang(sid, ownerName(c3), tonumber(c3:match('{(%x%x%x%x%x%x)}') or '', 16), cd, cdp, clean(c2))
            n = n + 1
        end
    end
    return n
end

local function pollDialog()
    if not sampReady() then return end
    local ok, err = pcall(function()
        if not sampIsDialogActive() then lastDialogText = nil; return end
        if not sampGetDialogCaption():find(LABEL_PREFIX, 1, true) then return end
        local text = sampGetDialogText()
        if text == lastDialogText then return end
        lastDialogText = text
        if parseDialog(text) > 0 then
            snapshotAt = os.time()
            flushChanges()
        end
    end)
    if not ok then A.log('graffiti', 'dialog: ' .. tostring(err)) end
end

------------------------------------------------------------------------
-- auto-odswiezanie: /graffiti -> "Zobacz wszystkie" -> strony -> zamkniecie
------------------------------------------------------------------------

local AUTO_TIMEOUT, AUTO_MAX_FAIL = 4, 3
local auto = { state = 'idle', deadline = 0, nextAt = 0, failures = 0, disabled = false, lastPage = nil, force = false }

local function dialogLines(text)
    local lines = {}
    for l in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
    if lines[#lines] == '' then lines[#lines] = nil end
    return lines
end

local function findItem(text, style, needle)
    local offset = style == 5 and 1 or 0
    for i, l in ipairs(dialogLines(text)) do
        if i > offset and clean(l):find(needle, 1, true) then return i - 1 - offset end
    end
end

local function graffitiDialog()
    if not sampIsDialogActive() then return nil end
    local cap = sampGetDialogCaption()
    if not cap:find(LABEL_PREFIX, 1, true) then return false end
    return cap, sampGetDialogText(), sampGetCurrentDialogType()
end

local function pressItem(idx, button)
    sampSetCurrentDialogListItem(idx)
    sampCloseCurrentDialogWithButton(button)
end

local function autoSchedule(delay)
    auto.state = 'idle'
    auto.nextAt = os.clock() + (delay or cfg.autoRefreshMin * 60)
end

local function autoFail(reason)
    A.log('graffiti', 'auto /graffiti: ' .. reason)
    auto.failures = auto.failures + 1
    if auto.failures >= AUTO_MAX_FAIL then
        auto.disabled = true
        notify('Auto /graffiti wstrzymane (3 nieudane proby) - wlacz ponownie w menu.')
    end
    autoSchedule()
end

local function autoDone()
    auto.failures = 0
    flushChanges()
    dirty = true
    autoSchedule()
end

local function autoStep()
    local now = os.clock()
    if auto.state == 'idle' then
        if not (cfg.autoRefresh or auto.force) or auto.disabled or now < auto.nextAt then return end
        if A.zoneBotBusy then return autoSchedule(3) end          -- Strefy Bot jedzie: /graffiti nie przeszkadza w /strefy
        if not auto.force and os.time() - snapshotAt < cfg.autoRefreshMin * 60 then return autoSchedule(30) end
        if A.menuOpen or not isPlayerPlaying(PLAYER_HANDLE) or sampIsDialogActive() or sampIsChatInputActive()
            or sampIsCursorActive() then
            return autoSchedule(5)
        end
        auto.force = false
        sampProcessChatInput('/graffiti')
        auto.state, auto.deadline, auto.lastPage = 'menu', now + AUTO_TIMEOUT, nil
        return
    end

    local cap, text, style = graffitiDialog()
    if now > auto.deadline then
        if auto.state == 'closing' then return autoDone() end
        local seen = (cap == false) and 'inny dialog' or (cap and clean(cap)) or (sampIsDialogActive() and clean(sampGetDialogCaption()) or 'brak dialogu')
        if cap then sampCloseCurrentDialogWithButton(0) end
        return autoFail('timeout w stanie ' .. auto.state .. ', widoczne: ' .. tostring(seen):sub(1, 60))
    end
    if cap == false then return autoFail('pojawil sie inny dialog') end
    if not cap then return end

    if auto.state == 'menu' then
        local item = findItem(text, style, 'wszystkie')
        if not item then
            sampCloseCurrentDialogWithButton(0)
            return autoFail('menu bez opcji "Zobacz wszystkie"')
        end
        pressItem(item, 1)
        auto.state, auto.deadline = 'page', now + AUTO_TIMEOUT
    elseif auto.state == 'page' then
        local k, n = clean(cap):match('strona (%d+)/(%d+)')
        k, n = tonumber(k), tonumber(n)
        if not k then
            sampCloseCurrentDialogWithButton(0)
            return autoFail('nieoczekiwany dialog: ' .. clean(cap))
        end
        if k == auto.lastPage then return end
        auto.lastPage = k
        if parseDialog(text) > 0 then snapshotAt = os.time() end
        lastDialogText = text
        local item = k < n and findItem(text, style, 'Dalej')
        if item then
            pressItem(item, 1)
            auto.deadline = now + AUTO_TIMEOUT
        else
            sampCloseCurrentDialogWithButton(0)
            auto.state, auto.deadline = 'closing', now + 1.5
        end
    elseif auto.state == 'closing' then
        sampCloseCurrentDialogWithButton(0)    -- serwer moze po ESC wrocic do menu
    end
end

local function runAuto()
    if not sampReady() or type(sampProcessChatInput) ~= 'function' then return end
    local ok, err = pcall(autoStep)
    if not ok then
        auto.disabled = true
        A.log('graffiti', 'auto /graffiti crash: ' .. tostring(err))
        notify('Auto /graffiti wylaczone (blad, szczegoly w moonloader.log).')
    end
end

------------------------------------------------------------------------
-- persystencja
------------------------------------------------------------------------

local function save()
    local m, gs = {}, {}
    for idx, sid in pairs(map) do m[tostring(idx)] = sid end
    for sid, g in pairs(gangs) do gs[tostring(sid)] = g end
    A.saveJson(FILE, { version = 4, config = cfg, map = m, gangs = gs, snapshotAt = snapshotAt })
    saveDirty = false
end

local function sanitize()
    if cfg.mode ~= 'near' and cfg.mode ~= 'all' then cfg.mode = DEFAULTS.mode end
    if cfg.filter ~= 'all' and cfg.filter ~= 'enemy' and cfg.filter ~= 'paint' then cfg.filter = DEFAULTS.filter end
    cfg.maxBlips       = A.clamp(floor(cfg.maxBlips), 1, #TAGS)
    cfg.radius         = max(0, cfg.radius)
    cfg.refreshMs      = A.clamp(cfg.refreshMs, 100, 5000)
    cfg.labelScanMs    = A.clamp(cfg.labelScanMs, 250, 10000)
    cfg.autoRefreshMin = A.clamp(floor(cfg.autoRefreshMin), 1, 60)
    cfg.minRadarLum    = A.clamp(cfg.minRadarLum, 0, 254)
    cfg.notifyFreshSec = A.clamp(cfg.notifyFreshSec, 0, 86400)
    cfg.hudFontSize    = A.clamp(floor(cfg.hudFontSize), 6, 40)
    cfg.hudSoon        = A.clamp(floor(cfg.hudSoon), 0, 6)
    cfg.botSpeed       = A.clamp(floor(cfg.botSpeed), 6, 35)
    if cfg.botMode ~= 'bike' and cfg.botMode ~= 'foot' then cfg.botMode = 'bike' end
end

local function load()
    cfg = A.deepCopy(DEFAULTS)
    local data = A.loadJson(FILE)
    if not data then
        data = A.loadJson(OLD_FILE)        -- import z TagBlips
        if data then A.log('graffiti', 'zaimportowano ' .. OLD_FILE) end
    end
    if data then
        if type(data.config) == 'table' then
            A.overlay(cfg, data.config)
            if data.config.botBike == false and data.config.botMode == nil then cfg.botMode = 'foot' end
        end
        if type(data.map) == 'table' then
            for k, v in pairs(data.map) do
                local idx, sid = tonumber(k), tonumber(v)
                if idx and sid and TAGS[idx] and sid >= 0 and sid < SERVER_TAGS then learnMap(idx, sid, true) end
            end
        end
        if type(data.gangs) == 'table' then
            for k, g in pairs(data.gangs) do
                local sid = tonumber(k)
                if sid and type(g) == 'table' and type(g.o) == 'string' then
                    gangs[sid] = {
                        o = g.o, c = tonumber(g.c), cd = tonumber(g.cd) or 0, cdp = tonumber(g.cdp) or 60,
                        z = type(g.z) == 'string' and g.z or nil, t = tonumber(g.t) or 0,
                    }
                end
            end
        end
        snapshotAt = tonumber(data.snapshotAt) or 0
    end
    for idx, sid in pairs(SEED_MAP) do
        if not map[idx] and not tagOf[sid] then learnMap(idx, sid, true) end
    end
    -- odblokowania sprzed startu nie sa "nowe"
    local now = os.time()
    for sid, g in pairs(gangs) do
        if (g.cd or 0) <= now then unlockSeen[sid] = g.cd or 0 end
    end
    cfg.chatMsgs, cfg.notifyUnlock, cfg.notifyChanges = false, false, false
    cfg.myGang = A.trim(cfg.myGang)
    if cfg.myGang == '' then cfg.myGang = DEFAULTS.myGang end
    sanitize()
    save()
end

------------------------------------------------------------------------
-- blipy
------------------------------------------------------------------------

local function dropBlip(idx)
    local b = active[idx]
    if b and doesBlipExist(b) then removeBlip(b) end
    active[idx], activeColour[idx] = nil, nil
end

local function clearBlips()
    for idx in pairs(active) do dropBlip(idx) end
end

local function countActive()
    local n = 0
    for _ in pairs(active) do n = n + 1 end
    return n
end

local function inWorld()
    if not isPlayerPlaying(PLAYER_HANDLE) then return false end
    return not (cfg.hideInInteriors and getActiveInterior() ~= 0)
end

local function byDist(a, b) return dist[a] < dist[b] end

local function rank(px, py)
    local n = 0
    for idx = 1, #TAGS do
        if passesFilter(idx) then
            local t = TAGS[idx]
            local dx, dy = t[1] - px, t[2] - py
            dist[idx] = dx * dx + dy * dy
            n = n + 1
            order[n] = idx
        end
    end
    for i = #order, n + 1, -1 do order[i] = nil end
    if n > 1 then table.sort(order, byDist) end
    return n
end

local function findTarget(px, py)
    local best, bestD2
    for idx = 1, #TAGS do
        if isTarget(idx) then
            local t = TAGS[idx]
            local dx, dy = t[1] - px, t[2] - py
            local d2 = dx * dx + dy * dy
            if not bestD2 or d2 < bestD2 then best, bestD2 = idx, d2 end
        end
    end
    return best
end

local function sync(phase)
    for k in pairs(want) do want[k] = nil end
    targetIdx = nil
    local world = inWorld()
    if world then
        local px, py = getCharCoordinates(PLAYER_PED)
        targetIdx = findTarget(px, py)
        if cfg.enabled then
            local n = rank(px, py)
            local all = cfg.mode == 'all' or cfg.filter == 'paint'
            local limit = all and n or min(n, cfg.maxBlips)
            local r2 = (not all and cfg.radius > 0) and cfg.radius * cfg.radius or math.huge
            for i = 1, limit do
                local idx = order[i]
                if dist[idx] > r2 then break end
                want[idx] = blipColour(idx, phase)
            end
            if targetIdx then want[targetIdx] = blipColour(targetIdx, phase) end
        end
    end

    for idx, b in pairs(active) do
        if not want[idx] or not doesBlipExist(b) then dropBlip(idx) end
    end

    local failed = 0
    for idx, colour in pairs(want) do
        local b = active[idx]
        if not b then
            local t = TAGS[idx]
            local ok, h = pcall(addBlipForCoord, t[1], t[2], t[3])
            if ok and h and doesBlipExist(h) then
                changeBlipDisplay(h, BLIP_DISPLAY_BLIP_ONLY)
                active[idx], b = h, h
            else
                failed = failed + 1
            end
        end
        if b and activeColour[idx] ~= colour then
            changeBlipColour(b, colour)
            activeColour[idx] = colour
        end
    end

    if failed > 0 then
        if not poolWarned then
            poolWarned = true
            notify(('Pula blipow pelna, %d graffiti nie weszlo. %s'):format(
                failed, cfg.mode == 'all' and 'Przelacz na tryb near.' or 'Zmniejsz limit blipow.'))
        end
    else
        poolWarned = false
    end
end

------------------------------------------------------------------------
-- odblokowania (timer przejecia doszedl do zera)
------------------------------------------------------------------------

local function checkUnlocks()
    if not cfg.notifyUnlock or cfg.myGang == '' then return end
    local now = os.time()
    local px, py = playerPos()
    local list = {}
    for sid, g in pairs(gangs) do
        local cd = g.cd or 0
        if cd > 0 and cd <= now and unlockSeen[sid] ~= cd then
            unlockSeen[sid] = cd
            if isEnemy(g) and now - cd < 120 then
                local idx = tagOf[sid]
                local d = (idx and px) and dist2d(idx, px, py) or nil
                if cfg.unlockRange <= 0 or (d and d <= cfg.unlockRange) then
                    list[#list + 1] = { sid = sid, g = g, d = d }
                end
            end
        end
    end
    if #list == 0 then return end
    table.sort(list, function(a, b) return (a.d or 1e9) < (b.d or 1e9) end)
    if #list <= 2 then
        for _, e in ipairs(list) do
            notify(('{FFD24A}#%d %s{FFFFFF} [%s] mozna przejac%s'):format(e.sid, e.g.z or '?', gangTag(e.g.o),
                e.d and (' - ' .. floor(e.d + 0.5) .. ' m') or ''))
        end
    else
        notify(('{FFD24A}%d graffiti{FFFFFF} mozna przejac (najblizsze #%d %s).'):format(#list, list[1].sid,
            list[1].g.z or '?'))
    end
end

------------------------------------------------------------------------
-- akcje
------------------------------------------------------------------------

local function describe(idx)
    local sid, g = tagInfo(idx)
    if not sid then return ('graffiti ?%d'):format(idx) end
    return ('#%d %s %s'):format(sid, g and g.z or '?', gangTag(g and g.o))
end

local function setWaypoint(idx)
    if type(placeWaypoint) ~= 'function' then notify('Ta wersja MoonLoadera nie ma placeWaypoint.') return end
    local t = TAGS[idx]
    placeWaypoint(t[1], t[2], t[3])
    local px, py = playerPos()
    notify(('Waypoint: %s%s.'):format(describe(idx), px and (', ' .. floor(dist2d(idx, px, py) + 0.5) .. ' m') or ''))
end

local function cmdNext()
    local px, py = playerPos()
    if not px then return end
    if cfg.myGang == '' then notify('Najpierw ustaw swoj gang w menu (Graffiti > Moj gang).') return end
    local idx = findTarget(px, py)
    if not idx then notify('Brak znanych graffiti do przejecia.') return end
    setWaypoint(idx)
end

local function set(key, v)
    cfg[key] = v
    sanitize()
    save()
    dirty = true
end

------------------------------------------------------------------------
-- HUD (budowany co 0.5 s, rysowany co klatke)
------------------------------------------------------------------------

local hudLines, hudAt = {}, -1e9
local soonList = {}       -- najblizsze odblokowania cudzych: { idx, sid, g, rem, d }
local stats = { ready = 0, locked = 0 }

local function rebuildSoon(px, py)
    local now = os.time()
    local n, ready, locked = 0, 0, 0
    for i = #soonList, 1, -1 do soonList[i] = nil end
    for sid, g in pairs(gangs) do
        if isEnemy(g) then
            local rem = (g.cd or 0) - now
            if rem <= 0 then
                ready = ready + 1
            else
                locked = locked + 1
                local idx = tagOf[sid]
                n = n + 1
                soonList[n] = { idx = idx, sid = sid, g = g, rem = rem, d = (idx and px) and dist2d(idx, px, py) or nil }
            end
        end
    end
    table.sort(soonList, function(a, b) return a.rem < b.rem end)
    stats.ready, stats.locked = ready, locked
end

-- najblizszy teleport serwera (/teles) do graffiti: krotko, np. "/LS 45m"
local tpCache = {}
local function tpTag(idx)
    if not idx or not TAGS[idx] then return '' end
    local c = tpCache[idx]
    if not c then
        local t = TAGS[idx]
        local best, bd = nil, 1e18
        for _, tp in ipairs(A.TELEPORTS or {}) do
            local d = (tp[2] - t[1]) ^ 2 + (tp[3] - t[2]) ^ 2 + (tp[4] - t[3]) ^ 2
            if d < bd then best, bd = tp, d end
        end
        c = best and ('  {FF66FF}%s {AAAAAA}%dm'):format(best[1], floor(sqrt(bd) + 0.5)) or ''
        tpCache[idx] = c
    end
    return c
end

local function buildHud()
    local px, py = getCharCoordinates(PLAYER_PED)
    rebuildSoon(px, py)

    local counts, colors = {}, {}
    for sid = 0, SERVER_TAGS - 1 do
        local g = gangs[sid]
        if g and g.o then
            local tag = gangTag(g.o)
            counts[tag] = (counts[tag] or 0) + 1
            colors[tag] = g.c
        end
    end
    local list = {}
    for tag, n in pairs(counts) do list[#list + 1] = { tag = tag, n = n } end
    table.sort(list, function(a, b) return a.n > b.n end)

    local line1 = '{7FD07F}Graffiti'
    for i = 1, min(#list, 3) do
        local t = list[i].tag
        line1 = line1 .. ('  {%s}%s {FFFFFF}%d'):format(colors[t] and hex(colors[t]) or 'AAAAAA', t, list[i].n)
    end
    if mapCount < SERVER_TAGS then line1 = line1 .. ('  {AAAAAA}mapa %d/%d'):format(mapCount, SERVER_TAGS) end

    local out = { line1 }
    if cfg.myGang == '' then
        out[2] = '{AAAAAA}ustaw gang w menu'
    else
        if targetIdx then
            local sid, g = tagInfo(targetIdx)
            out[#out + 1] = ('{33FF66}teraz {FFFFFF}%s {%s}%s {AAAAAA}%d m%s%s'):format(
                g.z or '?', hex(g.c), gangTag(g.o), floor(dist2d(targetIdx, px, py) + 0.5),
                stats.ready > 1 and ('  +' .. (stats.ready - 1)) or '', tpTag(targetIdx))
        else
            out[#out + 1] = '{AAAAAA}nic do przejecia'
        end
        local now = os.time()
        for i = 1, min(cfg.hudSoon, #soonList) do
            local e = soonList[i]
            out[#out + 1] = ('{FFD24A}%s {FFFFFF}%s {%s}%s{AAAAAA}%s%s'):format(
                timerText(e.g, now) or 'teraz', e.g.z or '?', hex(e.g.c), gangTag(e.g.o),
                e.d and ('  ' .. floor(e.d + 0.5) .. ' m') or '', tpTag(e.idx))
        end
    end
    hudLines = out
end

local function textWidth(s)
    if type(renderGetFontDrawTextLength) == 'function' then return renderGetFontDrawTextLength(font, stripColors(s)) end
    return #stripColors(s) * cfg.hudFontSize * 0.6
end

local function lineHeight()
    if type(renderGetFontDrawHeight) == 'function' then return renderGetFontDrawHeight(font) + 2 end
    return cfg.hudFontSize * 1.8
end

local function drawHud(now)
    if not cfg.hud or not inWorld() then return end
    if now - hudAt >= 0.5 then
        hudAt = now
        buildHud()
    end
    local lh = lineHeight()
    local w = 0
    for _, l in ipairs(hudLines) do w = max(w, textWidth(l)) end
    local h = lh * #hudLines
    local x, y = A.hudPlace('graffiti', w + 2 * HUD_PAD, h + 2 * HUD_PAD, 0.015, 0.64)
    renderDrawBox(x, y, w + 2 * HUD_PAD, h + 2 * HUD_PAD, 0x60000000)
    for i, l in ipairs(hudLines) do
        renderFontDrawText(font, l, x + HUD_PAD, y + HUD_PAD + (i - 1) * lh, 0xFFFFFFFF)
    end
end

------------------------------------------------------------------------
-- modul
------------------------------------------------------------------------

local nextDialog, nextLabels, lastSync, lastSave, nextUnlock = 0, 0, -1e9, 0, 0

------------------------------------------------------------------------
-- STREFY BOT (osobna funkcja = wlasny limit zmiennych lokalnych LuaJIT)
--  Jedzie (nie zsiada) na checkpoint strefy, wciska Y, stoi 60 s, az serwer napisze "podbil".
--  Stan stref (czyje, kiedy mozna) z modulu Strefy: komunikaty czatu + /strefy czytane w tle.
-- Dojazd (MV): trasa po sieci drog z pamieci gry (ThePaths, A* w Lua - bez promieni kolizji, wiec bez przyciec),
-- jazda "pure pursuit" po trasie + krotkie "wasy" kolizji; pieszo: drogi, a ostatnie metry A* po kolizji z
-- twardym limitem pracy na klatke. Motor: /nrg najwyzej raz na 25 s, ten sam motor uzywany dalej,
-- dla jednego celu najwyzej jedno zsiadanie - koniec z wsiadaniem i zsiadaniem w kolko.
------------------------------------------------------------------------
local GBX = (function()
local NRG = 522
local BIKE_MIN = 60                                                -- [m] blizej idzie pieszo
local PARK_R = 7                                                   -- [m] motor staje tyle od celu
local ZONE_TIME = 60                                               -- [s] przejecie strefy
local GB = { on = false, state = 'off', why = '', space = false, yUntil = 0, yDown = false }
local ZB = { toggle = false, done = 0, skip = {}, total = 0 }
local MV = { noBike = {}, nrgNext = 0, nrgFails = 0 }               -- dojazd
local RN = { off = nil, area = {}, px = {}, py = {}, pz = {}, adj = {}, grid = {}, pen = {}, nodes = 0, why = '' }
local gbStop                                                       -- (ponizej) zatrzymanie bota
local NF = A.newNav({ tag = 'gangbot', CELL = 0.8, CLEAR = 0.32, SOFT_CLEAR = 0.8, SOFT_COST = 1.4,
    H_LOW = 0.6, H_MID = 0.95, H_HIGH = 1.4, STEP_UP = 0.7, STEP_DOWN = 2.5, DIRECT_MAX = 40, MARGIN = 20,
    MAX_EXP = 4000, WEIGHT = 1.3, BUDGET = 0.0025, STEP_MAX = 40, CACHE_TTL = 300, UNKNOWN_FAR = 60 })

local function gbLog(msg) A.log('gangbot', msg) end
local function wrap180(a) return (a + 540) % 360 - 180 end
local function hdg(px, py, x, y) return math.deg(math.atan2(-(x - px), y - py)) % 360 end
local function pad(k, v) pcall(setGameKeyState, k, v) end      -- stan pada, trzeba co klatke
local function dist2(ax, ay, bx, by) return (ax - bx) ^ 2 + (ay - by) ^ 2 end

local function camH()
    local okc, cx, cy = pcall(getActiveCameraCoordinates)
    local oka, ax, ay = pcall(getActiveCameraPointAt)
    if not (okc and oka and cx and ax) then return nil end
    local dx, dy = ax - cx, ay - cy
    if dx * dx + dy * dy < 1e-4 then return nil end
    return math.deg(math.atan2(-dx, dy)) % 360
end

-- klawisz z klawiatury trzymany przez bota (oznaczony, zeby nie byl skrotem dla innych modulow)
local function rawKey(vk, defScan, on)
    if on then A.synth = { vk = vk, untilT = A.now() + 0.08 } end
    pcall(function()
        local scan = tonumber(A.ffi.C.MapVirtualKeyA(vk, 0)) or 0
        if scan == 0 then scan = defScan end
        A.ffi.C.keybd_event(0, scan, 8 + (on and 0 or 2), 0)
    end)
end

local function space(on)                                           -- sprint pieszo
    if on == GB.space then return end
    GB.space = on
    rawKey(0x20, 0x39, on)
end

local function keyY(on)                                            -- Y: start przejecia strefy
    if on == GB.yDown then return end
    GB.yDown = on
    rawKey(0x59, 0x15, on)
end

local function releaseAll() space(false); keyY(false) end

-- komenda jak wpisana w czat (dziala tez dla komend serwera); zapas: sampSendChat
local function sendCmd(cmd)
    gbLog(cmd)
    if type(sampProcessChatInput) == 'function' and pcall(sampProcessChatInput, cmd) then return end
    pcall(sampSendChat, cmd)
end

local function myCar()
    if not isCharInAnyCar(PLAYER_PED) then return nil end
    local ok, car = pcall(storeCarCharIsInNoSave, PLAYER_PED)
    return ok and car or nil
end

local function vehOk(car)
    if not car then return false end
    local ok, r = pcall(function() return doesVehicleExist(car) and not isCarDead(car) end)
    return ok and r == true
end

-- wolne NRG-500 w promieniu rad (bez kierowcy)
local function findBike(px, py, rad)
    local ok, list = pcall(getAllVehicles)
    if not ok or type(list) ~= 'table' then return nil end
    local best, bd
    for _, v in ipairs(list) do
        if doesVehicleExist(v) and getCarModel(v) == NRG and not isCarDead(v) then
            local x, y = getCarCoordinates(v)
            local d = dist2(x, y, px, py)
            if d < rad * rad and (not bd or d < bd) then
                local okD, drv = pcall(getDriverOfCar, v)
                if not (okD and drv and drv ~= -1 and doesCharExist(drv)) then best, bd = v, d end
            end
        end
    end
    return best
end

-- ------------------------------------------------------------ kopiec (A* po sieci drog)
local function hpush(h, f, id)
    local i = #h + 1
    h[i] = { f, id }
    while i > 1 do
        local q = floor(i / 2)
        if h[q][1] <= h[i][1] then break end
        h[i], h[q] = h[q], h[i]
        i = q
    end
end

local function hpop(h)
    local n = #h
    if n == 0 then return nil end
    local top = h[1]
    h[1] = h[n]
    h[n] = nil
    n = n - 1
    local i = 1
    while true do
        local l, r, s = i * 2, i * 2 + 1, i
        if l <= n and h[l][1] < h[s][1] then s = l end
        if r <= n and h[r][1] < h[s][1] then s = r end
        if s == i then break end
        h[i], h[s] = h[s], h[i]
        i = s
    end
    return top[2]
end

-- ------------------------------------------------------------ SIEC DROG z pamieci gry (CPathFind ThePaths @0x96F050)
-- Wezly pojazdow kazdego wczytanego obszaru 750x750 (CPathNode 0x1C: pozycja int16/8 @+8, pierwsze polaczenie @+0x10,
-- obszar @+0x12, numer @+0x14, liczba polaczen = 4 bity @+0x18). Kazdy odczyt sprawdzany IsBadReadPtr, a uklad
-- weryfikowany (wezel i ma numer i, polaczenia pojazdow prowadza tylko do wezlow pojazdow) - gdy cos sie nie zgadza,
-- siec drog jest wylaczona i bot jedzie samymi "wasami" (bez ryzyka dla gry).
local PATHS = 0x96F050

local function rdOk(addr, n)
    return addr >= 0x10000 and A.ffi.C.IsBadReadPtr(A.ffi.cast('void*', addr), n or 4) == 0
end
local function ru32(a) return tonumber(A.ffi.cast('uint32_t*', a)[0]) end
local function ru16(a) return tonumber(A.ffi.cast('uint16_t*', a)[0]) end
local function ri16(a) return tonumber(A.ffi.cast('int16_t*', a)[0]) end
local function rnNodes(a) local p = PATHS + 0x804 + a * 4; return rdOk(p) and ru32(p) or 0 end
local function rnLinks(a) local p = PATHS + 0xA44 + a * 4; return rdOk(p) and ru32(p) or 0 end
local function rnCount(off, a) local p = PATHS + off + a * 4; return rdOk(p) and ru32(p) or nil end

local function rnNode(b, a, i)
    local n = b + i * 0x1C
    if not rdOk(n, 0x1C) then return nil end
    if ru16(n + 0x12) ~= a or ru16(n + 0x14) ~= i then return nil end
    return n
end

-- polaczenia wezla: plaska lista { obszar, numer, obszar, numer, ... }
local function rnTargets(a, n)
    local out = {}
    local base, cnt = ru16(n + 0x10), ru32(n + 0x18) % 16
    local L = rnLinks(a)
    if cnt == 0 or L < 0x10000 or not rdOk(L + base * 4, cnt * 4) then return out end
    for k = 0, cnt - 1 do
        local p = L + (base + k) * 4
        out[#out + 1] = ru16(p)
        out[#out + 1] = ru16(p + 2)
    end
    return out
end

-- tablica z liczba wezlow pojazdow (m_dwNumVehicleNodes) - szukana i sprawdzana, nie zgadywana
local function rnDetect()
    local loaded = {}
    for a = 0, 63 do
        local b = rnNodes(a)
        if b >= 0x10000 and rnNode(b, a, 0) then loaded[#loaded + 1] = a end
    end
    if #loaded == 0 then return nil, 'brak wczytanych wezlow drog' end
    for off = 0xE00, 0x1700, 4 do
        local ok, evidence = true, 0
        for _, a in ipairs(loaded) do
            local V = rnCount(off, a)
            local b = rnNodes(a)
            if not V or V < 2 or V > 30000 or not rnNode(b, a, V - 1) then ok = false; break end
            for i = math.max(0, V - 10), V - 1 do                  -- ostatnie wezly pojazdow -> tylko wezly pojazdow
                local n = rnNode(b, a, i)
                if not n then ok = false; break end
                local t = rnTargets(a, n)
                for k = 1, #t, 2 do
                    local ta, tn = t[k], t[k + 1]
                    local tv = ta < 64 and rnNodes(ta) >= 0x10000 and rnCount(off, ta)
                    if tv and tn >= tv then ok = false; break end
                end
                if not ok then break end
            end
            if not ok then break end
            local nP = rnNode(b, a, V)                             -- pierwszy wezel pieszy -> tylko wezly piesze
            if nP then
                local t = rnTargets(a, nP)
                for k = 1, #t, 2 do
                    local ta, tn = t[k], t[k + 1]
                    local tv = ta < 64 and rnNodes(ta) >= 0x10000 and rnCount(off, ta)
                    if tv and tn < tv then ok = false; break end
                end
                if not ok then break end
                if #t > 0 then evidence = evidence + 1 end
            end
        end
        if ok and evidence > 0 then return off end
    end
    return nil, 'nie znalazlem liczby wezlow drog'
end

local function gridKey(x, y) return floor((x + 3000) / 50) * 256 + floor((y + 3000) / 50) end

local function rnDropArea(a)
    local ar = RN.area[a]
    if not ar then return end
    for _, id in ipairs(ar.ids) do RN.px[id], RN.py[id], RN.pz[id], RN.adj[id] = nil, nil, nil, nil end
    RN.nodes = RN.nodes - #ar.ids
    RN.area[a] = nil
end

-- budowa obszaru po kawalku (400 wezlow na klatke - bez przyciec)
local function rnBuildChunk(B)
    local a, b, L = B.a, B.b, B.L
    local last = min(B.V, B.i + 400) - 1
    for i = B.i, last do
        local n = b + i * 0x1C
        local x, y, z = ri16(n + 8) / 8, ri16(n + 10) / 8, ri16(n + 12) / 8
        local water = (ru32(n + 0x18) % 256) >= 128 and z < 3
        if not water then
            local id = a * 65536 + i
            local l = {}
            local base, cnt = ru16(n + 0x10), ru32(n + 0x18) % 16
            if cnt > 0 and L >= 0x10000 and rdOk(L + base * 4, cnt * 4) then
                for k = 0, cnt - 1 do
                    local p = L + (base + k) * 4
                    local ta = ru16(p)
                    if ta < 64 then l[#l + 1] = ta * 65536 + ru16(p + 2) end
                end
            end
            RN.px[id], RN.py[id], RN.pz[id], RN.adj[id] = x, y, z, l
            B.ids[#B.ids + 1] = id
        end
    end
    B.i = last + 1
    if B.i >= B.V then
        RN.area[a] = { b = b, V = B.V, ids = B.ids }
        RN.nodes = RN.nodes + #B.ids
        RN.build, RN.gridDirty = nil, true
    end
end

-- true = siec drog gotowa, 'busy' = jeszcze sie buduje (sprobuj w nastepnej klatce), false = niedostepna
local function rnUpdate()
    local now = A.now()
    if RN.off == false then
        if (RN.tries or 0) >= 5 or now < (RN.retryAt or 0) then return false end
        RN.off = nil
    end
    if RN.off == nil then
        local ok, off, why = pcall(rnDetect)
        if ok and off then
            RN.off = off
            gbLog(('siec drog z pamieci gry: OK (liczniki @+0x%X)'):format(off))
        else
            RN.off, RN.tries, RN.retryAt = false, (RN.tries or 0) + 1, now + 20
            RN.why = ok and tostring(why) or tostring(off)
            if RN.tries == 1 or RN.tries >= 5 then
                gbLog('siec drog z pamieci gry niedostepna (' .. RN.why .. ')' .. (RN.tries >= 5 and ' - jazda bez trasy po drogach' or ''))
            end
            return false
        end
    end
    if RN.build then
        local B = RN.build
        local okB, errB = pcall(rnBuildChunk, B)
        if not okB then
            gbLog('siec drog: blad budowy obszaru ' .. B.a .. ': ' .. tostring(errB))
            RN.area[B.a], RN.build = { b = B.b, V = B.V, ids = B.ids }, nil
            RN.nodes, RN.gridDirty = RN.nodes + #B.ids, true
        end
        return 'busy'
    end
    local changed = false
    for a = 0, 63 do
        local b = rnNodes(a)
        local V = b >= 0x10000 and (rnCount(RN.off, a) or 0) or 0
        local ar = RN.area[a]
        if b < 0x10000 then
            if ar then rnDropArea(a); changed = true end
        elseif not ar or ar.b ~= b or ar.V ~= V then
            rnDropArea(a)
            if not (V > 0 and V < 30000 and rdOk(b, V * 0x1C)) then V = 0 end
            RN.build = { a = a, b = b, V = V, i = 0, ids = {}, L = rnLinks(a) }
            if V == 0 then RN.area[a], RN.build = { b = b, V = 0, ids = {} }, nil end
            return 'busy'
        end
    end
    if changed then RN.gridDirty = true end
    if RN.gridDirty then
        RN.gridDirty = false
        local grid = {}
        for _, ar in pairs(RN.area) do
            for _, id in ipairs(ar.ids) do
                local k = gridKey(RN.px[id], RN.py[id])
                local c = grid[k]
                if not c then c = {}; grid[k] = c end
                c[#c + 1] = id
            end
        end
        RN.grid = grid
    end
    return RN.nodes > 0
end

-- najblizszy wezel (z kara za roznice wysokosci - wiadukty)
local function rnNearest(x, y, z, maxR)
    local best, bd
    local gx, gy = floor((x + 3000) / 50), floor((y + 3000) / 50)
    local r = math.ceil(maxR / 50)
    for ix = gx - r, gx + r do
        for iy = gy - r, gy + r do
            local cell = RN.grid[ix * 256 + iy]
            if cell then
                for _, id in ipairs(cell) do
                    local d = sqrt(dist2(RN.px[id], RN.py[id], x, y)) + math.abs(RN.pz[id] - z) * 2
                    if not bd or d < bd then best, bd = id, d end
                end
            end
        end
    end
    if best and bd <= maxR then return best, bd end
    return nil
end

-- wezel startowy: z kilku najblizszych pierwszy, do ktorego jest prosta bez sciany
local function rnStart(x, y, z)
    local cand = {}
    local gx, gy = floor((x + 3000) / 50), floor((y + 3000) / 50)
    for ix = gx - 2, gx + 2 do
        for iy = gy - 2, gy + 2 do
            local cell = RN.grid[ix * 256 + iy]
            if cell then
                for _, id in ipairs(cell) do
                    local d = sqrt(dist2(RN.px[id], RN.py[id], x, y)) + math.abs(RN.pz[id] - z) * 2
                    if d < 90 then cand[#cand + 1] = { id, d } end
                end
            end
        end
    end
    if #cand == 0 then return nil end
    table.sort(cand, function(p, q) return p[2] < q[2] end)
    local out, rest = {}, {}                                       -- najpierw widoczne z miejsca postaci
    for i = 1, min(8, #cand) do
        local id = cand[i][1]
        if A.navLos(x, y, z + 0.3, RN.px[id], RN.py[id], RN.pz[id] + 1.0) then out[#out + 1] = id else rest[#rest + 1] = id end
    end
    for _, id in ipairs(rest) do out[#out + 1] = id end
    return out
end

-- planowanie trasy po kawalku: 'run' | tabela punktow | nil (brak)
local function rnPlan(sx, sy, sz, tx, ty, tz)
    local starts = rnStart(sx, sy, sz)
    local g = rnNearest(tx, ty, tz, 450)
    if not starts or not starts[1] or not g then return nil end
    local s = table.remove(starts, 1)
    local job = { s = s, g = g, open = {}, gs = { [s] = 0 }, from = {}, closed = {}, exp = 0, best = s, bestH = 1e18,
        alts = starts, expS = 0 }
    hpush(job.open, 0, s)
    return job
end

local function rnPath(job, last)
    local ids, c = {}, last
    while c do
        table.insert(ids, 1, c)
        c = job.from[c]
    end
    local pts = {}
    for _, id in ipairs(ids) do
        local x, y, z = RN.px[id], RN.py[id], RN.pz[id]
        if x then
            local p = pts[#pts]
            if not p or dist2(p.x, p.y, x, y) >= 9 then pts[#pts + 1] = { x = x, y = y, z = z + 1.0 } end
        end
    end
    return pts
end

-- koniec przeszukiwania bez celu: maly odciety kawalek sieci (parking, plac) - sprobuj od innego wezla startowego;
-- na koniec najlepsza z czesciowych tras
local function rnExhausted(job)
    if job.best ~= job.s and (not job.keepH or job.bestH < job.keepH) then
        job.keep, job.keepH = rnPath(job, job.best), job.bestH
    end
    if job.alts and #job.alts > 0 and job.expS < 120 then
        local s = table.remove(job.alts, 1)
        job.s, job.open, job.gs, job.from, job.closed, job.best, job.bestH, job.expS = s, {}, { [s] = 0 }, {}, {}, s, 1e18, 0
        hpush(job.open, 0, s)
        return nil
    end
    if job.keep and #job.keep > 0 then job.partial = true; return job.keep end
    return 'fail'
end

local function rnRun(job)
    local px, py, adj, pen = RN.px, RN.py, RN.adj, RN.pen
    local gx, gy = px[job.g], py[job.g]
    if not gx then return 'fail' end
    for _ = 1, 300 do
        local id = hpop(job.open)
        if not id then
            local r = rnExhausted(job)
            if r then return r end
            id = hpop(job.open)
            if not id then return 'fail' end
        end
        if not job.closed[id] and px[id] then
            job.closed[id] = true
            if id == job.g then return rnPath(job, id) end
            job.exp, job.expS = job.exp + 1, job.expS + 1
            if job.exp > 15000 then
                job.alts = nil
                return rnExhausted(job)
            end
            local g0, x0, y0 = job.gs[id], px[id], py[id]
            local h0 = sqrt(dist2(x0, y0, gx, gy))
            if h0 < job.bestH then job.best, job.bestH = id, h0 end
            for _, nb in ipairs(adj[id] or {}) do
                local nx, ny = px[nb], py[nb]
                if nx and not job.closed[nb] then
                    local ng = g0 + sqrt(dist2(nx, ny, x0, y0)) * (pen[nb] and 5 or 1)
                    local og = job.gs[nb]
                    if not og or ng < og then
                        job.gs[nb], job.from[nb] = ng, id
                        hpush(job.open, ng + sqrt(dist2(nx, ny, gx, gy)), nb)
                    end
                end
            end
        end
    end
    return 'run'
end

-- kara dla wezlow kolo miejsca, w ktorym utknal pojazd (kolejna trasa je omija)
local function rnPenalize(x, y)
    local k0 = gridKey(x, y)
    for dx = -1, 1 do
        for dy = -1, 1 do
            local cell = RN.grid[k0 + dx * 256 + dy]
            if cell then
                for _, id in ipairs(cell) do
                    if dist2(RN.px[id], RN.py[id], x, y) < 15 * 15 then RN.pen[id] = true end
                end
            end
        end
    end
end

-- trasa po wezlach -> lamana od pozycji do celu: bez zawracania do wezla, ktory juz minelismy, i bez wezla za celem.
-- Trasa po drogach jest wygladzana (zakrety po luku, nie "pod katem") i przesunieta ok. 1 m w prawo od osi jezdni.
local LANE = 1.0
local function routePoints(r, sx, sy, sz, tx, ty, tz)
    local road = type(r) == 'table' and #r > 0
    local pts = road and r or {}
    while #pts >= 2 and dist2(sx, sy, pts[2].x, pts[2].y) < dist2(pts[1].x, pts[1].y, pts[2].x, pts[2].y) do
        table.remove(pts, 1)
    end
    while #pts >= 2 and dist2(tx, ty, pts[#pts - 1].x, pts[#pts - 1].y) < dist2(pts[#pts].x, pts[#pts].y, pts[#pts - 1].x, pts[#pts - 1].y) do
        pts[#pts] = nil
    end
    if road and #pts >= 3 then
        for _ = 1, 2 do                                            -- Chaikin x2
            local out = { pts[1] }
            for i = 1, #pts - 1 do
                local a, b = pts[i], pts[i + 1]
                if i > 1 then out[#out + 1] = { x = a.x * 0.75 + b.x * 0.25, y = a.y * 0.75 + b.y * 0.25, z = a.z * 0.75 + b.z * 0.25 } end
                if i < #pts - 1 then out[#out + 1] = { x = a.x * 0.25 + b.x * 0.75, y = a.y * 0.25 + b.y * 0.75, z = a.z * 0.25 + b.z * 0.75 } end
            end
            out[#out + 1] = pts[#pts]
            pts = out
        end
        local sh = {}
        for i = 1, #pts do                                         -- prawy pas
            local a, b = pts[max(1, i - 1)], pts[min(#pts, i + 1)]
            local dx, dy = b.x - a.x, b.y - a.y
            local l = sqrt(dx * dx + dy * dy)
            if l > 0.1 then
                sh[i] = { x = pts[i].x + dy / l * LANE, y = pts[i].y - dx / l * LANE, z = pts[i].z }
            else
                sh[i] = pts[i]
            end
        end
        pts = sh
    end
    table.insert(pts, 1, { x = sx, y = sy, z = sz })
    pts[#pts + 1] = { x = tx, y = ty, z = tz, final = true }
    return pts
end

-- ------------------------------------------------------------ sledzenie trasy (lamana)
local function pathAdvance(path, wi, x, y)
    while wi < #path do
        local a, b = path[wi], path[wi + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local l2 = dx * dx + dy * dy
        local t = l2 > 1e-6 and ((x - a.x) * dx + (y - a.y) * dy) / l2 or 1
        if t >= 1 or (not b.final and dist2(b.x, b.y, x, y) < 4) then wi = wi + 1 else break end
    end
    return wi
end

-- punkt na trasie L metrow za rzutem pozycji na biezacy odcinek
local function pathLook(path, wi, x, y, L)
    local a, b = path[wi], path[wi + 1]
    if not b then return a.x, a.y end
    local dx, dy = b.x - a.x, b.y - a.y
    local l2 = dx * dx + dy * dy
    local t = l2 > 1e-6 and max(0, min(1, ((x - a.x) * dx + (y - a.y) * dy) / l2)) or 1
    local sx, sy = a.x + dx * t, a.y + dy * t
    local rem, i = L, wi
    while true do
        local nb = path[i + 1]
        if not nb then return path[i].x, path[i].y end
        local sl = sqrt(dist2(nb.x, nb.y, sx, sy))
        if sl >= rem then
            local k = rem / max(sl, 1e-3)
            return sx + (nb.x - sx) * k, sy + (nb.y - sy) * k
        end
        rem = rem - sl
        sx, sy, i = nb.x, nb.y, i + 1
    end
end

local function pathLeft(path, wi, x, y)
    local p = path[wi + 1]
    if not p then return sqrt(dist2(path[wi].x, path[wi].y, x, y)) end
    local d, lx, ly = sqrt(dist2(p.x, p.y, x, y)), p.x, p.y
    for i = wi + 2, #path do
        d = d + sqrt(dist2(path[i].x, path[i].y, lx, ly))
        lx, ly = path[i].x, path[i].y
    end
    return d
end

-- predkosc, z jaka mozna jechac teraz, zeby lagodnie wyhamowac przed kazdym zakretem i przed celem.
-- Zakret = zmiana kierunku trasy na odcinku ~14 m (trasa jest wygladzona, wiec pojedyncze katy sa male).
local DEC = 4.5                                                    -- [m/s^2] spokojne hamowanie
local function speedPlan(path, wi, x, y, vmax, stopR)
    local S, H = {}, {}
    local s, lx, ly = 0, x, y
    for i = wi + 1, #path do
        local p = path[i]
        local seg = sqrt(dist2(p.x, p.y, lx, ly))
        if seg > 0.3 then
            S[#S + 1], H[#H + 1] = s, hdg(lx, ly, p.x, p.y)
        end
        s = s + seg
        lx, ly = p.x, p.y
        if s > 130 then break end
    end
    local lim, k = vmax, 1
    for j = 1, #S do
        while k < #S and S[k] - S[j] < 14 do k = k + 1 end
        if k <= j then break end
        local ang = math.abs(wrap180(H[k] - H[j]))
        if ang > 12 then
            local vc = max(7, vmax * (1 - (ang - 12) / 110))
            lim = min(lim, sqrt(vc * vc + 2 * DEC * S[j]))
        end
    end
    if s <= 130 then lim = min(lim, sqrt(2 * DEC * max(0, s - stopR)) + 1.5) end
    return lim
end

-- ------------------------------------------------------------ pieszo (galka pada wzgledem kamery + sprint)
local function padToward(px, py, x, y, ang, mag)
    local ch = camH()
    if not ch then return end
    local rel = math.rad(wrap180(hdg(px, py, x, y) + ang - ch))
    pad(0, floor(-math.sin(rel) * mag + 0.5))
    pad(1, floor(-math.cos(rel) * mag + 0.5))
end

-- galka w strone swiatowego kierunku 'want', obracana plynnie (bez szarpniec przy kazdym punkcie trasy)
local function padSmooth(S, want, mag, now)
    local dt = A.clamp(now - (S.angT or now), 0.001, 0.1)
    S.angT = now
    if not S.ang then S.ang = want end
    S.ang = (S.ang + A.clamp(wrap180(want - S.ang), -540 * dt, 540 * dt)) % 360
    S.mag = (S.mag or mag) + A.clamp(mag - (S.mag or mag), -400 * dt, 400 * dt)
    local ch = camH()
    if not ch then return end
    local rel = math.rad(wrap180(S.ang - ch))
    pad(0, floor(-math.sin(rel) * S.mag + 0.5))
    pad(1, floor(-math.cos(rel) * S.mag + 0.5))
end

-- wysokosc celu dla A* po kolizji: przyblizone miejsce (daleko od graffiti) nie zna ziemi - bierzemy wysokosc postaci
local function navTz(d, pz) return d.rough and pz or d.z end

-- dalej niz 45 m: trasa po drogach (albo prosto), ostatnie ~30 m: A* po kolizji (limit pracy na klatke)
local function footStart(now, px, py, pz)
    local d = MV.dest
    local F = { stucks = 0, lookAt = 0, path = nil, wi = 1, ang = MV.ft and MV.ft.ang }
    MV.ft = F
    if d.path and #d.path >= 2 then                                -- nauczony slad: od najblizszego punktu do celu
        local k, kd
        for i, p in ipairs(d.path) do
            local dd = dist2(p[1], p[2], px, py)
            if not kd or dd < kd then k, kd = i, dd end
        end
        if kd and kd < 25 * 25 then
            local path = { { x = px, y = py, z = pz } }
            for i = k, #d.path do path[#path + 1] = { x = d.path[i][1], y = d.path[i][2], z = d.path[i][3] } end
            path[#path + 1] = { x = d.x, y = d.y, z = d.z, final = true }
            F.path, F.wi, F.local_, F.fixed = path, 1, true, true
            space(false)
            return
        end
    end
    if dist2(d.x, d.y, px, py) > 45 * 45 then
        F.waitRN = true                                            -- trasa po drogach (footStep)
    else
        space(false)
        F.nav, F.local_ = NF.start(px, py, pz, d.x, d.y, navTz(d, pz), d.goalR or 0.8, false, now), true
    end
end

local function footStep(now, px, py, pz)
    local F, d = MV.ft, MV.dest
    local dt2 = dist2(d.x, d.y, px, py)
    if dt2 < d.reach * d.reach then space(false); return 'arrived' end
    if F.waitRN then
        local ok = rnUpdate()
        if ok == 'busy' then GB.why = 'mapa drog'; return 'run' end
        F.waitRN = false
        F.job = ok and rnPlan(px, py, pz, d.x, d.y, d.z) or nil
        if not F.job then F.path, F.wi = routePoints(nil, px, py, pz, d.x, d.y, d.z), 1 end
        return 'run'
    end
    if F.job then                                                  -- trasa po drogach
        local r = rnRun(F.job)
        if r == 'run' then GB.why = 'trasa'; return 'run' end
        F.job = nil
        F.path, F.wi = routePoints(r, px, py, pz, d.x, d.y, d.z), 1
    end
    if F.nav then                                                  -- ostatnie metry: A* po kolizji
        local r = NF.run(F.nav, now)
        if r == 'run' then GB.why = 'trasa'; return 'run' end
        local nav = F.nav
        F.nav = nil
        if r == 'fail' then
            gbLog(('pieszo: brak trasy po kolizji (%d wezlow) - ide prosto'):format(nav.exp))
            r = {}
        end
        table.insert(r, 1, { x = px, y = py, z = pz })
        r[#r + 1] = { x = d.x, y = d.y, z = d.z, final = true }
        F.path, F.wi = r, 1
    end
    if not F.local_ and dt2 < 30 * 30 then                         -- blisko: dokladna trasa po kolizji
        F.local_ = true
        F.nav = NF.start(px, py, pz, d.x, d.y, navTz(d, pz), d.goalR or 0.8, false, now)
        return 'run'
    end
    if F.side then                                                 -- krok w bok po zablokowaniu
        if now < F.side.untilT then
            padToward(px, py, F.side.wx, F.side.wy, 90 * F.side.dir, 110)
            GB.why = 'omijam'
            return 'run'
        end
        F.side, F.ang = nil, nil
        if F.fixed then return 'run' end                           -- nauczony slad: wracamy na niego
        F.local_, F.path = dt2 < 30 * 30, nil
        if F.local_ then F.nav = NF.start(px, py, pz, d.x, d.y, navTz(d, pz), d.goalR or 0.8, false, now) else F.waitRN = true end
        return 'run'
    end
    local path = F.path
    if not path then return 'run' end
    F.wi = pathAdvance(path, F.wi, px, py)
    if F.local_ and now >= F.lookAt and F.wi < #path - 1 then      -- skroty po prostej
        F.lookAt = now + 0.4
        local gz = NF.feet(px, py, pz)
        for k = min(#path - 1, F.wi + 5), F.wi + 2, -3 do
            if NF.corridor(px, py, gz, path[k].x, path[k].y, now) then F.wi = k; break end
        end
    end
    local df = sqrt(dt2)
    local lx, ly = pathLook(path, F.wi, px, py, F.local_ and 1.5 or 3.5)
    if df < 2.0 then lx, ly = d.x, d.y end
    padSmooth(F, hdg(px, py, lx, ly), df < 1.5 and 70 or 128, now)
    -- sprint z histereza (bez klepania spacji): wlacza sie powyzej 6 m, wylacza ponizej 3 m
    if F.sprint then F.sprint = df > 3 else F.sprint = df > 6 end
    if F.sprint then pad(16, 255) end
    space(F.sprint)
    GB.why = ('pieszo %.0f m'):format(df)
    if not F.lp then
        F.lp, F.lpAt = { px, py }, now
    elseif now - F.lpAt >= 1.2 then
        local moved = dist2(px, py, F.lp[1], F.lp[2])
        F.lp, F.lpAt = { px, py }, now
        if moved < 0.64 then
            F.stucks = F.stucks + 1
            if dt2 < (d.reach + 1.0) ^ 2 then space(false); return 'arrived' end
            if F.stucks >= 4 then space(false); return 'fail' end
            local dx, dy = lx - px, ly - py
            local l = sqrt(dx * dx + dy * dy)
            if l > 0.1 then
                NF.p.blocks[#NF.p.blocks + 1] = { x = px + dx / l * 0.9, y = py + dy / l * 0.9, r = 0.7, untilT = now + 45 }
            end
            if F.stucks % 2 == 1 then GB.jumpUntil = now + 0.12 end    -- skok co drugi raz, nie za kazdym
            space(false)
            F.side = { untilT = now + 0.6, dir = (F.stucks % 2 == 1) and 1 or -1, wx = lx, wy = ly }
            gbLog(('pieszo: zablokowany (%d) - krok w bok, nowa trasa'):format(F.stucks))
        end
    end
    return 'run'
end

-- ------------------------------------------------------------ pojazd
-- Przeszkoda przed pojazdem (promien pod katem ang): odleglosc do czegos TWARDEGO - budynek, pojazd, wysoki obiekt
-- (sciana z obiektow, latarnia). Niskie obiekty (plotki, barierki, kosze) zwracaja nil: przy predkosci sie je rozjezdza.
local function feeler(cx, cy, cz, h, ang, len)
    local hr, r = math.rad(h), math.rad(h + ang)
    local sx, sy = cx - math.sin(hr) * 1.2, cy + math.cos(hr) * 1.2
    local ex, ey = sx - math.sin(r) * len, sy + math.cos(r) * len
    local best
    local ok, hit, cp = pcall(processLineOfSight, sx, sy, cz + 0.3, ex, ey, cz + 0.3, true, true, false, false, false, false, false, false)
    if ok and hit and cp and cp.normal[3] < 0.6 then best = sqrt(dist2(cp.pos[1], cp.pos[2], sx, sy)) end
    local ok2, hit2, cp2 = pcall(processLineOfSight, sx, sy, cz + 0.3, ex, ey, cz + 0.3, false, false, false, true, false, false, false, false)
    if ok2 and hit2 and cp2 and cp2.normal[3] < 0.6 then
        local d2 = sqrt(dist2(cp2.pos[1], cp2.pos[2], sx, sy))
        if not best or d2 < best then
            local ok3, hit3, cp3 = pcall(processLineOfSight, sx, sy, cz + 2.0, ex, ey, cz + 2.0, false, false, false, true, false, false, false, false)
            if ok3 and hit3 and cp3 and math.abs(sqrt(dist2(cp3.pos[1], cp3.pos[2], sx, sy)) - d2) < 1.5 then best = d2 end
        end
    end
    return best
end

local function driveStart(now)
    MV.drv = { stucks = 0, stalls = 0, wAt = 0, wLen = 6, path = nil, job = nil, wi = 1, replans = 0,
        steer = 0, thr = 0, brk = 0, avoid = 0, lastT = now, vmax = cfg.botSpeed * (0.92 + math.random() * 0.08) }
end

-- gaz / hamulec analogowo, plynnie (bez przelaczania pelny gaz <-> pelny hamulec co klatke)
local function pedals(D, vt, spd, dt)
    local e = vt - spd
    local thr, brk = 0, 0
    if e > 0.4 then
        thr = min(255, 90 + e * 28)
    elseif e > -1.5 and vt > 2.5 then
        thr = max(0, 50 + e * 30)                                  -- utrzymanie predkosci
    elseif spd > 1 and e < -0.8 then
        brk = min(230, 50 + (-e - 0.8) * 45)
    end
    D.thr = D.thr + (thr - D.thr) * min(1, dt * 6)
    D.brk = D.brk + (brk - D.brk) * min(1, dt * 9)
    if D.thr >= 8 then pad(16, floor(D.thr + 0.5)) end
    if D.brk >= 8 and spd > 0.8 then pad(14, floor(D.brk + 0.5)) end
    if D.thr > 160 and spd < 9 then pad(1, -45) end              -- lekko do przodu: bez wheelie przy ruszaniu
end

-- kierownica: cel z pure pursuit, ograniczona predkosc obrotu i mniejszy skret przy duzej predkosci
local function steerTo(D, want, spd, dt)
    local maxS = spd < 8 and 128 or max(55, 128 - (spd - 8) * 3)
    want = A.clamp(want, -maxS, maxS)
    D.steer = D.steer + A.clamp(want - D.steer, -520 * dt, 520 * dt)
    pad(0, floor(D.steer + 0.5))
end

-- jazda do MV.vt = { x, y, z, r }: trasa po drogach (jesli daleko) + pure pursuit + plan predkosci + czujniki przeszkod
local function driveStep(now, car)
    local D, tgt = MV.drv, MV.vt
    local dt = A.clamp(now - D.lastT, 0.001, 0.1)
    D.lastT = now
    local cx, cy, cz = getCarCoordinates(car)
    local spd = getCarSpeed(car) or 0
    local h = getCarHeading(car)
    local dfin = sqrt(dist2(tgt.x, tgt.y, cx, cy))
    if dfin < tgt.r then                                           -- na miejscu: dohamuj do zera (bez dodawania gazu)
        steerTo(D, 0, spd, dt)
        D.thr = 0
        if spd > 1.2 then
            D.brk = D.brk + (min(230, 90 + spd * 22) - D.brk) * min(1, dt * 9)
            pad(14, floor(D.brk + 0.5))
            GB.why = 'hamuje'
            return 'run'
        end
        return 'arrived'
    end
    local okU, up = pcall(isCarUpsidedown, car)
    if okU and up and spd < 1 then return 'flip' end
    if tgt.exact and dfin < 6 then                                 -- strefa: krazy wokol punktu - reszta pieszo
        D.nearAt = D.nearAt or now
        if now - D.nearAt > 8 then return 'fail' end
    end
    if not D.path then
        if D.job == nil then
            if dfin > 40 then
                local ok = rnUpdate()
                if ok == 'busy' then pedals(D, 0, spd, dt); GB.why = 'mapa drog'; return 'run' end
                D.job = ok and rnPlan(cx, cy, cz, tgt.x, tgt.y, tgt.z) or false
            else
                D.job = false
            end
        end
        local r = nil
        if D.job then
            pedals(D, min(spd, 6), spd, dt)                        -- liczenie trasy trwa 1-3 klatki: bez gwaltownego hamowania
            r = rnRun(D.job)
            if r == 'run' then GB.why = 'trasa'; return 'run' end
            D.partial = D.job.partial
            gbLog(('jazda: trasa po drogach %d pkt%s (%d wezlow)'):format(type(r) == 'table' and #r or 0,
                D.partial and ', czesciowa' or '', D.job.exp))
        else
            D.partial = false
        end
        D.job, D.planAt = nil, now
        D.path, D.wi, D.lp = routePoints(r, cx, cy, cz, tgt.x, tgt.y, tgt.z), 1, nil
        D.bestLeft, D.bestAt = nil, now
    end
    if D.rev then                                                  -- cofanie po zablokowaniu (plynnie)
        if now < D.rev.untilT then
            steerTo(D, D.rev.steer, 0, dt)
            D.thr = 0
            pad(14, 200)
            GB.why = 'cofam'
            return 'run'
        end
        D.rev, D.lp = nil, nil
    end
    local path = D.path
    D.wi = pathAdvance(path, D.wi, cx, cy)
    -- trasa czesciowa (cel w niewczytanym obszarze): nowa trasa, gdy zostalo malo drogi po wezlach
    if D.partial and D.replans < 8 and dfin > 60 and now - (D.planAt or 0) > 5 and #path >= 3
        and dist2(path[#path - 1].x, path[#path - 1].y, cx, cy) < 40 * 40 then
        D.replans, D.path, D.job = D.replans + 1, nil, nil
        return 'run'
    end
    local left = pathLeft(path, D.wi, cx, cy)
    -- postep liczony po trasie (nie w linii prostej - trasa moze chwilowo prowadzic od celu)
    if not D.bestLeft or left < D.bestLeft - 5 then
        D.bestLeft, D.bestAt = left, now
    elseif now - D.bestAt > 20 then
        D.stalls = D.stalls + 1
        gbLog(('jazda: brak postepu od 20 s (%d) - nowa trasa'):format(D.stalls))
        if D.stalls >= 3 then return 'fail' end
        if RN.nodes > 0 then rnPenalize(cx, cy) end
        D.path, D.job = nil, nil
        return 'run'
    end
    local L = A.clamp(4 + spd * 0.6, 5, 20)
    local lx, ly = pathLook(path, D.wi, cx, cy, L)
    local err = wrap180(hdg(cx, cy, lx, ly) - h)
    if now >= D.wAt then
        D.wAt = now + 0.1
        D.wLen = 6 + spd * 0.7
        D.wC = feeler(cx, cy, cz, h, 0, D.wLen)
        D.wL = feeler(cx, cy, cz, h, 22, D.wLen * 0.75)
        D.wR = feeler(cx, cy, cz, h, -22, D.wLen * 0.75)
    end
    local avoid = 0                                                -- odpychanie od scian (wygladzone)
    if D.wL then avoid = avoid + 80 * (1 - D.wL / (D.wLen * 0.75)) end
    if D.wR then avoid = avoid - 80 * (1 - D.wR / (D.wLen * 0.75)) end
    if D.wC and not D.wL and not D.wR then avoid = avoid + (err > 0 and -55 or 55) * (1 - D.wC / D.wLen) end
    D.avoid = D.avoid + (avoid - D.avoid) * min(1, dt * 8)
    local k = spd < 6 and 3.4 or (spd < 15 and 2.5 or 1.7)
    steerTo(D, -err * k + D.avoid, spd, dt)
    local vt = speedPlan(path, D.wi, cx, cy, D.vmax, tgt.r)
    local ae = math.abs(err)
    if ae > 35 then vt = min(vt, max(5, 14 - (ae - 35) * 0.15)) end    -- duzy blad kierunku: wolniej, az sie ustawi
    if D.wC then vt = min(vt, max(3, D.wC * 0.65)) end
    pedals(D, vt, spd, dt)
    GB.why = ('jade %.0f m'):format(left)
    if not D.lp then
        D.lp, D.lpAt = { cx, cy }, now
    elseif now - D.lpAt >= 1.5 then
        local moved = dist2(cx, cy, D.lp[1], D.lp[2])
        D.lp, D.lpAt = { cx, cy }, now
        if moved < 1.0 then
            D.stucks = D.stucks + 1
            if dfin < tgt.r + 8 and not tgt.exact then return 'arrived' end
            if D.stucks >= 8 then return 'fail' end
            D.rev = { untilT = now + 1.2, steer = (err > 0) and 110 or -110 }
            D.steer, D.thr = 0, 0
            if D.stucks % 2 == 0 and RN.nodes > 0 then             -- co drugi raz: omijamy to miejsce nowa trasa
                rnPenalize(cx, cy)
                D.path, D.job = nil, nil
            end
            gbLog(('jazda: zablokowany (%d) - cofam%s'):format(D.stucks, D.path and '' or ' i licze nowa trase'))
        end
    end
    return 'run'
end

-- ------------------------------------------------------------ dojazd (MV): wybor srodka i caly przejazd do celu
-- dest = { key (cel), x, y, z, reach (pieszo), goalR, park (pojazd staje tyle od celu), keepVeh (strefy: nie zsiadaj) }
-- Zasady: motor tylko gdy cel dalej niz BIKE_MIN; /nrg najwyzej raz na 25 s; po zsiadnieciu dla danego celu
-- nie wsiada ponownie (MV.noBike) - nie ma petli wsiadz/zsiadz.
local function mvWalk(now, px, py, pz)
    MV.state = 'walk'
    footStart(now, px, py, pz)
end

local function mvDrive(now, car)
    local d = MV.dest
    GB.bike = car
    MV.state = 'drive'
    MV.vt = { x = d.x, y = d.y, z = d.z, r = d.keepVeh and (d.park or 1.3) or (d.park or PARK_R), exact = d.keepVeh }
    if d.parkAt and not d.keepVeh then MV.vt = { x = d.parkAt.x, y = d.parkAt.y, z = d.parkAt.z, r = 3 } end
    driveStart(now)
end

local function mvExit(now)
    MV.state, MV.exitAt, MV.exitN = 'exit', now, 0
    if MV.dest and MV.dest.key then MV.noBike[MV.dest.key] = true end
end

-- "nie wsiadaj ponownie" dziala tylko blisko celu: daleko (wywrotka, upadek) bot wraca na motor zamiast biec 300 m
local NOBIKE_R = 80
local function bikeBanned(key, dd) return key ~= nil and MV.noBike[key] and dd < NOBIKE_R end

local function mvGo(dest, now, px, py, pz)
    if MV.dest ~= dest then MV.remounts = 0 end
    MV.dest, MV.ft, MV.drv = dest, nil, nil
    local dd = sqrt(dist2(dest.x, dest.y, px, py))
    local car = myCar()
    if car then
        if dest.keepVeh or (dd > (dest.park or PARK_R) + 3 and not bikeBanned(dest.key, dd)) then return mvDrive(now, car) end
        return mvExit(now)
    end
    local want = cfg.botMode == 'bike' and not bikeBanned(dest.key, dd) and (MV.remounts or 0) <= 2
        and (dd > BIKE_MIN or (dest.keepVeh and dd > 25))
    if want then
        local b = (GB.bike and vehOk(GB.bike)) and GB.bike or nil
        if b then
            local bx, by = getCarCoordinates(b)
            if dist2(bx, by, px, py) > 40 * 40 then b = nil end
        end
        b = b or findBike(px, py, 30)
        if b then
            GB.bike = b
            local bx, by, bz = getCarCoordinates(b)
            MV.state, MV.bdest = 'tobike', dest
            MV.dest = { key = dest.key, x = bx, y = by, z = bz, reach = 2.2, goalR = 2.6 }
            footStart(now, px, py, pz)
            return
        end
        if now >= MV.nrgNext then
            MV.state, MV.cmdAt, MV.cmdN = 'getbike', -1e9, 0
            return
        end
    end
    mvWalk(now, px, py, pz)
end

-- 'run' | 'arrived' | 'fail'
local function mvStep(now, px, py, pz)
    local st = MV.state
    if st == 'walk' then return footStep(now, px, py, pz) end

    if st == 'getbike' then                                        -- /nrg, potem motor obok albo od razu na nim
        if myCar() then
            MV.nrgFails = 0
            mvGo(MV.dest, now, px, py, pz)
            return 'run'
        end
        if MV.cmdN > 0 and now - MV.cmdAt > 0.8 then
            local b = findBike(px, py, 15)
            if b then
                MV.nrgFails, GB.bike = 0, b
                mvGo(MV.dest, now, px, py, pz)
                return 'run'
            end
        end
        if now - MV.cmdAt > 3 then
            if MV.cmdN >= 2 then                                   -- dwa razy bez motoru: pieszo, /nrg dopiero za 60 s
                MV.nrgNext = now + 60
                MV.nrgFails = MV.nrgFails + 1
                gbLog('/nrg nie daje motoru - ide pieszo')
                mvWalk(now, px, py, pz)
                return 'run'
            end
            MV.cmdN, MV.cmdAt = MV.cmdN + 1, now
            MV.nrgNext = now + 25
            sendCmd('/nrg')
        end
        GB.why = '/nrg'
        return 'run'
    end

    if st == 'tobike' then
        local r = footStep(now, px, py, pz)
        if r == 'arrived' then
            MV.state, MV.enterAt, MV.enterN = 'enter', now, 0
        elseif r == 'fail' or not vehOk(GB.bike) then
            gbLog('nie moge dojsc do motoru - ide pieszo')
            GB.bike = nil
            MV.dest = MV.bdest
            if MV.dest.key then MV.noBike[MV.dest.key] = true end
            mvWalk(now, px, py, pz)
        end
        return 'run'
    end

    if st == 'enter' then
        local car = myCar()
        if car then
            MV.dest = MV.bdest
            mvDrive(now, car)
            return 'run'
        end
        GB.why = 'wsiadam'
        local t = now - MV.enterAt
        if t < 0.15 then
            pad(15, 255)                                           -- TRIANGLE = wsiadanie
        elseif t > 4 then
            MV.enterN = MV.enterN + 1
            if MV.enterN >= 2 or not vehOk(GB.bike) then
                gbLog('nie moge wsiasc na motor - ide pieszo')
                GB.bike = nil
                MV.dest = MV.bdest
                if MV.dest.key then MV.noBike[MV.dest.key] = true end
                mvWalk(now, px, py, pz)
                return 'run'
            end
            MV.enterAt = now
        end
        return 'run'
    end

    if st == 'drive' then
        local car = myCar()
        local far = dist2(MV.dest.x, MV.dest.y, px, py) > NOBIKE_R * NOBIKE_R
        if not car then                                            -- spadl z pojazdu: daleko - z powrotem na motor
            MV.remounts = (MV.remounts or 0) + 1
            gbLog('spadlem z pojazdu' .. (far and ' - wsiadam ponownie' or ' - reszta pieszo'))
            if far then mvGo(MV.dest, now, px, py, pz); return 'run' end
            if MV.dest.key then MV.noBike[MV.dest.key] = true end
            mvWalk(now, px, py, pz)
            return 'run'
        end
        local r = driveStep(now, car)
        if r == 'run' then return 'run' end
        if r == 'fail' and far and not MV.dest.keepVeh then        -- daleko od celu: nie zsiadamy, cel do pominiecia
            gbLog('jazda: nie moge dojechac - zostaje na motorze')
            return 'fail'
        end
        if r == 'flip' then MV.remounts = (MV.remounts or 0) + 1 end
        if MV.dest.keepVeh then
            if r == 'arrived' then return 'arrived' end
            if r == 'flip' then mvExit(now); return 'run' end
            local cx, cy = getCarCoordinates(car)
            if dist2(cx, cy, MV.dest.x, MV.dest.y) < 25 * 25 then  -- nie dojedzie do samego punktu: reszta pieszo
                gbLog('pojazd nie dojedzie do punktu - zsiadam, reszta pieszo')
                mvExit(now)
                return 'run'
            end
            return 'fail'
        end
        if r ~= 'arrived' then gbLog('jazda: ' .. r .. ' - zsiadam, reszta pieszo') end
        mvExit(now)
        return 'run'
    end

    if st == 'exit' then
        if not isCharInAnyCar(PLAYER_PED) then
            if dist2(MV.dest.x, MV.dest.y, px, py) > NOBIKE_R * NOBIKE_R and (MV.remounts or 0) <= 2 then
                mvGo(MV.dest, now, px, py, pz)                     -- wywrotka daleko: podnies motor i jedz dalej
            else
                mvWalk(now, px, py, pz)
            end
            return 'run'
        end
        GB.why = 'zsiadam'
        local car = myCar()
        if car and (getCarSpeed(car) or 0) > 1 then pad(14, 255); MV.exitAt = now; return 'run' end
        local t = now - MV.exitAt
        if t < 0.15 then
            pad(15, 255)
        elseif t > 2.5 then
            MV.exitN = MV.exitN + 1
            if MV.exitN >= 4 then return 'fail' end
            MV.exitAt = now
        end
        return 'run'
    end
    return 'fail'
end

-- pojazd stoi w miejscu (strefa): hamulec przy ruchu, reczny na postoju
local function mvHold()
    local car = myCar()
    if not car then return end
    if (getCarSpeed(car) or 0) > 1 then pad(14, 180) else pad(6, 255) end
end

-- ------------------------------------------------------------ STREFY: checkpoint -> Y -> 60 s -> nastepna
local function zmod()
    local sz = A.mods.strefy
    if sz and sz.ready and A.isOn('strefy') and sz.zones then return sz end
    return nil
end

-- komunikat o strefach po 'since' (z modulu Strefy): kinds = { start = true, ... }; id = nil -> dowolna strefa
local function zEvent(since, kinds, id)
    local sz = zmod()
    if not sz then return nil end
    local evs = sz.events()
    for i = #evs, 1, -1 do
        local e = evs[i]
        if e.t < since then break end
        if kinds[e.kind] and (e.id == nil or id == nil or e.id == id) then return e end
    end
    return nil
end

local function zoneEligible(sz, id, now)
    local st = sz.zone(id)
    if st and st.mine then return false end
    local sk = ZB.skip[id]
    if sk and sk > now then return false end
    local r = sz.zoneReady(id)
    if cfg.zoneReadyOnly then
        if sz.snap.ok then return r == true end
        return r ~= false
    end
    return true
end

-- pojazdem na sam checkpoint; gdy pojazd 2 razy nie trafi w punkt - reszta pieszo (ZB.foot)
local function zoneDest(z)
    if ZB.foot then
        MV.noBike['z' .. z.id] = true
        return { key = 'z' .. z.id, x = z.x, y = z.y, z = z.z, reach = 0.8, goalR = 1.0, park = 1.0 }
    end
    return { key = 'z' .. z.id, x = z.x, y = z.y, z = z.z, reach = 1.0, goalR = 1.2, park = 1.3, keepVeh = true }
end

local function zoneBack(now, px, py, pz, z, state)
    ZB.backN = (ZB.backN or 0) + 1
    if ZB.backN >= 3 and not ZB.foot then
        ZB.foot = true
        gbLog(('strefa %s (%d): pojazdem nie trafiam w punkt - reszta pieszo'):format(z.name, z.id))
    end
    if ZB.backN >= 6 then
        ZB.skip[z.id] = now + 180
        gbLog(('strefa %s (%d): nie moge utrzymac sie na punkcie - pomijam na 3 min'):format(z.name, z.id))
        GB.state = 'pick'
        return
    end
    mvGo(zoneDest(z), now, px, py, pz)
    GB.state = state
end

local function zjPick(now, px, py, pz)
    releaseAll()
    mvHold()
    local sz = zmod()
    if not sz then return gbStop('Strefy Bot: wlacz modul Strefy.') end
    if (not ZB.refreshed or (os.time() - sz.snap.at > 180 and now - (ZB.refreshAt or -1e9) > 120)) then
        ZB.refreshed, ZB.refreshAt = true, now
        sz.refresh()
        GB.state = 'zrefresh'
        return
    end
    if now < (ZB.waitUntil or 0) then return end
    local list = sz.zones()
    local best, bd, total, mine = nil, nil, 0, 0
    for id, z in pairs(list) do
        total = total + 1
        local st = sz.zone(id)
        if st and st.mine then mine = mine + 1 end
        if zoneEligible(sz, id, now) and (z.int or 0) == 0 then
            local d = dist2(z.x, z.y, px, py)
            if not bd or d < bd then best, bd = z, d end
        end
    end
    ZB.total, ZB.mine = total, mine
    if total > 0 and mine == total then return gbStop(('Strefy Bot: wszystkie strefy sa nasze (%d).'):format(total)) end
    if not best then
        GB.why = cfg.zoneReadyOnly and 'brak gotowych stref - czekam' or 'brak stref do przejecia - czekam'
        ZB.waitUntil = now + 5
        return
    end
    ZB.zone, ZB.pressN, ZB.pressAt, ZB.t0, ZB.nudge, ZB.backN, ZB.foot = best, 0, nil, nil, 0, 0, false
    gbLog(('strefa %s (%d), %.0f m'):format(best.name, best.id, sqrt(bd)))
    mvGo(zoneDest(best), now, px, py, pz)
    GB.state = 'zgo'
end

local function zjStep(now, px, py, pz)
    local st, z = GB.state, ZB.zone
    if st == 'zrefresh' then
        local sz = zmod()
        GB.why = 'odswiezam /strefy'
        mvHold()
        if not sz or not sz.browsing() or now - ZB.refreshAt > 20 then GB.state = 'pick' end
        return
    end
    if st == 'pick' then return zjPick(now, px, py, pz) end
    local sz = zmod()
    if not sz then return gbStop('Strefy Bot: wlacz modul Strefy.') end
    local d2 = dist2(z.x, z.y, px, py)

    if st == 'zgo' or st == 'zback' then
        local zs = sz.zone(z.id)
        if st == 'zgo' and zs and zs.mine then GB.state = 'pick'; return end
        -- checkpoint strefy juz pod nami (serwer napisal "Wcisnij Y"): dalej nie jedziemy
        if d2 < 4 * 4 and zEvent(now - 1.5, { prompt = true }) then
            mvHold()
            if st == 'zback' then GB.state = 'zhold' else GB.state, ZB.pressN, ZB.pressAt, ZB.arriveAt = 'zpress', 0, nil, now end
            return
        end
        local r = mvStep(now, px, py, pz)
        if r == 'run' then return end
        if r == 'fail' then
            ZB.skip[z.id] = now + 180
            gbLog(('strefa %s (%d): nie moge dojechac - pomijam na 3 min'):format(z.name, z.id))
            GB.state = 'pick'
            return
        end
        if st == 'zback' then GB.state = 'zhold'; return end
        GB.state, ZB.pressN, ZB.pressAt, ZB.arriveAt = 'zpress', 0, nil, now
        return
    end

    if st == 'zpress' then
        mvHold()
        if d2 > 3 * 3 then                                         -- nie na checkpoincie: wroc
            return zoneBack(now, px, py, pz, z, 'zgo')
        end
        local since = (ZB.pressAt or ZB.arriveAt) - 0.3
        local e = zEvent(since, { start = true }, z.id)
        if e then
            ZB.t0, GB.state = e.t, 'zhold'
            gbLog(('strefa %s (%d): przejecie ruszylo'):format(z.name, z.id))
            return
        end
        if ZB.pressAt then
            e = zEvent(since, { hours = true }, nil)
            if e then return gbStop('Strefy Bot: przejmowanie stref jest dozwolone tylko od 8 rano do polnocy.') end
            e = zEvent(since, { locked = true, taken = true, war = true, own = true, win = true }, z.id)
            if e then
                if e.kind == 'locked' then
                    sz.lock(z.id, 600)
                    gbLog(('strefa %s (%d): teraz nie mozna atakowac - wroce za 10 min'):format(z.name, z.id))
                elseif e.kind == 'taken' then
                    ZB.skip[z.id] = now + 120
                    gbLog(('strefa %s (%d): juz ktos przejmuje - pomijam na 2 min'):format(z.name, z.id))
                elseif e.kind == 'war' then
                    ZB.waitUntil = now + 20
                    gbLog('gang walczy juz o inna strefe - czekam 20 s')
                else
                    sz.setMine(z.id)
                    gbLog(('strefa %s (%d) juz nasza'):format(z.name, z.id))
                end
                GB.state = 'pick'
                return
            end
        end
        if ZB.pressAt and now - ZB.pressAt < 3 then GB.why = ('strefa %s: Y'):format(z.name); return end
        if not ZB.pressAt and now - ZB.arriveAt < 0.6 then GB.why = 'staje'; return end
        -- serwer nie napisal "Wcisnij Y" (checkpoint jeszcze nie pod nami): podjedz dokladniej, max 2 razy
        if not ZB.pressAt and d2 > 1.0 and (ZB.nudge or 0) < 2 and not zEvent(ZB.arriveAt - 4, { prompt = true }) then
            ZB.nudge = (ZB.nudge or 0) + 1
            local dd = zoneDest(z)
            dd.park, dd.reach = 0.7, 0.6
            mvGo(dd, now, px, py, pz)
            GB.state = 'zgo'
            gbLog(('strefa %s (%d): podjezdzam blizej punktu'):format(z.name, z.id))
            return
        end
        if ZB.pressN >= 3 then
            if myCar() and not ZB.foot then                        -- Y z pojazdu nic nie daje: sprobuj pieszo
                ZB.foot, ZB.pressN, ZB.pressAt = true, 0, nil
                gbLog(('strefa %s (%d): Y z pojazdu nie startuje - probuje pieszo'):format(z.name, z.id))
                mvGo(zoneDest(z), now, px, py, pz)
                GB.state = 'zgo'
                return
            end
            ZB.skip[z.id] = now + 300
            gbLog(('strefa %s (%d): Y nie startuje przejecia - pomijam na 5 min'):format(z.name, z.id))
            GB.state = 'pick'
            return
        end
        ZB.pressN, ZB.pressAt = ZB.pressN + 1, now
        GB.yUntil = now + 0.15
        gbLog(('strefa %s (%d): Y (%d)'):format(z.name, z.id, ZB.pressN))
        return
    end

    if st == 'zhold' then
        local el = now - ZB.t0
        local e = zEvent(ZB.t0 - 0.5, { win = true }, z.id)
        local zs = sz.zone(z.id)
        if e or (zs and zs.mine and el > 5) then
            ZB.done = ZB.done + 1
            sz.setMine(z.id)
            gbLog(('strefa %s (%d) przejeta (%d w tej sesji)'):format(z.name, z.id, ZB.done))
            A.say('Strefy', ('Przejeta: %s (%d)'):format(z.name, z.id), '33FF66')
            GB.state = 'pick'
            return
        end
        e = zEvent(ZB.t0 + 0.5, { fail = true, lost = true }, z.id)
        if e then
            ZB.skip[z.id] = now + 120
            gbLog(('strefa %s (%d): przejecie nieudane - wroce za 2 min'):format(z.name, z.id))
            GB.state = 'pick'
            return
        end
        if el > ZONE_TIME + 20 then
            ZB.skip[z.id] = now + 120
            ZB.refreshed = false                                    -- sprawdz w /strefy, czyja jest
            gbLog(('strefa %s (%d): brak komunikatu o przejeciu po %d s'):format(z.name, z.id, floor(el)))
            GB.state = 'pick'
            return
        end
        if d2 > 2.5 * 2.5 then                                     -- trzymaj sie checkpointu
            return zoneBack(now, px, py, pz, z, 'zback')
        end
        mvHold()
        GB.why = ('strefa %s: przejecie %d s'):format(z.name, math.max(0, math.ceil(ZONE_TIME - el)))
    end
end

-- ------------------------------------------------------------ wspolne
gbStop = function(msg)
    releaseAll()
    GB.on, GB.state = false, 'off'
    MV.state, MV.dest, MV.ft, MV.drv = nil, nil, nil, nil
    A.zoneBotBusy, A.zoneBotOn = false, false
    if msg then A.say('Gang', msg, '7FD07F') end
end

local MODE_NAME = { bike = 'motor', foot = 'pieszo' }

local function gbStart()
    if not zmod() then
        return A.say('Gang', 'Strefy Bot: wlacz modul Strefy.', 'FF6666')
    end
    GB.on, GB.state, GB.why = true, 'pick', ''
    MV.noBike, MV.state, MV.ft, MV.drv = {}, nil, nil, nil
    MV.nrgNext = 0
    ZB.skip, ZB.refreshed, ZB.waitUntil = {}, false, 0
    GB.bike = myCar()
    pcall(rnUpdate)
    gbLog('Strefy Bot start, ' .. MODE_NAME[cfg.botMode] .. (RN.off and ', trasy po drogach' or ''))
    A.say('Gang', 'Strefy Bot wlaczony (' .. MODE_NAME[cfg.botMode] .. ').', '7FD07F')
end

local function gbStep(now)
    if ZB.toggle then
        ZB.toggle = false
        if GB.on then return gbStop('Strefy Bot wylaczony.') end
        if not isPlayerPlaying(PLAYER_HANDLE) then return end
        gbStart()
    end
    A.zoneBotOn, A.zoneBotBusy = GB.on, GB.on                     -- auto /graffiti czeka, az bot skonczy
    if not GB.on then return end
    if A.menuOpen or A.pauseActive() or A.chatInputActive() or A.dialogActive() or not A.gameFocused() then
        releaseAll()
        GB.why = 'pauza'
        return
    end
    if not isPlayerPlaying(PLAYER_HANDLE) then return end
    keyY(now < GB.yUntil)
    if isCharDead(PLAYER_PED) then
        releaseAll()
        GB.state, GB.why = 'pick', 'smierc'
        MV.state, MV.ft, MV.drv = nil, nil, nil
        return
    end
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    if now < (GB.jumpUntil or 0) then pad(14, 255) end             -- skok pieszo
    if GB.bike and not vehOk(GB.bike) then GB.bike = nil end
    return zjStep(now, px, py, pz)
end

local gbFont
local function gbHud()
    if not cfg.botHud or not A.drawOk or not (GB.on or A.menuOpen) then return end
    gbFont = gbFont or renderCreateFont('Arial', 9, 5)
    local txt = GB.on and (('Strefy bot  %d  '):format(ZB.done) .. (GB.why ~= '' and GB.why or GB.state)) or 'Strefy bot'
    local w = renderGetFontDrawTextLength(gbFont, txt)
    local x, y = A.hudPlace('grafbot', w + 14, 18, 0.47, 0.14)
    renderDrawBox(x, y, w + 14, 18, 0x90000000)
    renderDrawBox(x, y, 3, 18, not GB.on and 0xFF666666 or (GB.why == 'pauza' and 0xFFFFD24A or 0xFF33FF66))
    renderFontDrawText(gbFont, txt, x + 8, y + 2, 0xFFFFFFFF)
end

local MODES = { 'bike', 'foot' }

local function zMenu()
    local ui = A.ui
    local on = GB.on
    local sz = zmod()
    local total, mine, ready = 0, 0, 0
    if sz then
        for id in pairs(sz.zones()) do
            total = total + 1
            local st = sz.zone(id)
            if st and st.mine then mine = mine + 1 end
            if sz.zoneReady(id) then ready = ready + 1 end
        end
    end
    ui.kv('Status', on and (GB.why ~= '' and GB.why or GB.state) or 'wylaczony', on and 0xFF33FF66 or 0xFF8A8A96)
    ui.kv('Nasze / gotowe', ('%d / %d  (z %d)'):format(mine, ready, total))
    ui.kv('Przejete teraz', ZB.done)
    if ui.button((on and 'Stop' or 'Start') .. '##zbtoggle', nil,
        'Bot jedzie (nie zsiada) na checkpoint strefy, wciska Y i stoi 60 s, az serwer napisze, ze strefa jest Wasza, '
        .. 'potem nastepna. Stan stref czyta sam z /strefy i z czatu.') then
        ZB.toggle = true
        if not on then A.setMenu(false) end
    end
    local cur = cfg.botMode == 'bike' and 1 or 2
    local pick = ui.seg('zbmode', { 'Motor', 'Pieszo' }, cur)
    if pick then set('botMode', MODES[pick]) end
    ui.textDim(cur == 1 and 'NRG-500 (/nrg), blisko celu pieszo' or 'pieszo, sprintem')
    if cur == 1 then
        ui.sliderInt('Predkosc##zb', function() return cfg.botSpeed end, function(v) set('botSpeed', v) end, 6, 35, '%d m/s',
            'Maksymalna predkosc motoru. Na zakretach, przy scianach i przed celem zwalnia sam.')
    end
    ui.keyButton('Klawisz##zb', function() return cfg.zoneKey end, function(vk) set('zoneKey', vk) end,
        'Wlacza i wylacza Strefy Bota.')
    ui.check('Tylko gotowe##zbready', function() return cfg.zoneReadyOnly end, function(v) set('zoneReadyOnly', v) end,
        'Jedzie tylko na strefy, ktore wedlug /strefy mozna teraz przejac (nie nasze i bez blokady czasowej).')
    ui.check('HUD##zb', function() return cfg.botHud end, function(v) set('botHud', v) end,
        'Maly status Strefy Bota na ekranie.')
    if ui.button('Od nowa##zbreset', nil, 'Zapomina pominiete strefy i od razu czyta /strefy jeszcze raz.') then
        ZB.skip, ZB.refreshed, ZB.waitUntil = {}, false, 0
        if sz then sz.refresh() end
    end
    ui.textDim(RN.off and ('Trasy po drogach: ' .. RN.nodes .. ' wezlow') or (RN.off == false and 'Trasy po drogach: niedostepne' or 'Trasy po drogach: przy starcie'))
end

local function gbInit()
    A.onChat('graffiti', function(lines)                           -- log czatu bota (do poprawek)
        if not GB.on then return end
        for _, l in ipairs(lines) do
            local c = clean(l.text or ''):lower()
            if c:find('stref', 1, true) or c:find('wojn', 1, true) then gbLog('czat: ' .. c:sub(1, 120)) end
        end
    end)
end

return {
    init = gbInit,
    zmenu = zMenu,
    hud = gbHud,
    step = function(now)
        local t0 = A.hires()
        local ok, err = pcall(gbStep, now)
        if not ok and err ~= GB.lastErr then GB.lastErr = err; gbLog('blad: ' .. tostring(err)) end
        local dt = A.hires() - t0
        if GB.on and dt > 0.03 and now - (GB.slowAt or -1e9) > 5 then  -- dlugie klatki do logu (szukanie przyciec)
            GB.slowAt = now
            gbLog(('wolna klatka bota: %.0f ms (stan %s / %s)'):format(dt * 1000, tostring(GB.state), tostring(MV.state)))
        end
    end,
    key = function(vk)
        if A.chatInputActive() or A.dialogActive() then return end
        if vk == cfg.zoneKey then ZB.toggle = true end
    end,
    stop = function() if GB.on then gbStop() end end,
    release = releaseAll,
}
end)()






function M.init()
    load()
    font = renderCreateFont('Arial', cfg.hudFontSize, 0x1 + 0x4)
    autoSchedule(15)
    lastSave = os.clock()
    GBX.init()
end

function M.onKey(vk) GBX.key(vk) end

function M.frame(now)
    if not A.menuOpen then gangSetup = nil end
    runAuto()
    if now >= nextDialog then
        nextDialog = now + 0.1
        pollDialog()
    end
    if now >= nextLabels then
        nextLabels = now + cfg.labelScanMs / 1000
        scanLabels()
    end
    local interval = cfg.blinkReady and 0.4 or cfg.refreshMs / 1000
    if dirty or now - lastSync >= interval then
        dirty = false
        lastSync = now
        sync(cfg.blinkReady and floor(now / 0.4) % 2 == 1)
    end
    if now >= nextUnlock then
        nextUnlock = now + 1
        checkUnlocks()
    end
    if saveDirty and now - lastSave >= SAVE_INTERVAL then
        lastSave = now
        save()
    end
    if A.drawOk then
        drawHud(now)
    end
    GBX.step(now)
    pcall(GBX.hud)
end

function M.disable()
    GBX.stop()
    clearBlips()
    if saveDirty then save() end
end

function M.terminate(quit)
    GBX.release()
    if saveDirty then pcall(save) end
    if not quit then clearBlips() end
end

function M.status()
    return ('%d/%d, do przejecia %d, blipow %d'):format(mapCount, SERVER_TAGS, stats.ready, countActive())
end

------------------------------------------------------------------------
-- menu
------------------------------------------------------------------------

local listMode = 1   -- 1 do przejecia, 2 wszystkie
local gangBuf
local soonAt = -1e9

local function graffitiTable(px, py, h)
    local im, ui = A.imgui, A.ui
    local now = os.time()
    local rows = {}
    if listMode == 1 then
        for sid, g in pairs(gangs) do
            if isEnemy(g) and isPaintable(g) then
                local idx = tagOf[sid]
                rows[#rows + 1] = { idx = idx, sid = sid, g = g, rem = 0, d = (idx and px) and dist2d(idx, px, py) or nil }
            end
        end
        table.sort(rows, function(a, b) return (a.d or 1e9) < (b.d or 1e9) end)
        for _, e in ipairs(soonList) do rows[#rows + 1] = e end
    else
        for sid = 0, SERVER_TAGS - 1 do
            local g = gangs[sid]
            if g and g.o then
                local idx = tagOf[sid]
                rows[#rows + 1] = { idx = idx, sid = sid, g = g, rem = (g.cd or 0) - now,
                    d = (idx and px) and dist2d(idx, px, py) or nil }
            end
        end
        table.sort(rows, function(a, b) return (a.d or 1e9) < (b.d or 1e9) end)
    end

    local W = ui.W
    im.BeginChild('##grftable', im.ImVec2(W, h), true)
    if #rows == 0 then ui.textDim('Brak danych - kliknij Odswiez.') end
    im.Columns(4, '##grfcols', false)
    im.SetColumnWidth(0, W * 0.44); im.SetColumnWidth(1, W * 0.16); im.SetColumnWidth(2, W * 0.18)
    for _, e in ipairs(rows) do
        local g = e.g
        ui.text(g.z or ('#' .. e.sid)); im.NextColumn()
        ui.textCol(0xFF000000 + brighten(g.c or 0xAAAAAA), gangTag(g.o)); im.NextColumn()
        local tm = timerText(g, now)
        if isMine(g.o) then ui.textDim('nasze')
        elseif tm then ui.textCol(0xFFFFD24A, tm)
        else ui.textCol(0xFF33FF66, 'teraz') end
        im.NextColumn()
        ui.textDim(e.d and (floor(e.d + 0.5) .. ' m') or '')
        if e.idx then
            im.SameLine()
            if im.SmallButton('GPS##grfwp' .. e.sid) then setWaypoint(e.idx) end
        end
        im.NextColumn()
    end
    im.Columns(1)
    im.EndChild()
end

function M.menu()
    local im, ui = A.imgui, A.ui
    local px, py
    if isPlayerPlaying(PLAYER_HANDLE) then px, py = getCharCoordinates(PLAYER_PED) end
    local t = A.now()
    if t - soonAt > 0.5 then
        soonAt = t
        pcall(rebuildSoon, px, py)
    end

    ui.group('Graffiti', function()
        local pick = ui.seg('grfl', { 'Do przejecia (' .. stats.ready .. ')', 'Wszystkie' }, listMode)
        if pick then listMode = pick end
        graffitiTable(px, py, 200)
        ui.buttons({
            { 'GPS', cmdNext, 'Ustawia waypoint na najblizsze graffiti, ktore mozna przejac.' },
            { 'Odswiez', function()
                auto.disabled, auto.failures, auto.force = false, 0, true
                autoSchedule(0)
            end, 'Od razu otwiera /graffiti w tle i wczytuje aktualne dane.' },
        })
    end)

    if gangSetup == nil then gangSetup = (cfg.myGang == '') end
    ui.cols(function()
        ui.group('Opcje', function()
            if gangSetup then
                if not gangBuf then
                    gangBuf = im.new.char[64]()
                    A.ffi.copy(gangBuf, A.u8(cfg.myGang):sub(1, 63))
                end
                ui.textDim('Fragment nazwy Twojego gangu (np. CWL)')
                if ui.input('##grfgang', 'np. CWL', gangBuf, 64, 0) then
                    set('myGang', A.trim(A.cp(A.ffi.string(gangBuf))))
                end
            end
            ui.checks({
                { 'Radar##grf', function() return cfg.enabled end, function(v) set('enabled', v) end,
                  'Graffiti jako kolorowe punkty na radarze. Kolor = gang, ktory je ma.' },
                { 'Tylko gotowe', function() return cfg.filter == 'paint' end,
                    function(v) set('filter', v and 'paint' or 'all') end,
                  'Na radarze zostaja tylko cudze graffiti, ktore mozna juz przejac.' },
                { 'HUD##grf', function() return cfg.hud end, function(v) set('hud', v) end,
                  'Lista na ekranie: najblizsze graffiti do przejecia i odliczanie pozostalych.' },
                { 'Auto Refresh', function() return cfg.autoRefresh end, function(v)
                    set('autoRefresh', v)
                    auto.disabled, auto.failures = false, 0
                    autoSchedule(5)
                end, 'Co kilka minut sam otwiera /graffiti w tle i odswieza dane.' },
            }, 1)
        end)
    end, function()
        local sz = A.mods.strefy
        if sz and sz.ready and sz.menuGroup then ui.group('Strefy', sz.menuGroup) end
        ui.group('Strefy Bot', GBX.zmenu)
    end)
end

return M
end)(A))

-- ============================================================================
-- MODUL: STREFY (dawny StrefaAlert 2.1) - alerty o strefach gangu na Discorda
-- Dziala z BackgroundPlay.lua: gra nie staje na alt-tabie, czat dalej przychodzi.
-- ============================================================================
A.register((function(A)
local ffi = A.ffi

local M = { id = 'strefy', title = 'Strefy', hidden = true }
local FILE = A.DIR .. '\\strefy.json'
local LOG_FILE = A.DIR .. '\\strefy_log.txt'

local C = {
    discord   = true,
    webhook   = 'https://discord.com/api/webhooks/1548491127324155954/zCGXwu2efJ6Zl591f_ky5Gsdh5YP6VJpy3mzSkNE6jQEfGAUFmp8BCjpPmM8rbcgaRM7',
    gang      = 'imperium orczych bagniakow CWL',                                 -- nazwa gangu do embedow
    footer    = 'PMS Zone & Graffiti Watcher',
    captureSec = 60,           -- odliczanie w embedzie o ataku
    cooldown  = 60,            -- to samo zdarzenie (typ + gang + strefa): max 1 raz na tyle sekund
    chatEcho  = false,         -- alert tez na czacie gry
    logChat   = true,          -- linie czatu o strefach do logu
    attackHud = true,          -- HUD: nasz gang przejmuje strefe (60 s)
    enemyHud  = true,          -- HUD: ktos atakuje nasza strefe (kto, jak dlugo, gdzie, jaki teleport)
}

local function gangLabel() return C.gang ~= '' and C.gang or 'nasz gang' end

local BATCH_QUIET, BATCH_MAX = 0.4, 2
local SEND_GAP, MAX_TRIES = 1.0, 5
local GAP_SECONDS, MAX_CATCHUP = 5, 300
local HEARTBEAT = 300
local LOG_MAX_BYTES = 1024 * 1024
local CONT_END, CONT_START = '\172', '\187'   -- serwer tnie dlugie komunikaty (CP1250)
local RECENT_MAX = 25

local setupOpen, whBuf, gnBuf = nil, nil, nil
local recent = {}                              -- ostatnie wpisy logu (menu)
local stats = { ok = 0, fail = 0, events = 0 }

-- ------------------------------------------------------------ log
local function logf(msg)
    A.log('strefy', msg)
    recent[#recent + 1] = os.date('%H:%M:%S ') .. msg
    if #recent > RECENT_MAX then table.remove(recent, 1) end
    local f = io.open(LOG_FILE, 'ab')
    if f then
        f:write(os.date('%Y-%m-%d %H:%M:%S') .. '  ' .. msg .. '\r\n')
        f:close()
    end
end

local function rotateLog()
    local f = io.open(LOG_FILE, 'rb')
    if not f then return end
    local size = f:seek('end')
    f:close()
    if size and size > LOG_MAX_BYTES then
        os.remove(LOG_FILE .. '.old')
        os.rename(LOG_FILE, LOG_FILE .. '.old')
    end
end

-- ------------------------------------------------------------ tekst
local CP1250 = A.CP1250

local function jsonEsc(s)
    local out = {}
    for i = 1, #s do
        local b = s:byte(i)
        if b == 34 then out[#out + 1] = '\\"'
        elseif b == 92 then out[#out + 1] = '\\\\'
        elseif b < 32 then out[#out + 1] = string.format('\\u%04x', b)
        elseif b < 127 then out[#out + 1] = string.char(b)
        elseif CP1250[b] then out[#out + 1] = string.format('\\u%04x', CP1250[b])
        else out[#out + 1] = '?' end
    end
    return table.concat(out)
end

local function cleanText(s)
    s = A.stripColors(s):gsub('%s+', ' ')
    return (s:gsub('^%s+', ''):gsub('%s+$', ''))
end

local function clip(s, n) return #s > n and s:sub(1, n) or s end

-- ------------------------------------------------------------ parsery (formaty z logu samp.gg)
-- "Strefa Idlewood (8) nalezaca do Twojego gangu zostala zaatakowana przez goldapia67 67!"
local function parseAttack(c)
    local low = c:lower()
    local _, e = low:find('zaatakowana%s+przez%s+')
    if not (e and low:find('twojego gangu', 1, true)) then return nil end
    local attacker = c:sub(e + 1):match('^([^!]+)')
    if attacker then attacker = attacker:gsub('%s+$', '') end
    if not attacker or #attacker == 0 then attacker = 'nieznany gang' end
    local zone
    local _, ze = low:find('strefa%s+')
    if ze then
        local ns = low:sub(ze + 1):find('%s+nale')
        if ns and ns > 1 then zone = c:sub(ze + 1, ze + ns - 1) end
    end
    return clip(attacker, 60), zone
end

-- "Gangowi garwolinska 15 nie udalo sie podbic strefy Willowfield (1) nalezacej do Twojego gangu."
local function parseDefended(c)
    local low = c:lower()
    if not (low:find('nie uda', 1, true) and low:find('podbi', 1, true) and low:find('twojego', 1, true)) then return nil end
    local attacker = 'nieznany gang'
    local _, a2 = low:find('^gangowi%s+')
    if a2 then
        local b1 = low:find('%s+nie%s+uda', a2 + 1)
        if b1 and b1 > a2 + 1 then attacker = c:sub(a2 + 1, b1 - 1) end
    end
    local zone
    local _, s2 = low:find('strefy%s+')
    if s2 then
        local n1 = low:find('%s+nale', s2 + 1)
        if n1 and n1 > s2 + 1 then zone = c:sub(s2 + 1, n1 - 1) end
    end
    return clip(attacker, 60), zone
end

-- "Gang Koneserzy Papieroska KP podbil strefe Glen Park (9) nalezaca dotychczas do Twojego gangu!"
local function parseLost(c)
    local low = c:lower()
    if not (low:find('podbi', 1, true) and low:find('dotychczas do twojego', 1, true)) then return nil end
    local attacker = 'nieznany gang'
    local _, a2 = low:find('^gang%s+')
    if a2 then
        local b1 = low:find('%s+podbi', a2 + 1)
        if b1 and b1 > a2 + 1 then attacker = c:sub(a2 + 1, b1 - 1) end
    end
    local zone
    local p = low:find('podbi', 1, true)
    local _, s2 = low:find('stref%S*%s+', p)
    if s2 then
        local n1 = low:find('%s+nale', s2 + 1)
        if n1 and n1 > s2 + 1 then zone = c:sub(s2 + 1, n1 - 1) end
    end
    return clip(attacker, 60), zone
end

-- ------------------------------------------------------------ embedy
local COLOR_ATTACK, COLOR_DEFENDED, COLOR_LOST = 15105570, 3066993, 15158332
local MAX_LIST_LINES = 25

local function wrapEmbed(title, description, color, fields)
    return '{"embeds":[{'
        .. '"title":"' .. title .. '",'
        .. '"description":"' .. description .. '",'
        .. '"color":' .. color .. ','
        .. (fields and ('"fields":[' .. fields .. '],') or '')
        .. '"timestamp":"' .. os.date('!%Y-%m-%dT%H:%M:%S.000Z') .. '",'
        .. '"footer":{"text":"' .. jsonEsc(C.footer) .. '"}'
        .. '}]}'
end

local function timerText(ev)
    local left = C.captureSec - ev.delay - math.floor(os.clock() - ev.at)
    if left > 0 then return '<t:' .. (os.time() + left) .. ':R>' end
    return 'prawdopodobnie ju\\u017c po czasie'
end

local function zoneText(z) return z and jsonEsc(z) or '?' end

local function listLines(events, lineFn)
    local lines = {}
    for i, ev in ipairs(events) do
        if i > MAX_LIST_LINES then
            lines[#lines + 1] = '...i jeszcze ' .. (#events - MAX_LIST_LINES)
            break
        end
        lines[#lines + 1] = '\\u2022 ' .. lineFn(ev)
    end
    return table.concat(lines, '\\n')
end

local BUILD = {}

function BUILD.atak(events)
    if #events == 1 then
        local ev = events[1]
        local a = jsonEsc(ev.attacker)
        local fields = '{"name":"Strefa","value":"' .. zoneText(ev.zone) .. '","inline":true},'
            .. '{"name":"Obecny w\\u0142a\\u015bciciel","value":"' .. jsonEsc(gangLabel()) .. '","inline":true},'
            .. '{"name":"Atakuj\\u0105cy","value":"**' .. a .. '**","inline":true},'
            .. '{"name":"Przej\\u0119cie za (bez obrony)","value":"' .. timerText(ev) .. '","inline":false}'
        if ev.delay > 0 then
            fields = fields .. ',{"name":"\\u26a0\\ufe0f Wykryto z op\\u00f3\\u017anieniem",'
                .. '"value":"do ' .. ev.delay .. ' s - gra wstrzyma\\u0142a skrypt","inline":false}'
        end
        return wrapEmbed('\\ud83d\\udea8 NASZA STREFA JEST ATAKOWANA!',
            '**' .. a .. '** atakuje **nasz\\u0105** stref\\u0119! Je\\u015bli nikt nie obroni, przejm\\u0105 j\\u0105 za:',
            COLOR_ATTACK, fields)
    end
    return wrapEmbed('\\ud83d\\udea8 ATAKOWANE S\\u0104 NASZE STREFY (' .. #events .. ')!', listLines(events, function(ev)
        return '**' .. zoneText(ev.zone) .. '** - atakuje **' .. jsonEsc(ev.attacker) .. '**, przej\\u0119cie ' .. timerText(ev)
    end), COLOR_ATTACK)
end

function BUILD.odparty(events)
    if #events == 1 then
        local ev = events[1]
        local a = jsonEsc(ev.attacker)
        local fields = '{"name":"Strefa","value":"' .. zoneText(ev.zone) .. '","inline":true},'
            .. '{"name":"W\\u0142a\\u015bciciel","value":"' .. jsonEsc(gangLabel()) .. '","inline":true},'
            .. '{"name":"Atakuj\\u0105cy","value":"**' .. a .. '**","inline":true}'
        return wrapEmbed('\\ud83d\\udee1\\ufe0f ATAK ODPARTY!',
            '**' .. a .. '** nie zdo\\u0142a\\u0142 przej\\u0105\\u0107 naszej strefy.', COLOR_DEFENDED, fields)
    end
    return wrapEmbed('\\ud83d\\udee1\\ufe0f ODPARLI\\u015aMY ATAKI (' .. #events .. ')!', listLines(events, function(ev)
        return '**' .. zoneText(ev.zone) .. '** - atakowa\\u0142 **' .. jsonEsc(ev.attacker) .. '**'
    end), COLOR_DEFENDED)
end

function BUILD.stracona(events)
    if #events == 1 then
        local ev = events[1]
        local a = jsonEsc(ev.attacker)
        local fields = '{"name":"Strefa","value":"' .. zoneText(ev.zone) .. '","inline":true},'
            .. '{"name":"Poprzedni w\\u0142a\\u015bciciel","value":"' .. jsonEsc(gangLabel()) .. '","inline":true},'
            .. '{"name":"Nowy w\\u0142a\\u015bciciel","value":"**' .. a .. '**","inline":true}'
        return wrapEmbed('\\ud83c\\udff4 STRACILI\\u015aMY STREF\\u0118!',
            '**' .. a .. '** przej\\u0105\\u0142 nasz\\u0105 stref\\u0119.', COLOR_LOST, fields)
    end
    return wrapEmbed('\\ud83c\\udff4 STRACILI\\u015aMY STREFY (' .. #events .. ')!', listLines(events, function(ev)
        return '**' .. zoneText(ev.zone) .. '** - przej\\u0105\\u0142 **' .. jsonEsc(ev.attacker) .. '**'
    end), COLOR_LOST)
end

-- ------------------------------------------------------------ wysylka (kolejka, 429, curl -> PowerShell)
local outbox, inflight = {}, nil
local lastLaunch, sendIdx = -100, 0
local TMP = (os.getenv('TEMP') or os.getenv('TMP') or A.DIR)

local function fpath(n, kind, ext) return TMP .. '\\antek_strefy_' .. n .. '_' .. kind .. '.' .. ext end

local function removeSendFiles(n)
    os.remove(fpath(n, 'payload', 'json'))
    os.remove(fpath(n, 'hdr', 'txt'))
    os.remove(fpath(n, 'body', 'txt'))
    os.remove(fpath(n, 'code', 'txt'))
end

local function enqueueSend(json, label, detected)
    if not C.discord then return end
    if not C.webhook:find('^https://') then
        logf('Brak poprawnego webhooka - nie wysylam: ' .. label)
        return
    end
    outbox[#outbox + 1] = { json = json, label = label, tries = 0, notBefore = 0, detected = detected or os.clock() }
end

local function retryLater(p, why, delay)
    if p.tries < MAX_TRIES then
        p.notBefore = os.clock() + delay
        table.insert(outbox, 1, p)
        logf(string.format('Discord: %s - ponawiam za %.1f s (%d/%d) - %s', why, delay, p.tries, MAX_TRIES, p.label))
    else
        stats.fail = stats.fail + 1
        logf('Discord: ' .. why .. ' - poddaje sie po ' .. p.tries .. ' probach - ' .. p.label)
    end
end

local function took(p) return string.format('%.1f s od wykrycia', os.clock() - p.detected) end

-- nil = proces dziala, liczba = zakonczony
local function procExit(p)
    if not p then return -1 end
    if A.proc.running(p) then return nil end
    return A.proc.finish(p)
end

local function startFallback(p)
    p.fallback, p.ft = true, os.clock()
    local ps = '[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12; '
        .. 'try { $r = Invoke-WebRequest -UseBasicParsing -Uri \'' .. C.webhook
        .. '\' -Method Post -ContentType \'application/json\' -InFile \'' .. fpath(p.n, 'payload', 'json')
        .. '\'; Set-Content -Path \'' .. fpath(p.n, 'code', 'txt') .. '\' -Value ([int]$r.StatusCode) } '
        .. 'catch { Set-Content -Path \'' .. fpath(p.n, 'code', 'txt') .. '\' -Value (\'ERR \' + $_.Exception.Message) }'
    A.proc.finish(p.proc)
    p.proc = A.proc.spawn('powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -Command "' .. ps .. '"')
    logf('Wysylka zapasowa przez PowerShell (start: ' .. tostring(p.proc ~= nil) .. ')')
end

local function finishInflight()
    A.proc.finish(inflight.proc)
    removeSendFiles(inflight.n)
    inflight = nil
end

local function launchNext()
    if inflight or #outbox == 0 then return end
    local c = os.clock()
    if c - lastLaunch < SEND_GAP or c < outbox[1].notBefore then return end

    local p = table.remove(outbox, 1)
    sendIdx = sendIdx % 20 + 1
    p.n = sendIdx
    removeSendFiles(p.n)
    if not A.writeFile(fpath(p.n, 'payload', 'json'), p.json) then
        logf('BLAD: nie moge zapisac ' .. fpath(p.n, 'payload', 'json') .. ' - pomijam: ' .. p.label)
        return
    end
    p.tries, p.t, p.fallback = p.tries + 1, c, false
    inflight, lastLaunch = p, c
    p.proc = A.proc.spawn('curl.exe -s -m 15 -D "' .. fpath(p.n, 'hdr', 'txt') .. '" -o "' .. fpath(p.n, 'body', 'txt')
        .. '" -X POST -H "Content-Type: application/json" --data-binary "@' .. fpath(p.n, 'payload', 'json')
        .. '" "' .. C.webhook .. '"')
    if not p.proc then startFallback(p) end
end

local function processInflight()
    local p = inflight
    if not p then return end
    local c = os.clock()

    local hdr = A.readFile(fpath(p.n, 'hdr', 'txt'))
    if hdr and #hdr > 0 then
        local status
        for line in hdr:gmatch('[^\r\n]+') do
            local st = line:match('^HTTP/%S+%s+(%d+)')
            if st then status = tonumber(st) end
        end
        if not status and procExit(p.proc) == nil then return end   -- naglowki jeszcze sie zapisuja
        local body = A.readFile(fpath(p.n, 'body', 'txt')) or ''
        finishInflight()
        if status and status >= 200 and status < 300 then
            stats.ok = stats.ok + 1
            logf('Discord: OK (HTTP ' .. status .. ', ' .. took(p) .. ') - ' .. p.label)
        elseif status == 429 then
            retryLater(p, 'limit (429)', (tonumber(body:match('"retry_after"%s*:%s*([%d%.]+)')) or 1) + 0.3)
        elseif status and status >= 500 then
            retryLater(p, 'blad Discorda (HTTP ' .. status .. ')', 2 * p.tries)
        else
            stats.fail = stats.fail + 1
            logf('Discord: BLAD HTTP ' .. tostring(status) .. ' - ' .. p.label .. ' | ' .. body:sub(1, 200)
                .. ((status == 401 or status == 404) and ' (sprawdz webhook)' or ''))
        end
        return
    end

    if p.fallback then
        local code = A.readFile(fpath(p.n, 'code', 'txt'))
        if code and #code > 0 then
            code = code:gsub('%s+$', '')
            finishInflight()
            if code:match('^2%d%d$') then
                stats.ok = stats.ok + 1
                logf('Discord (PowerShell): OK (HTTP ' .. code .. ', ' .. took(p) .. ') - ' .. p.label)
            elseif code:match('429') or code:match('^5%d%d') then
                retryLater(p, 'PowerShell: ' .. code, 2 * p.tries)
            else
                stats.fail = stats.fail + 1
                logf('Discord (PowerShell): BLAD ' .. code .. ' - ' .. p.label)
            end
        elseif (procExit(p.proc) ~= nil and c - p.ft > 1) or c - p.ft > 15 then
            finishInflight()
            retryLater(p, 'brak polaczenia (curl i PowerShell)', 3 * p.tries)
        end
    elseif procExit(p.proc) ~= nil or c - p.t > 8 then
        logf('curl bez odpowiedzi (kod ' .. tostring(p.proc and p.proc.code or '?') .. ') - probuje PowerShell...')
        startFallback(p)
    end
end

-- ------------------------------------------------------------ zdarzenia (paczki z tej samej chwili)
local lastByKey, batch = {}, {}
local batchFirst, batchLast = 0, 0
local KIND_LOG = { atak = 'ALERT: atakuje', odparty = 'ODPARTY:', stracona = 'STRACONA: przejal' }
local KIND_CHAT = { atak = '{FF9900}ATAK', odparty = '{33FF66}ODPARTY', stracona = '{FF3333}STRACONA' }

local function queueEvent(kind, attacker, zone, delay)
    local t = os.time()
    local key = (kind .. '|' .. attacker .. '|' .. tostring(zone or '')):lower()
    if lastByKey[key] and t - lastByKey[key] < C.cooldown then
        logf('Pominieto powtorke (' .. kind .. '): ' .. attacker .. ' (strefa: ' .. tostring(zone) .. ')')
        return
    end
    lastByKey[key] = t
    stats.events = stats.events + 1
    logf(KIND_LOG[kind] .. ' ' .. attacker .. ' (strefa: ' .. tostring(zone) .. ')'
        .. (delay > 0 and (', wykryte z opoznieniem do ' .. delay .. ' s') or ''))
    if C.chatEcho then A.say('Strefy', KIND_CHAT[kind] .. '{FFFFFF} ' .. tostring(zone or '?') .. ' - ' .. attacker, 'FF9900') end
    if delay > MAX_CATCHUP then
        logf('Za stare po przerwie w dzialaniu skryptu - nie wysylam.')
        return
    end
    local c = os.clock()
    if #batch == 0 then batchFirst = c end
    batchLast = c
    batch[#batch + 1] = { kind = kind, attacker = attacker, zone = zone, delay = delay, at = c }
end

local function flushBatch()
    local events = batch
    batch = {}
    local lostZones = {}
    for _, ev in ipairs(events) do
        if ev.kind == 'stracona' and ev.zone then lostZones[ev.zone] = true end
    end
    local by = { atak = {}, stracona = {}, odparty = {} }
    for _, ev in ipairs(events) do
        if not (ev.kind == 'atak' and ev.zone and lostZones[ev.zone]) then
            local l = by[ev.kind]
            l[#l + 1] = ev
        end
    end
    for _, kind in ipairs({ 'atak', 'stracona', 'odparty' }) do
        local l = by[kind]
        if #l > 0 then
            enqueueSend(BUILD[kind](l), kind .. (#l == 1 and (': ' .. l[1].attacker) or (' x' .. #l)), batchFirst)
        end
    end
    if #events > 1 then logf('Polaczono ' .. #events .. ' zdarzen w wiadomosci.') end
end

local PARSERS = { { 'atak', parseAttack }, { 'odparty', parseDefended }, { 'stracona', parseLost } }

local lastLogged, lastLoggedTime, repeatCount = nil, 0, 0

local function logChat(c)
    local now = os.time()
    if c == lastLogged and now - lastLoggedTime < 10 then
        repeatCount, lastLoggedTime = repeatCount + 1, now
        return
    end
    if repeatCount > 0 then logf('czat: (poprzednia linia powtorzona jeszcze ' .. repeatCount .. ' razy)') end
    repeatCount, lastLogged, lastLoggedTime = 0, c, now
    logf('czat: ' .. c)
end

local detectOwnAttack                           -- zdefiniowane nizej (sekcja HUD ataku)
local enemyEvent                                -- zdefiniowane nizej (stan stref)
local zoneChat                                  -- zdefiniowane nizej (stan stref)

local function handleLine(c, delay, t)
    pcall(detectOwnAttack, c, t)
    pcall(zoneChat, c)
    if C.logChat then
        local low = c:lower()
        if low:find('stref', 1, true) or low:find('gtp', 1, true) or low:find('przejm', 1, true) or low:find('atak', 1, true) then
            logChat(c)
        end
    end
    for _, pr in ipairs(PARSERS) do
        local attacker, zone = pr[2](c)
        if attacker then
            pcall(enemyEvent, pr[1], attacker, zone, t)
            return queueEvent(pr[1], attacker, zone, delay)
        end
    end
end

-- ------------------------------------------------------------ HUD ataku (nasz gang przejmuje strefe)
local CAPTURE = 60
local ATT_LAG = 1.0                             -- komunikat o ataku przychodzi ok. 1 s po starcie odliczania na serwerze
local ATT = {}                                  -- { zone, t0 } - aktywne przejecia
local attFont, zoneFont
local unknownLogged = 0

local function gangTag()
    local last = C.gang:match('(%S+)%s*$')
    if last and #last <= 6 and last:upper() == last then return last end
    return C.gang ~= '' and C.gang or 'Nasz gang'
end

local function isPlayerChat(c)
    return c:find('%(Gracz%)') or c:match('^%d+%s+%[') or c:match('^[%w_%[%]%.%$]+%s*%(%d+%)%s*:')
end

-- tekst miedzy slowem kluczowym a koncem zdania, wyciety z oryginalu (lower() nie zmienia pozycji bajtow)
local function cutAfter(c, low, pattern)
    local _, _, p1, _, p2 = low:find(pattern)            -- wzorzec: ()(.-)() -> pozycja, tekst, pozycja
    if not p1 then return nil end
    local name = A.trim(c:sub(p1, p2 - 1))
    return name ~= '' and name:sub(1, 40) or nil
end

detectOwnAttack = function(c, t)
    if isPlayerChat(c) then return end
    local low = c:lower()
    local ours = low:find('tw.j gang', 1) or (C.gang ~= '' and low:find(C.gang:lower(), 1, true))
    local attacking = low:find('atakuj', 1, true) or (low:find('przejm', 1, true) and (low:find('rozpocz', 1, true) or low:find('przejmuje', 1, true)))
    if not (ours and attacking) then return end
    if low:find('zaatakowan', 1, true) then return end          -- to atak NA nas (obsluguje alert Discord)
    if low:find('nie mo', 1, true) or low:find('w tej chwili', 1, true) then return end   -- "Nie mozesz teleportowac..." itp.
    local zone = cutAfter(c, low, 'stref%S*%s+()(.-)()%s*[%.!,%(]') or cutAfter(c, low, 'stref%S*%s+()(.-)()$')
        or cutAfter(c, low, 'atakuje%s+()(.-)()%s*[%.!,%(]') or cutAfter(c, low, 'atakuje%s+()(.-)()$')
    if not zone then
        if unknownLogged < 10 then unknownLogged = unknownLogged + 1; logf('atak: nie umiem wyciagnac nazwy strefy z: ' .. c) end
        zone = '?'
    end
    local now = (t or A.now()) - ATT_LAG
    for _, a in ipairs(ATT) do
        if a.zone == zone and now - a.t0 < CAPTURE then return end   -- ten sam atak powtorzony - bez resetu licznika
    end
    table.insert(ATT, 1, { zone = zone, t0 = now })
    while #ATT > 3 do table.remove(ATT) end
    logf('nasz atak: ' .. zone)
end

local function drawAttackHud(now)
    for i = #ATT, 1, -1 do
        if now - ATT[i].t0 >= CAPTURE then table.remove(ATT, i) end
    end
    if not C.attackHud or not A.drawOk or (#ATT == 0 and not A.menuOpen) then return end
    attFont = attFont or renderCreateFont('Arial', 9, 5)
    local lines = {}
    for _, a in ipairs(ATT) do
        lines[#lines + 1] = string.format('{FF9900}%s{FFFFFF} atakuje strefe: {FFD24A}%s', gangTag(), a.zone)
        lines[#lines + 1] = string.format('{AAAAAA}Przejecie za: {FFFFFF}%d s', math.max(0, math.ceil(CAPTURE - (now - a.t0))))
    end
    if #lines == 0 then lines = { '{AAAAAA}HUD ataku stref' } end
    local w = 0
    for _, l in ipairs(lines) do w = math.max(w, renderGetFontDrawTextLength(attFont, l)) end
    local h = #lines * 16 + 6
    local x, y = A.hudPlace('strefyatak', w + 16, h, 0.5, 0.22)
    renderDrawBox(x, y, w + 16, h, 0x90000000)
    renderDrawBox(x, y, 3, h, 0xFFFF9900)
    for i, l in ipairs(lines) do renderFontDrawText(attFont, l, x + 9, y + 3 + (i - 1) * 16, 0xFFFFFFFF) end
end

-- ------------------------------------------------------------ strefy: pozycje (stale, A.GANG_ZONES) i stan (czat + /strefy)
-- Pozycje stref sa w skrypcie (A.GANG_ZONES) - nic nie trzeba nagrywac.
-- Stan kazdej strefy (czyja jest, czy mozna ja zaatakowac) skladany z komunikatow czatu i z dialogu /strefy
-- (Strefy Bot otwiera go sam w tle: "Zobacz wszystkie strefy" -> strony -> zamkniecie).
local ZONES = {}                                 -- id -> { id, name, x, y, z, int }
for id, z in pairs(A.GANG_ZONES or {}) do
    ZONES[id] = { id = id, name = z[4] or ('strefa ' .. id), x = z[1], y = z[2], z = z[3], int = 0 }
end
local EN = {}                                    -- aktywne ataki NA NAS: { id, name, zone, attacker, t0 }
local enemyFont
local ZS = {}                                    -- id -> { mine, owner, cd (epoch, 0 = teraz), busy, lockUntil, t, src }
local ZEV = {}                                   -- komunikaty o strefach dla Strefy Bota: { t (A.now), kind, id }
local ZSNAP = { at = 0, ok = nil, rows = 0 }     -- ostatni pelny odczyt /strefy

local SFOLD = {
    [0xA5] = 'a', [0xB9] = 'a', [0xC6] = 'c', [0xE6] = 'c', [0xCA] = 'e', [0xEA] = 'e', [0xA3] = 'l', [0xB3] = 'l',
    [0xD1] = 'n', [0xF1] = 'n', [0xD3] = 'o', [0xF3] = 'o', [0x8C] = 's', [0x9C] = 's', [0x8F] = 'z', [0x9F] = 'z',
    [0xAF] = 'z', [0xBF] = 'z',
}

-- tekst gry (CP1250) -> male litery ASCII bez kolorow, do porownan
local function sfold(s)
    s = A.stripColors(tostring(s or '')):gsub('[\128-\255]', function(c) return SFOLD[c:byte()] or '?' end)
    return (s:lower():gsub('%s+', ' '))
end

local function zoneParts(zone)
    local id = tonumber(tostring(zone):match('%((%d+)%)'))
    local name = A.trim((tostring(zone):gsub('%s*%(%d+%)', '')))
    return id, name ~= '' and name or tostring(zone)
end

local function nearestTele(x, y)
    local best, bd
    for _, tp in ipairs(A.TELEPORTS or {}) do
        local d = (tp[2] - x) ^ 2 + (tp[3] - y) ^ 2
        if not bd or d < bd then best, bd = tp, d end
    end
    return best, bd and math.sqrt(bd)
end

-- czy tekst (wlasciciel strefy) to nasz gang: pelna nazwa albo tag (np. CWL) jako osobne slowo
local function myGangText(t)
    local f = sfold(t)
    if f == '' then return false end
    local g = sfold(C.gang)
    if g ~= '' and f:find(g, 1, true) then return true end
    local tag = gangTag():lower()
    if #tag < 2 or tag == 'nasz gang' then return false end
    return (' ' .. f .. ' '):find('[^%w]' .. tag:gsub('%p', '%%%0') .. '[^%w]') ~= nil
end

local function zset(id, mine, owner, src)
    if not (id and ZONES[id]) then return nil end
    local s = ZS[id]
    if not s then s = {}; ZS[id] = s end
    if mine ~= nil then s.mine = mine end
    if owner then s.owner = owner end
    if mine then s.cd, s.busy = nil, nil end
    s.t, s.src = os.time(), src or s.src
    return s
end

local function zevent(kind, id)
    ZEV[#ZEV + 1] = { t = A.now(), kind = kind, id = id }
    if #ZEV > 40 then table.remove(ZEV, 1) end
end

-- komunikaty serwera o strefach (formaty z logu samp.gg):
--  "Twoj gang atakuje strefe Idlewood (8) nalezaca do gangu FullServer FS!"           -> start przejecia
--  "Twoj gang podbil strefe Idlewood (8) nalezaca dotychczas do ... Kontrolujecie juz 29 stref!" -> przejeta
--  "W tej chwili strefa nie moze zostac zaatakowana!" / "Ta strefa jest juz przejmowana."
--  "Twoj gang w tej chwili bierze udzial w wojnie o strefe." / "Wcisnij Y, aby rozpoczac przejmowanie tej strefy."
zoneChat = function(c)
    if isPlayerChat(c) then return end
    local f = sfold(c)
    if not (f:find('stref', 1, true) or f:find('wojn', 1, true)) then return end
    local id = tonumber(f:match('%((%d+)%)'))
    if id and ZONES[id] then
        local name = c:match('[Ss]tref%S*%s+(.-)%s*%(%d+%)')
        if name and #name > 1 and #name < 40 then ZONES[id].name = A.trim(name) end
    end
    -- tylko komunikaty serwera (od poczatku linii) - nie linie graczy z czatu gangu
    if f:find('^twoj gang atakuje stref') then
        local owner = c:match('do gangu%s+(.-)%s*!?%s*$')
        zset(id, false, owner and A.trim(owner) or nil, 'czat')
        zevent('start', id)
    elseif f:find('^twoj gang podbil stref') then
        zset(id, true, gangLabel(), 'czat')
        zevent('win', id)
    elseif f:find('^gang .- podbil stref') and f:find('dotychczas do twojego', 1, true) then
        local s = zset(id, false, nil, 'czat')
        if s then s.owner = c:match('^[Gg]ang%s+(.-)%s+podbi') or s.owner end
        zevent('lost', id)
    elseif f:find('^strefa ') and f:find('zaatakowana', 1, true) and f:find('do twojego gangu', 1, true) then
        zset(id, true, gangLabel(), 'czat')
        zevent('attacked', id)
    elseif f:find('^gangowi ') and f:find('nie udalo', 1, true) and f:find('do twojego', 1, true) then
        zset(id, true, gangLabel(), 'czat')
    elseif (f:find('^twojemu gangowi') or f:find('^twoj gang nie')) and (f:find('nie udalo', 1, true) or f:find('nie zdolal', 1, true)) then
        zevent('fail', id)
    elseif f:find('^w tej chwili strefa nie moze') then
        zevent('locked', id)
    elseif f:find('^ta strefa jest juz przejmowana') then
        zevent('taken', id)
    elseif f:find('^twoj gang w tej chwili bierze udzial') then
        zevent('war', id)
    elseif f:find('^wcisnij y, aby rozpoczac przejmowanie') then
        zevent('prompt', id)
    elseif f:find('^przejmowanie stref') and f:find('dozwolone', 1, true) then
        zevent('hours', id)
    elseif f:find('^aktualnie twoj gang nie toczy') then
        zevent('nowar', id)
    elseif f:find('^ta strefa') and f:find('nalez', 1, true) and f:find('twoj', 1, true) then
        zevent('own', id)
    end
end

-- true = mozna atakowac, false = nie (nasza / blokada / trwa atak), nil = nie wiadomo
local function zoneReady(id)
    local s = ZS[id]
    if not s then return nil end
    if s.mine then return false end
    local t = os.time()
    if (s.busy and s.busy > t) or (s.lockUntil and s.lockUntil > t) or (s.cd and s.cd > t) then return false end
    if s.mine == false and (s.cd ~= nil or ZSNAP.ok) then return true end
    return nil
end

-- zdarzenia ataku NA NAS: HUD wroga
enemyEvent = function(kind, attacker, zone, t)
    local id, name = zoneParts(zone)
    local now = (t or A.now()) - ATT_LAG
    if kind == 'atak' then
        for _, e in ipairs(EN) do
            if e.zone == zone then e.attacker = attacker; return end
        end
        table.insert(EN, 1, { id = id, name = name, zone = zone, attacker = attacker, t0 = now })
        while #EN > 3 do table.remove(EN) end
    else                                          -- odparty / stracona: atak skonczony
        for i = #EN, 1, -1 do
            if EN[i].zone == zone or (id and EN[i].id == id) then table.remove(EN, i) end
        end
    end
end

local function fmtMin(sec)
    return string.format('%d:%02d', math.floor(sec / 60), math.floor(sec % 60))
end

-- HUD wroga: kto atakuje nasza strefe, jak dlugo, gdzie ona jest i jaki teleport do niej prowadzi
local function drawEnemyHud(now)
    for i = #EN, 1, -1 do
        if now - EN[i].t0 > 240 then table.remove(EN, i) end
    end
    if not C.enemyHud or not A.drawOk or (#EN == 0 and not A.menuOpen) then return end
    enemyFont = enemyFont or renderCreateFont('Arial', 9, 5)
    local lines = {}
    local px, py = getCharCoordinates(PLAYER_PED)
    for _, e in ipairs(EN) do
        lines[#lines + 1] = string.format('{FF3333}ATAK NA STREFE {FFFFFF}%s{AAAAAA}  (%s)', e.zone, tostring(e.attacker):sub(1, 28))
        local z = e.id and ZONES[e.id]
        local where
        if z then
            local tp, d = nearestTele(z.x, z.y)
            where = string.format('{AAAAAA}trwa {FFFFFF}%s{AAAAAA} | od Ciebie {FFFFFF}%.0f m{AAAAAA}%s', fmtMin(now - e.t0),
                math.sqrt((z.x - px) ^ 2 + (z.y - py) ^ 2), tp and string.format(' | TP {FF66FF}%s{AAAAAA} (%.0f m od strefy)', tp[1], d) or '')
        else
            where = string.format('{AAAAAA}trwa {FFFFFF}%s', fmtMin(now - e.t0))
        end
        lines[#lines + 1] = where
    end
    if #lines == 0 then lines = { '{AAAAAA}HUD ataku na nasze strefy' } end
    local w = 0
    for _, l in ipairs(lines) do w = math.max(w, renderGetFontDrawTextLength(enemyFont, l)) end
    local h = #lines * 16 + 6
    local x, y = A.hudPlace('strefywrog', w + 16, h, 0.5, 0.30)
    renderDrawBox(x, y, w + 16, h, 0x90000000)
    renderDrawBox(x, y, 3, h, 0xFFFF3333)
    for i, l in ipairs(lines) do renderFontDrawText(enemyFont, l, x + 9, y + 3 + (i - 1) * 16, 0xFFFFFFFF) end
end

-- ------------------------------------------------------------ /strefy w tle: menu -> "Zobacz wszystkie strefy" -> strony
local BR = { state = 'idle', want = false, nextAt = 0, deadline = 0, pages = 0, lastText = nil, rows = 0, fails = 0,
    dumped = false, closeAt = 0 }

local function dlgLines(text)
    local lines = {}
    for l in (text .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
    if lines[#lines] == '' then lines[#lines] = nil end
    return lines
end

local function dlgItem(text, style, needles)
    local offset = style == 5 and 1 or 0
    for i, l in ipairs(dlgLines(text)) do
        if i > offset then
            local f = sfold(l)
            for _, n in ipairs(needles) do
                if f:find(n, 1, true) then return i - 1 - offset end
            end
        end
    end
    return nil
end

-- kolumna statusu: 'za 20 minut' -> s, 'Tak' / 'mozna' / 'teraz' -> 0, trwa atak -> busy; nil = nie wiadomo
local function zoneCd(f)
    if f:find('trwa', 1, true) or f:find('wojn', 1, true) or f:find('atakowan', 1, true) or f:find('przejmowan', 1, true) then
        return nil, true
    end
    local n, unit = f:match('za%s+(%d+)%s*(%a*)')
    n = tonumber(n)
    if n then
        if unit:find('^sek') then return n end
        if unit:find('^godz') then return n * 3600 end
        return n * 60
    end
    local mm, ss = f:match('^(%d+):(%d%d)$')
    if mm then return tonumber(mm) * 60 + tonumber(ss) end
    if f:find('^tak') or f:find('mozna', 1, true) or f:find('teraz', 1, true) or f:find('dostepn', 1, true) then return 0 end
    return nil
end

-- wiersz listy: "id<TAB>nazwa<TAB>wlasciciel<TAB>status" albo "nazwa (id)<TAB>wlasciciel<TAB>status"
local function parseZoneRows(text)
    local n, t = 0, os.time()
    for line in (text .. '\n'):gmatch('([^\n]*)\n') do
        local raw, cols = {}, {}
        for c in (line .. '\t'):gmatch('([^\t]*)\t') do
            raw[#raw + 1] = A.trim(A.stripColors(c))
            cols[#cols + 1] = A.trim(sfold(c))
        end
        local idCol = tonumber((cols[1] or ''):match('^#?(%d+)[%.%)]?$'))
        local id = idCol or tonumber(line:match('%((%d+)%)'))
        if id and ZONES[id] and #cols >= 2 then
            local o = idCol and 1 or 0
            local last = #cols
            local cd, busy = zoneCd(cols[last])
            local statusCol = (cd ~= nil or busy) and last or nil
            local ownerIdx = 2 + o
            if ownerIdx > last or ownerIdx == statusCol then ownerIdx = nil end
            local nameIdx = 1 + o
            if o == 0 then
                local nm = raw[1]:gsub('%s*%(%d+%)%s*', '')
                if nm ~= '' then ZONES[id].name = nm end
            elseif nameIdx ~= statusCol and raw[nameIdx] and raw[nameIdx] ~= '' and not raw[nameIdx]:match('^%d+$') then
                ZONES[id].name = raw[nameIdx]
            end
            local s = ZS[id]
            if not s then s = {}; ZS[id] = s end
            if ownerIdx then
                local of = cols[ownerIdx]
                if of == '' or of == '-' or of:find('^brak') or of:find('^nikt') or of:find('^wolna') then
                    s.owner, s.mine = nil, false
                else
                    s.owner, s.mine = raw[ownerIdx], myGangText(raw[ownerIdx])
                end
            end
            if cd ~= nil then s.cd = cd > 0 and (t + cd) or 0 else s.cd = nil end
            s.busy = busy and (t + 90) or nil
            s.t, s.src = t, '/strefy'
            n = n + 1
        end
    end
    return n
end

local function browseEnd(now, ok)
    BR.state, BR.want = 'idle', false
    if ok and BR.rows > 0 then
        ZSNAP.at, ZSNAP.ok, ZSNAP.rows, BR.fails = os.time(), true, BR.rows, 0
        logf(('/strefy: odczytano %d stref (%d str.)'):format(BR.rows, BR.pages))
    elseif ZSNAP.ok == nil then
        ZSNAP.ok = false
    end
    BR.nextAt = now + (BR.rows > 0 and 2 or 20)
end

local function browseStep(now)
    if BR.state == 'idle' then
        if not BR.want or now < BR.nextAt then return end
        if A.menuOpen or not isPlayerPlaying(PLAYER_HANDLE) or A.dialogActive() or A.chatInputActive() then
            BR.nextAt = now + 1
            return
        end
        if not (type(sampProcessChatInput) == 'function' and pcall(sampProcessChatInput, '/strefy')) then pcall(sampSendChat, '/strefy') end
        BR.state, BR.deadline, BR.pages, BR.lastText, BR.rows = 'menu', now + 4, 0, nil, 0
        return
    end
    local active = A.dialogActive()
    local cap, text, style = '', '', 2
    if active then
        local ok1, c = pcall(sampGetDialogCaption)
        local ok2, tx = pcall(sampGetDialogText)
        local ok3, st = pcall(sampGetCurrentDialogType)
        cap, text, style = ok1 and tostring(c) or '', ok2 and tostring(tx) or '', ok3 and tonumber(st) or 2
    end
    local ours = active and sfold(cap):find('stref', 1, true) ~= nil
    if now > BR.deadline then
        if BR.state ~= 'closing' then
            BR.fails = BR.fails + 1
            logf('/strefy: brak odpowiedzi (stan ' .. BR.state .. ')')
            if ours then pcall(sampCloseCurrentDialogWithButton, 0) end
        end
        return browseEnd(now, BR.state == 'closing')
    end
    if active and not ours then
        if BR.state ~= 'closing' then logf('/strefy: pojawil sie inny dialog - przerywam') end
        return browseEnd(now, BR.state == 'closing')
    end
    if BR.state == 'closing' then
        if not active then return browseEnd(now, true) end
        if now >= BR.closeAt then
            BR.closeAt = now + 0.3
            pcall(sampCloseCurrentDialogWithButton, 0)              -- serwer moze po ESC wrocic do menu
        end
        return
    end
    if not active or text == BR.lastText then return end
    BR.lastText = text
    local menu = sfold(text):find('zobacz wszystkie', 1, true) ~= nil
    local rows = menu and 0 or parseZoneRows(text)
    if rows > 0 then
        if not BR.dumped then
            BR.dumped = true
            logf('/strefy lista (format): ' .. A.stripColors(text):gsub('\t', ' ; '):gsub('\r?\n', ' | '):sub(1, 1500))
        end
        BR.rows, BR.pages = BR.rows + rows, BR.pages + 1
        local nxt = BR.pages < 12 and dlgItem(text, style, { 'dalej', 'nastepn', '>>' })
        if nxt then
            pcall(sampSetCurrentDialogListItem, nxt)
            pcall(sampCloseCurrentDialogWithButton, 1)
            BR.deadline = now + 4
        else
            pcall(sampCloseCurrentDialogWithButton, 0)
            BR.state, BR.deadline, BR.closeAt = 'closing', now + 1.5, now + 0.3
        end
        return
    end
    if BR.state == 'menu' then
        local it = dlgItem(text, style, { 'wszystkie' })
        if it then
            pcall(sampSetCurrentDialogListItem, it)
            pcall(sampCloseCurrentDialogWithButton, 1)
            BR.state, BR.deadline = 'page', now + 4
            return
        end
    end
    logf('/strefy: nie rozumiem dialogu "' .. cleanText(cap) .. '": ' .. A.stripColors(text):gsub('\t', ' ; '):gsub('\r?\n', ' | '):sub(1, 1500))
    BR.fails = BR.fails + 1
    pcall(sampCloseCurrentDialogWithButton, 0)
    BR.state, BR.deadline, BR.closeAt = 'closing', now + 1.5, now + 0.3
end

-- ------------------------------------------------------------ BackgroundPlay (0x53EA88 = NOP NOP)
local function backgroundActive()
    if not A.ffiReady then return nil end
    local ok, res = pcall(function()
        if ffi.C.IsBadReadPtr(ffi.cast('void*', 0x53EA88), 2) ~= 0 then return nil end
        local p = ffi.cast('const uint8_t*', 0x53EA88)
        return p[0] == 0x90 and p[1] == 0x90
    end)
    if ok then return res end
    return nil
end

-- ------------------------------------------------------------ modul
local chatQueue = {}
local lastTick, lastBeat, chatCount = os.time(), os.time(), 0
local carry, carryTime, carryT = nil, 0, nil
local nextStep = 0

local function save() A.saveJson(FILE, { discord = C.discord, webhook = C.webhook, gang = C.gang, attackHud = C.attackHud, enemyHud = C.enemyHud }) end

function M.init()
    local t = A.loadJson(FILE)
    if t then
        C.discord = t.discord ~= false
        if type(t.webhook) == 'string' and A.trim(t.webhook) ~= '' then C.webhook = A.trim(t.webhook) end
        if type(t.gang) == 'string' and A.trim(t.gang) ~= '' then C.gang = A.trim(t.gang) end
        if type(t.attackHud) == 'boolean' then C.attackHud = t.attackHud end
        if type(t.enemyHud) == 'boolean' then C.enemyHud = t.enemyHud end
    end
    save()
    rotateLog()
    for n = 1, 20 do removeSendFiles(n) end
    lastTick, lastBeat = os.time(), os.time()
    A.onChat('strefy', function(lines)
        for _, l in ipairs(lines) do chatQueue[#chatQueue + 1] = { l.text, l.t } end
    end)
    local bg = backgroundActive()
    logf('Start. BackgroundPlay: ' .. (bg == true and 'ON' or (bg == false and 'OFF (na alt-tabie alerty przyjda po powrocie)' or '?')))
end

function M.frame()
    if not A.menuOpen then setupOpen = nil end
    local tnow = A.now()
    pcall(drawAttackHud, tnow)
    pcall(drawEnemyHud, tnow)
    if BR.state ~= 'idle' or BR.want then
        local okB, errB = pcall(browseStep, tnow)
        if not okB then logf('/strefy: blad ' .. tostring(errB)); BR.state, BR.want = 'idle', false end
    end
    local clk = os.clock()
    if clk < nextStep then return end
    nextStep = clk + 0.1

    local now = os.time()
    local gap = now - lastTick
    lastTick = now
    local delay = 0
    if gap > GAP_SECONDS then
        delay = gap
        logf('Skrypt byl wstrzymany przez ' .. gap .. ' s. Nadrabiam czat z tej przerwy.')
    end

    if now - lastBeat >= HEARTBEAT then
        lastBeat = now
        rotateLog()
        local bg = backgroundActive()
        logf('dziala (linii czatu w ' .. math.floor(HEARTBEAT / 60) .. ' min: ' .. chatCount
            .. (bg == true and ', BackgroundPlay ON' or (bg == false and ', BackgroundPlay OFF' or '')) .. ')')
        chatCount = 0
    end

    if #chatQueue > 0 then
        local lines = chatQueue
        chatQueue = {}
        for _, item in ipairs(lines) do
            chatCount = chatCount + 1
            local c, lt = cleanText(item[1]), item[2]
            if carry then
                if c:sub(1, 1) == CONT_START then
                    c, lt = carry .. ' ' .. (c:sub(2):gsub('^%s+', '')), carryT
                else
                    handleLine(carry, delay, carryT)
                end
                carry = nil
            end
            if c:sub(-1) == CONT_END then
                carry, carryTime, carryT = (c:sub(1, -2):gsub('%s+$', '')), now, lt
            else
                handleLine(c, delay, lt)
            end
        end
    end
    if carry and now - carryTime >= 2 then
        handleLine(carry, delay, carryT)
        carry = nil
    end

    if #batch > 0 and (clk - batchLast >= BATCH_QUIET or clk - batchFirst >= BATCH_MAX) then flushBatch() end
    processInflight()
    launchNext()
end

M.test = { detect = function(c) return detectOwnAttack(c) end, attacks = function() return ATT end, enemy = function() return EN end,
    event = function(k, a, z) return enemyEvent(k, a, z) end, zones = function() return ZONES end,
    chat = function(c) return zoneChat(c) end, parse = function(t) return parseZoneRows(t) end }

-- API dla Strefy Bota
M.zones = function() return ZONES end
M.zone = function(id) return ZS[id] end
M.zoneReady = zoneReady
M.events = function() return ZEV end
M.snap = ZSNAP
M.refresh = function() BR.want = true; BR.nextAt = math.min(BR.nextAt, A.now()) end
M.browsing = function() return BR.want or BR.state ~= 'idle' end
M.lock = function(id, sec)
    local s = ZS[id]
    if not s then s = {}; ZS[id] = s end
    s.lockUntil = os.time() + sec
end
M.setMine = function(id) zset(id, true, gangLabel(), 'bot') end

function M.disable()
    chatQueue, batch, ATT, EN = {}, {}, {}, {}
    BR.state, BR.want = 'idle', false
end

function M.terminate()
    if inflight then A.proc.finish(inflight.proc) end
end

function M.status()
    return ('alertow %d, wyslane %d, bledy %d%s'):format(stats.events, stats.ok, stats.fail,
        #outbox > 0 and (', w kolejce ' .. #outbox) or '')
end

-- ------------------------------------------------------------ menu

function M.menuGroup()
    local ui, im = A.ui, A.imgui
    if setupOpen == nil then setupOpen = (C.webhook == '' or C.gang == '') end
    ui.check('StrefaAlert', function() return C.discord end, function(v) C.discord = v; save() end,
        'Wysyla na Discorda alerty, gdy ktos atakuje Twoja strefe, gdy ja stracisz albo obronisz.')
    ui.check('HUD ataku', function() return C.attackHud end, function(v) C.attackHud = v; save() end,
        'Gdy Twoj gang zaczyna przejmowac strefe: nazwa strefy i odliczanie 60 s. Przeciagniesz go, gdy menu jest otwarte.')
    ui.check('HUD wroga', function() return C.enemyHud end, function(v) C.enemyHud = v; save() end,
        'Gdy ktos atakuje Twoja strefe: nazwa strefy, kto atakuje, jak dlugo trwa, ile m od Ciebie i jaki teleport tam prowadzi.')
    local mine, ready, total = 0, 0, 0
    for id in pairs(ZONES) do
        total = total + 1
        local st = ZS[id]
        if st and st.mine then mine = mine + 1 end
        if zoneReady(id) then ready = ready + 1 end
    end
    ui.kv('Nasze strefy', ('%d / %d'):format(mine, total))
    ui.kv('Gotowe do przejecia', ZSNAP.ok and tostring(ready) or (ZSNAP.ok == false and '? (/strefy nieczytelne)' or '?'))
    if ZSNAP.at > 0 then ui.kv('Odczyt /strefy', ('%d min temu'):format(math.floor((os.time() - ZSNAP.at) / 60))) end
    ui.buttons({
        { 'Odswiez /strefy', function() M.refresh() end, 'Otwiera /strefy w tle i czyta, czyja jest kazda strefa i kiedy mozna ja zaatakowac.' },
        { (M.showZones and 'Ukryj' or 'Pokaz') .. ' liste', function() M.showZones = not M.showZones end,
          'Kazda strefa: czyja jest, kiedy mozna ja przejac i najblizszy teleport.' },
    })
    if M.showZones then
        local ids = {}
        for id in pairs(ZONES) do ids[#ids + 1] = id end
        table.sort(ids)
        local t = os.time()
        for _, id in ipairs(ids) do
            local z, st = ZONES[id], ZS[id]
            local txt, col
            if st and st.mine then txt, col = 'nasza', 0xFF33FF66
            elseif st and st.cd and st.cd > t then txt, col = ('za %d min'):format(math.ceil((st.cd - t) / 60)), 0xFFFFD24A
            elseif zoneReady(id) then txt, col = 'gotowa', 0xFFFF9900
            elseif st and st.owner then txt, col = tostring(st.owner):sub(1, 18), 0xFFAAAAAA
            else txt, col = '?', 0xFF8A8A96 end
            ui.kv(A.u8(z.name) .. ' (' .. id .. ')', A.u8(txt), col)
        end
    end
end

return M
end)(A))

-- ============================================================================
-- MODUL: BILARD (dawny pool.lua) - tor bil, luzy, zalecana sila
-- Pasek sily: samp.events (jesli dziala z Twoim SF.lua) albo odczyt textdrawow co klatke.
-- ============================================================================
A.register((function(A)
local memory_ok, memory = pcall(require, 'memory')
if not memory_ok then memory = nil end

local sqrt, abs, max, min, huge = math.sqrt, math.abs, math.max, math.min, math.huge
local floor = math.floor
local clock, fmt = os.clock, string.format

local M = { id = 'pool', title = 'Bilard' }
local FILE     = A.DIR .. '\\pool.lua'
local OLD_FILE = A.WD .. '\\config\\pooltracer.lua'

--------------------------------------------------------------------------------
-- MODELE
--------------------------------------------------------------------------------
local CUE_MODEL, TABLE_MODEL, STICK_MODEL = 3003, 2964, 3004
local BALL_MODELS = {
    [0] = 3003,
    [1] = 3002, [2] = 3101, [3] = 2995, [4] = 2996, [5] = 3106, [6] = 3105, [7] = 3103,
    [8] = 3001, [9] = 3100, [10] = 2997, [11] = 3000, [12] = 3102, [13] = 2999,
    [14] = 2998, [15] = 3104,
}
local BALL_NUM = {}
for num, model in pairs(BALL_MODELS) do BALL_NUM[model] = num end
local SEEN_MODELS = {}

--------------------------------------------------------------------------------
-- KONFIG / STALE
--------------------------------------------------------------------------------
local CFG = {
    aimSrc = 0,           -- zrodlo kierunku: 0 auto, 1 kij, 2 kamera, 3 postac, 4 gracz->biala
    diag = false,         -- zapis diagnostyczny (textdrawy paska, obiekty przy bialej, kierunki, klawisze)
    mig14 = false,        -- jednorazowe wylaczenie auto celowania/strzalu po zmianie mechanizmu
    plan = true, autoAim = false, autoShoot = false,   -- planer najlepszego zagrania / auto celowanie / auto strzal
    enable = false, hud = false, rail = true,
    wide = true,          -- trasa szerokosci bili
    discrete = true,      -- poprawka na krok fizyki przy styku
    aimSource = 3,        -- 1 heading, 2 gracz->biala, 3 kij
    stickFlip = true, axisSwap = true, headingSign = 1.0,
    maxDepth = 2, maxBounces = 3, railE = 0.75, phyDt = 0.021, ballR = 0.0375,
    tdSource = 0,         -- 0 auto, 1 samp.events, 2 odczyt textdrawow
}

local K = {
    SCAN_EVERY = 0.5, SCAN_R2 = 144.0, NEAR_R2 = 36.0, AT_TABLE_R2 = 9.0,
    STICK_MAX = 1.6, Z_TOL = 0.15, TABLE_MARGIN = 0.12, FRAME_TTL = 1.0,
    SHOT_START2 = 0.0004, SHOT_DONE2 = 0.0025, SHOT_WINDOW = 0.5, SHOT_TIMEOUT = 2.0, AIM_GRACE = 1.5,
}

local TBL = {
    HX = 0.4870, HY = 0.9388, OFF_X = -0.0073, OFF_Y = 0.0060,
    POCKET_R = 0.0675, OUT_CORNER = 0.010, OUT_MID = 0.057,
    POCKETS = { {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0}, {0, 0} },
}

local function rebuildPockets()
    local X, Y, Mi = TBL.HX + TBL.OUT_CORNER, TBL.HY + TBL.OUT_CORNER, TBL.HX + TBL.OUT_MID
    local P = TBL.POCKETS
    P[1] = {-X, -Y}; P[2] = { Mi, 0}; P[3] = { X, Y}
    P[4] = {-X,  Y}; P[5] = { X, -Y}; P[6] = {-Mi, 0}
end
rebuildPockets()

local TD_BAR   = { text = 'LD_SPAC', x = 548.0, y = 222.0,   tol = 0.75 }
local TD_FRAME = { text = 'LD_SPAC', x = 546.0, y = 220.875, tol = 0.75 }
local TD_LABEL = { text = 'Power',   x = 542.5, y = 216.0,   tol = 1.5 }

local COL_CUE, COL_TARGET, COL_CHAIN = 0xFFFFFFFF, 0xFF00E676, 0xFFFFC107
local COL_GHOST, COL_POCKET = 0xA0FFFFFF, 0xFF00E676
local WHAT_POCKET = 'luza'

--------------------------------------------------------------------------------
-- STAN
--------------------------------------------------------------------------------
local AIM    = { a = 0, b = 0, c = 0, cam = 0, hasB = false, hasC = false, hasCam = false, use = 0, ok = false, src = 0 }
local AIMERR = { {}, {}, {}, {} }      -- bledy (znak) zrodel kierunku z ostatnich uderzen: kij, kamera, postac, gracz
local SRC_NAME = { 'kij', 'kamera', 'postac', 'gracz-biala' }
local CAL    = { xp = {}, xn = {}, yp = {}, yn = {}, on = true }
local TRK    = {}
local SHOT   = { ready = false, moving = false, sx = 0, sy = 0, t0 = 0, snap = nil }
local AIMING = { on = false, force = true, seen = false, ids = {}, since = 0, lastOff = nil }
local REQ    = { valid = false, power = nil, len = 0, cos2 = 0, dc = 0 }
local SKIPPED = {}
local Warn   = {}
local REC    = { phase = 0, t0 = 0, pred = nil, cueStart = nil }
local FONT   = nil
local BX, BY = 30, 300                 -- lewy gorny rog HUD-a (przeciagany)
local DIAG_AT = nil
local lastInfo = nil                   -- ostatni wynik diagnostyki (menu)

local POWER = {
    cands = {}, tdId = nil, bgId = nil, bgWidth = nil,
    value = 0, raw = 0, charging = false, released = nil, lastUpdate = 0,
    obsMax = nil, calibrated = false, spy = false, atTable = false,
    speedSamples = {}, distSamples = {},
    scaleFallback = 58.0, lead = 0.10,
    rate = nil, rateT = nil, rateW = nil,
}

local Frame = { ok = false, orientOk = false, obj = nil, t = -1e9,
    x = 0, y = 0, z = 0, ax = 1, ay = 0, bx = 0, by = 1, src = '-', angle = 0 }
local Cam  = { ok = false, x = 0, y = 0, z = 0, fx = 0, fy = 0, fz = 1 }
local Scan = { t = -1e9, px = 0, py = 0, cues = {}, tables = {}, sticks = {}, others = {} }

--------------------------------------------------------------------------------
-- NARZEDZIA
--------------------------------------------------------------------------------
local function say(f, ...)
    A.chat('{B48CFF}[Bilard]{FFFFFF} ' .. (select('#', ...) > 0 and fmt(f, ...) or f))
end

local function note(color, f, ...)
    local s = select('#', ...) > 0 and fmt(f, ...) or f
    A.log('bilard', s)
    if CFG.hud then A.chat(color .. s) end
end

local function finite(v) return type(v) == 'number' and v == v and abs(v) < 1e9 end
local function wrap180(a) return (a + 180) % 360 - 180 end
local function bearing(dx, dy) return math.deg(math.atan2(-dx, dy)) % 360 end
local function fromBearing(a)
    local r = math.rad(a)
    return -math.sin(r), math.cos(r)
end

local function mean(t)
    if #t == 0 then return nil end
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s / #t
end

local function lineCross(x1, y1, x2, y2, x3, y3, x4, y4)
    local d = (x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4)
    if abs(d) < 1e-9 then return nil end
    local a = x1 * y2 - y1 * x2
    local b = x3 * y4 - y3 * x4
    return (a * (x3 - x4) - (x1 - x2) * b) / d, (a * (y3 - y4) - (y1 - y2) * b) / d
end

local function pushSample(list, s)
    for i = 1, #s do
        if not finite(s[i]) then return false end
    end
    list[#list + 1] = s
    if #list > 300 then table.remove(list, 1) end
    list.ver = (list.ver or 0) + 1
    return true
end

local fitCache = setmetatable({}, { __mode = 'k' })
local function fitLinear(samples, idx)
    local byIdx = fitCache[samples]
    if not byIdx then byIdx = {}; fitCache[samples] = byIdx end
    local e = byIdx[idx]
    if e and e.ver == samples.ver then return e.a, e.k, e.n end
    local n, sx, sy, sxx, sxy = 0, 0, 0, 0, 0
    for _, smp in ipairs(samples) do
        local v = smp[idx]
        if v and v > 0 then
            n = n + 1
            sx, sy = sx + smp[1], sy + v
            sxx, sxy = sxx + smp[1] * smp[1], sxy + smp[1] * v
        end
    end
    local a, k
    if n >= 2 then
        local den = n * sxx - sx * sx
        if abs(den) > 1e-9 then
            k = (n * sxy - sx * sy) / den
            a = (sy - k * sx) / n
        end
    end
    byIdx[idx] = { ver = samples.ver, a = a, k = k, n = n }
    return a, k, n
end

local decelCache = {}
local function decelMedian()
    local ds, c = POWER.distSamples, decelCache
    if c.src ~= ds or c.ver ~= ds.ver then
        local t = {}
        for _, smp in ipairs(ds) do
            local a = smp[4]
            if a and a > 0.10 and a < 3.0 then t[#t + 1] = a end
        end
        table.sort(t)
        c.src, c.ver, c.n, c.m = ds, ds.ver, #t, nil
        if #t >= 2 then
            if #t % 2 == 1 then c.m = t[(#t + 1) / 2] else c.m = (t[#t / 2] + t[#t / 2 + 1]) / 2 end
        end
    end
    return c.m, c.n or 0
end

--------------------------------------------------------------------------------
-- FIZYKA SILY
--------------------------------------------------------------------------------
local function speedFromPower(p)
    local a, k = fitLinear(POWER.speedSamples, 2)
    if a then return max(0.01, a + k * p) end
    return 0.4 + p * 0.02
end

local function v0FromPower(p)
    local a, k = fitLinear(POWER.distSamples, 3)
    if a then return max(0.05, a + k * p) end
    local b, m = fitLinear(POWER.speedSamples, 2)
    if b then return max(0.05, b + m * p) end
    return nil
end

local function distFromPower(p)
    local acc = decelMedian()
    local v = v0FromPower(p)
    if not acc or not v then return nil end
    return v * v / (2 * acc), v, acc
end

local function powerFromDist(d)
    local acc = decelMedian()
    if not acc then return nil end
    local vNeed = sqrt(max(0, 2 * acc * d))
    local a, k = fitLinear(POWER.distSamples, 3)
    if not a then a, k = fitLinear(POWER.speedSamples, 2) end
    if not a or abs(k) < 1e-9 then return nil end
    return (vNeed - a) / k
end

local function stepFromPower(p)
    local a, k = fitLinear(POWER.speedSamples, 3)
    local v
    if a then v = a + k * p else v = speedFromPower(p) * CFG.phyDt end
    return max(0.001, min(0.06, v))
end

local function stepTrusted() return (POWER.bgWidth ~= nil or POWER.rmbMode) and POWER.value > 1 end

--------------------------------------------------------------------------------
-- OBIEKTY / UKLAD STOLU
--------------------------------------------------------------------------------
local function objHeading(obj)
    local ok, a, b = pcall(getObjectHeading, obj)
    if not ok then return nil end
    if type(a) == 'boolean' then return b end
    return a
end

-- osie z CMatrix (CPlaceable+0x14): right.xy +0x00/+0x04, forward.xy +0x10/+0x14
local warnedMatrix = {}
local function objAxes(obj)
    if not memory then return nil end
    local ok, ptr = pcall(getObjectPointer, obj)
    if not ok or not ptr or ptr == 0 then return nil end
    local ok2, mat = pcall(memory.getuint32, ptr + 0x14, true)
    if not ok2 or not mat or mat == 0 then
        if not warnedMatrix[obj] then
            warnedMatrix[obj] = true
            A.log('bilard', 'obiekt ' .. tostring(obj) .. ': brak macierzy, fallback na heading')
        end
        return nil
    end
    local ok3, rx, ry, fx, fy = pcall(function()
        return memory.getfloat(mat + 0x00, true), memory.getfloat(mat + 0x04, true),
               memory.getfloat(mat + 0x10, true), memory.getfloat(mat + 0x14, true)
    end)
    if not ok3 or not rx then return nil end
    local lr, lf = sqrt(rx * rx + ry * ry), sqrt(fx * fx + fy * fy)
    if lr < 1e-6 or lf < 1e-6 then return nil end
    return rx / lr, ry / lr, fx / lf, fy / lf
end

function Frame:setAxes(x, y, z, ax, ay, bx, by, src)
    if CFG.axisSwap then ax, ay, bx, by = -bx, -by, ax, ay end
    self.x, self.y, self.z = x, y, z
    self.ax, self.ay, self.bx, self.by = ax, ay, bx, by
    self.src = src
    self.angle = math.deg(math.atan2(-bx, by)) % 360
    self.ok = true
end

function Frame:setFromHeading(x, y, z, hdgDeg)
    local r = math.rad(hdgDeg * CFG.headingSign)
    local c, sn = math.cos(r), math.sin(r)
    self:setAxes(x, y, z, c, sn, -sn, c, 'heading')
end

function Frame:toWorld(lx, ly)
    lx, ly = lx + TBL.OFF_X, ly + TBL.OFF_Y
    return self.x + lx * self.ax + ly * self.bx, self.y + lx * self.ay + ly * self.by
end

function Frame:toLocal(wx, wy)
    local dx, dy = wx - self.x, wy - self.y
    return dx * self.ax + dy * self.ay - TBL.OFF_X, dx * self.bx + dy * self.by - TBL.OFF_Y
end

function Frame:dirToLocal(dx, dy)
    return dx * self.ax + dy * self.ay, dx * self.bx + dy * self.by
end

local function setFrameFromObject(obj, x, y, z)
    local ax, ay, bx, by = objAxes(obj)
    if ax then
        Frame:setAxes(x, y, z, ax, ay, bx, by, 'matrix')
        Frame.orientOk = true
        return true
    end
    local h = objHeading(obj)
    if h then
        Frame:setFromHeading(x, y, z, h)
        Frame.orientOk = true
        return true
    end
    Frame:setFromHeading(x, y, z, 0)
    Frame.src, Frame.orientOk = 'brak danych', false
    return false
end

local function frameFromTable(tbl)
    local now = clock()
    if not (Frame.ok and Frame.obj == tbl.obj and now - Frame.t < K.FRAME_TTL) then
        setFrameFromObject(tbl.obj, tbl.x, tbl.y, tbl.z)
        Frame.obj, Frame.t = tbl.obj, now
    end
    return Frame.orientOk
end

local function distToRail(lx, ly, dx, dy)
    local tx, ty = huge, huge
    if dx > 1e-9 then tx = (TBL.HX - lx) / dx elseif dx < -1e-9 then tx = (-TBL.HX - lx) / dx end
    if dy > 1e-9 then ty = (TBL.HY - ly) / dy elseif dy < -1e-9 then ty = (-TBL.HY - ly) / dy end
    if tx < ty then return tx, 'x' end
    if ty < huge then return ty, 'y' end
    return 0, nil
end

--------------------------------------------------------------------------------
-- SKAN OBIEKTOW
--------------------------------------------------------------------------------
local function rescan(px, py)
    local cues, tables, sticks, others = {}, {}, {}, {}
    for _, obj in ipairs(getAllObjects()) do
        if doesObjectExist(obj) then
            local model = getObjectModel(obj)
            if model == CUE_MODEL then cues[#cues + 1] = obj
            elseif model == TABLE_MODEL then tables[#tables + 1] = obj
            elseif model == STICK_MODEL then sticks[#sticks + 1] = obj
            else
                local _, x, y = getObjectCoordinates(obj)
                if (x - px) ^ 2 + (y - py) ^ 2 < K.SCAN_R2 then others[#others + 1] = { obj = obj, model = model } end
            end
        end
    end
    Scan.t, Scan.px, Scan.py = clock(), px, py
    Scan.cues, Scan.tables, Scan.sticks, Scan.others = cues, tables, sticks, others
end

local function findPool(px, py, fx, fy)
    if clock() - Scan.t > K.SCAN_EVERY or (px - Scan.px) ^ 2 + (py - Scan.py) ^ 2 > 25.0 then rescan(px, py) end

    local cue, cueX, cueY, cueZ, cueD = nil, 0, 0, 0, huge
    for _, obj in ipairs(Scan.cues) do
        if doesObjectExist(obj) then
            local _, x, y, z = getObjectCoordinates(obj)
            local d = (x - px) ^ 2 + (y - py) ^ 2
            if fx and (x - px) * fx + (y - py) * fy <= 0 then d = d + 100 end
            if d < cueD then cue, cueX, cueY, cueZ, cueD = obj, x, y, z, d end
        end
    end
    if not cue then return nil end

    local best, bestD = nil, huge
    for _, obj in ipairs(Scan.tables) do
        if doesObjectExist(obj) then
            local _, x, y, z = getObjectCoordinates(obj)
            local d = (x - cueX) ^ 2 + (y - cueY) ^ 2
            if d < bestD then best, bestD = { obj = obj, x = x, y = y, z = z }, d end
        end
    end

    local stick, stickD = nil, K.STICK_MAX
    for _, obj in ipairs(Scan.sticks) do
        if doesObjectExist(obj) then
            local _, x, y = getObjectCoordinates(obj)
            local d = sqrt((x - cueX) ^ 2 + (y - cueY) ^ 2)
            if d < stickD then stick, stickD = { obj = obj }, d end
        end
    end

    local balls = {}
    for _, o in ipairs(Scan.others) do
        if doesObjectExist(o.obj) then
            local _, x, y, z = getObjectCoordinates(o.obj)
            if (x - px) ^ 2 + (y - py) ^ 2 < K.NEAR_R2 and abs(z - cueZ) < K.Z_TOL then
                balls[#balls + 1] = { obj = o.obj, model = o.model, x = x, y = y, z = z }
            end
        end
    end
    return cue, cueX, cueY, cueZ, best, sqrt(bestD), balls, stick
end

--------------------------------------------------------------------------------
-- KALIBRACJA BAND (detekcja odbic)
--------------------------------------------------------------------------------
local function detectWall(a, b, c, d, ax)
    local ot = 3 - ax
    local vin  = sqrt((b[1] - a[1]) ^ 2 + (b[2] - a[2]) ^ 2)
    local vout = sqrt((d[1] - c[1]) ^ 2 + (d[2] - c[2]) ^ 2)
    if vin < 0.004 or vout < 0.004 then return nil end
    local inN, outN = b[ax] - a[ax], d[ax] - c[ax]
    if inN * outN >= 0 then return nil end
    local inT, outT = b[ot] - a[ot], d[ot] - c[ot]
    if abs(inT - outT) >= 0.3 * vin then return nil end
    local cx, cy = lineCross(a[1], a[2], b[1], b[2], c[1], c[2], d[1], d[2])
    if not cx then return nil end
    local w = ax == 1 and cx or cy
    local half = ax == 1 and TBL.HX or TBL.HY
    if abs(abs(w) - half) >= 0.05 then return nil end         -- 0.15 przepuszczalo zderzenia z bilami (np. -0.388)
    local lo, hi = min(b[ax], c[ax]) - 0.005, max(b[ax], c[ax]) + 0.005
    if w < lo or w > hi then return nil end
    return w
end

local function median(t)
    local c = {}
    for i, v in ipairs(t) do c[i] = v end
    table.sort(c)
    return c[math.ceil(#c / 2)]
end

local CAL_DIRTY = false

-- Pomiary band z odbic: gdy po obu stronach osi sa 3+ zgodne pomiary (rozrzut < 3 cm), stol sam sie koryguje.
local function autoCal()
    local function axis(pos, neg)
        if #pos < 3 or #neg < 3 then return nil end
        local function spread(t)
            local lo, hi = huge, -huge
            for _, v in ipairs(t) do lo, hi = min(lo, v), max(hi, v) end
            return hi - lo
        end
        if spread(pos) > 0.03 or spread(neg) > 0.03 then return nil end
        local mp, mn = median(pos), median(neg)
        return (mp - mn) / 2, (mp + mn) / 2
    end
    local changed = false
    local hx, ox = axis(CAL.xp, CAL.xn)
    if hx and hx > 0.2 then
        TBL.HX, TBL.OFF_X = hx, TBL.OFF_X + ox
        CAL.xp, CAL.xn, changed = {}, {}, true
    end
    local hy, oy = axis(CAL.yp, CAL.yn)
    if hy and hy > 0.4 then
        TBL.HY, TBL.OFF_Y = hy, TBL.OFF_Y + oy
        CAL.yp, CAL.yn, changed = {}, {}, true
    end
    if changed then
        rebuildPockets()
        CAL_DIRTY = true
        A.log('bilard', fmt('stol skalibrowany z odbic: HX %.4f HY %.4f, srodek %+.4f %+.4f', TBL.HX, TBL.HY, TBL.OFF_X, TBL.OFF_Y))
    end
end

local function trackBall(handle, lx, ly, isCue)
    local t = TRK[handle]
    if not t then t = {}; TRK[handle] = t end
    local last = t[#t]
    if last and (lx - last[1]) ^ 2 + (ly - last[2]) ^ 2 < 1e-10 then return end
    t[#t + 1] = { lx, ly }
    if #t > 4 then table.remove(t, 1) end
    if #t < 4 or not CAL.on then return end
    for ax = 1, 2 do
        local w = detectWall(t[1], t[2], t[3], t[4], ax)
        if w then
            local list
            if ax == 1 then list = w > 0 and CAL.xp or CAL.xn else list = w > 0 and CAL.yp or CAL.yn end
            list[#list + 1] = w
            if isCue then REC.bouncedAny = true end
            A.log('bilard', fmt('[cal] banda %s %s: %.4f', ax == 1 and 'X' or 'Y', w > 0 and '+' or '-', w))
            autoCal()
        end
    end
end

--------------------------------------------------------------------------------
-- REKORDER STRZALU (uczenie fizyki)
--------------------------------------------------------------------------------
local function recStart(balls, cx, cy, now)
    REC.phase, REC.t0 = 1, now
    REC.power = POWER.released or POWER.value
    REC.speedDone, REC.maxStep, REC.win, REC.bad = false, 0, 0, false
    REC.prevPos, REC.tgtHandle = { cx, cy }, nil
    REC.freeDone, REC.free, REC.freeS, REC.freePrev = false, {}, 0, { cx, cy }
    REC.bouncedAny, REC.stillSince, REC.prevPos3 = false, nil, nil
    TRK = {}
    REC.p0 = {}
    for _, b in ipairs(balls) do REC.p0[b.obj] = { b.lx, b.ly } end
end

local function recIdle(balls, cx, cy, what, dist, ball, ax, ay, live, now)
    local aimedRecently = live or (AIMING.lastOff and now - AIMING.lastOff < K.AIM_GRACE)
    local cs = REC.cueStart
    if cs and (cx - cs[1]) ^ 2 + (cy - cs[2]) ^ 2 > K.SHOT_START2 then
        if aimedRecently and REC.pred then recStart(balls, cx, cy, now) else REC.cueStart = { cx, cy } end
        return
    end
    REC.cueStart = { cx, cy }
    if not live then return end
    if ball then
        REC.pred = { handle = ball.obj, num = BALL_NUM[ball.model], bx = ball.lx, by = ball.ly,
            cx = cx + ax * dist, cy = cy + ay * dist, what = what }
    else
        REC.pred = { what = what, cx = cx + ax * dist, cy = cy + ay * dist }
    end
end

-- swobodny odcinek bialej: s(u) = v0*u - acc*u^2/2 (najmniejsze kwadraty)
local function recFree(cx, cy, now)
    local fp = REC.freePrev
    local dx, dy = cx - fp[1], cy - fp[2]
    REC.freeS = REC.freeS + sqrt(dx * dx + dy * dy)
    fp[1], fp[2] = cx, cy
    local el = now - REC.t0
    REC.free[#REC.free + 1] = { el, REC.freeS }
    if not ((el > 0.15 and (REC.tgtHandle or REC.bouncedAny)) or el > 1.6 or REC.bad) then return end
    REC.freeDone = true

    local pw = REC.power or 0
    if #REC.free >= 12 and REC.freeS > 0.20 and el > 0.35 and pw > 2 and not REC.bad then
        local Suu, Suw, Sww, Sus, Sws = 0, 0, 0, 0, 0
        for _, pt in ipairs(REC.free) do
            local u, w = pt[1], -pt[1] * pt[1] / 2
            Suu, Suw, Sww = Suu + u * u, Suw + u * w, Sww + w * w
            Sus, Sws = Sus + u * pt[2], Sws + w * pt[2]
        end
        local det = Suu * Sww - Suw * Suw
        if abs(det) > 1e-12 then
            local v0  = (Sus * Sww - Suw * Sws) / det
            local acc = (Suu * Sws - Suw * Sus) / det
            if v0 > 0.05 and acc > 0.10 and acc < 3.0 then
                local D = v0 * v0 / (2 * acc)
                pushSample(POWER.distSamples, { pw, D, v0, acc })
                note('{FFC107}', '[dist] sila %.1f%% -> v0 %.3f, hamowanie %.3f, droga %.3f (pomiarow %d)',
                    pw, v0, acc, D, #POWER.distSamples)
            else
                A.log('bilard', fmt('[dist] odrzucony: v0 %.3f, hamowanie %.3f', v0, acc))
            end
        end
    end
end

local function recSpeed(cx, cy, now)
    local pp = REC.prevPos
    local dx, dy = cx - pp[1], cy - pp[2]
    local sd = sqrt(dx * dx + dy * dy)
    if sd > 0.25 then REC.bad = true end
    REC.win = REC.win + sd
    if sd > REC.maxStep then REC.maxStep = sd end
    pp[1], pp[2] = cx, cy
    local elapsed = now - REC.t0
    if elapsed <= 0.25 then return end
    REC.speedDone = true
    local v = REC.win / elapsed
    if REC.bad or v > 8.0 or REC.maxStep < 1e-4 then
        A.log('bilard', fmt('[speed] odrzucony: %.3f j/s, krok %.4f%s', v, REC.maxStep, REC.bad and ' (teleport)' or ''))
    else
        pushSample(POWER.speedSamples, { REC.power or 0, v, REC.maxStep })
        note('{FFC107}', '[speed] sila %.1f%% -> %.3f j/s, krok %.4f (pomiarow %d)',
            REC.power or 0, v, REC.maxStep, #POWER.speedSamples)
    end
end

local function recWaitHit(balls, now)
    for _, b in ipairs(balls) do
        local s0 = REC.p0[b.obj]
        if s0 and (b.lx - s0[1]) ^ 2 + (b.ly - s0[2]) ^ 2 > 0.0002 then
            REC.tgtHandle, REC.tgtNum, REC.tgtStart, REC.phase = b.obj, BALL_NUM[b.model], s0, 2
            return
        end
    end
    if now - REC.t0 > 3.0 then REC.phase = 3 end
end

local function recTrackTarget(balls, now)
    local cur
    for _, b in ipairs(balls) do
        if b.obj == REC.tgtHandle then cur = b; break end
    end
    if cur then
        local dx, dy = cur.lx - REC.tgtStart[1], cur.ly - REC.tgtStart[2]
        if dx * dx + dy * dy > 0.0025 then
            local fact = bearing(dx, dy)
            local pr = REC.pred
            if pr and pr.handle then
                local predAng = bearing(pr.bx - pr.cx, pr.by - pr.cy)
                note('{99CCFF}', '[shot] bila %s%s: przew %.1f, fakt %.1f, blad %+.1f',
                    tostring(REC.tgtNum), pr.handle == REC.tgtHandle and '' or fmt(' (czekalismy na %s)', tostring(pr.num)),
                    predAng, fact, wrap180(fact - predAng))
            end
            REC.phase = 3
            return
        end
    end
    if now - REC.t0 > 3.0 then REC.phase = 3 end
end

local function recSettle(cx, cy, now)
    local pv = REC.prevPos3
    if pv and (cx - pv[1]) ^ 2 + (cy - pv[2]) ^ 2 < 3.6e-7 then
        REC.stillSince = REC.stillSince or now
    else
        REC.stillSince = nil
    end
    REC.prevPos3 = { cx, cy }
    if (REC.stillSince and now - REC.stillSince > 0.5) or now - REC.t0 > 8.0 then
        REC.phase, REC.cueStart = 0, { cx, cy }
    end
end

local function recUpdate(balls, cx, cy, what, dist, ball, ax, ay, live)
    local now = clock()
    if REC.phase == 0 then return recIdle(balls, cx, cy, what, dist, ball, ax, ay, live, now) end
    if not REC.freeDone then recFree(cx, cy, now) end
    if not REC.speedDone then recSpeed(cx, cy, now) end
    if REC.phase == 1 then recWaitHit(balls, now)
    elseif REC.phase == 2 then recTrackTarget(balls, now)
    else recSettle(cx, cy, now) end
end

--------------------------------------------------------------------------------
-- RENDER
--------------------------------------------------------------------------------
local function camUpdate()
    local cx, cy, cz = getActiveCameraCoordinates()
    local px, py, pz = getActiveCameraPointAt()
    local fx, fy, fz = px - cx, py - cy, pz - cz
    local l = sqrt(fx * fx + fy * fy + fz * fz)
    if l < 1e-6 then Cam.ok = false; return end
    Cam.x, Cam.y, Cam.z = cx, cy, cz
    Cam.fx, Cam.fy, Cam.fz = fx / l, fy / l, fz / l
    Cam.ok = true
end

local function worldToScreen(x, y, z)
    if not Cam.ok then return nil end
    if (x - Cam.x) * Cam.fx + (y - Cam.y) * Cam.fy + (z - Cam.z) * Cam.fz < 0.02 then return nil end
    local sx, sy = convert3DCoordsToScreen(x, y, z)
    if not sx then return nil end
    return sx, sy
end

local function line3D(x1, y1, x2, y2, z, color, width)
    local ax, ay = worldToScreen(x1, y1, z)
    if not ax then return end
    local bx, by = worldToScreen(x2, y2, z)
    if bx then renderDrawLine(ax, ay, bx, by, width or 2, color) end
end

local UNIT = {}
local function unitCircle(seg)
    local u = UNIT[seg]
    if not u then
        u = {}
        for i = 0, seg do
            local a = i / seg * math.pi * 2
            u[i] = { math.cos(a), math.sin(a) }
        end
        UNIT[seg] = u
    end
    return u
end

local function lineLocal(x1, y1, x2, y2, z, color, width)
    local ax, ay = Frame:toWorld(x1, y1)
    local bx, by = Frame:toWorld(x2, y2)
    line3D(ax, ay, bx, by, z, color, width)
end

local function circleLocal(lx, ly, z, r, color, seg)
    seg = seg or 16
    local u = unitCircle(seg)
    local px, py
    for i = 0, seg do
        local x, y = Frame:toWorld(lx + u[i][1] * r, ly + u[i][2] * r)
        if px then line3D(px, py, x, y, z, color, 1) end
        px, py = x, y
    end
end

local function pathLocal(x1, y1, x2, y2, z, color, r)
    if not CFG.wide then return lineLocal(x1, y1, x2, y2, z, color, 2) end
    local dx, dy = x2 - x1, y2 - y1
    local l = sqrt(dx * dx + dy * dy)
    if l < 1e-6 then return end
    local rr = r or CFG.ballR
    local nx, ny = -dy / l * rr, dx / l * rr
    lineLocal(x1 + nx, y1 + ny, x2 + nx, y2 + ny, z, color, 2)
    lineLocal(x1 - nx, y1 - ny, x2 - nx, y2 - ny, z, color, 2)
    lineLocal(x1, y1, x2, y2, z, (color % 0x1000000) + 0x40000000, 1)
end

local function drawRail(z)
    local c = { {-TBL.HX, -TBL.HY}, {TBL.HX, -TBL.HY}, {TBL.HX, TBL.HY}, {-TBL.HX, TBL.HY} }
    for i = 1, 4 do
        local a, b = c[i], c[i % 4 + 1]
        lineLocal(a[1], a[2], b[1], b[2], z, 0x5000BFFF, 1)
    end
    for _, p in ipairs(TBL.POCKETS) do circleLocal(p[1], p[2], z, TBL.POCKET_R, 0x8000BFFF, 12) end
    lineLocal(0, 0, 0, TBL.HY * 0.35, z, 0xC0FFFF00, 2)
    lineLocal(0, 0, TBL.HX * 0.35, 0, z, 0xC0FF4040, 2)
end

--------------------------------------------------------------------------------
-- TRASOWANIE
--------------------------------------------------------------------------------
local function rayCircle(x, y, dx, dy, cx, cy, r)
    local fx, fy = x - cx, y - cy
    local b = fx * dx + fy * dy
    local c = fx * fx + fy * fy - r * r
    local disc = b * b - c
    if disc < 0 then return nil end
    local sq = sqrt(disc)
    local t1, t2 = -b - sq, -b + sq
    if t1 > 1e-5 then return t1 end
    if t2 > 1e-5 then return t2 end
    return nil
end

local function nearestBall(x, y, dx, dy, balls, skip, minChord, skipped)
    local bt, bb, bc = huge, nil, 0
    local D = CFG.ballR * 2
    for _, b in ipairs(balls) do
        if b ~= skip then
            local t = rayCircle(x, y, dx, dy, b.lx, b.ly, D)
            if t then
                local ox, oy = b.lx - x, b.ly - y
                local perp = abs(ox * dy - oy * dx)
                local r2 = D * D - perp * perp
                local chord = r2 > 0 and 2 * sqrt(r2) or 0
                if minChord and chord < minChord then
                    if skipped then skipped[#skipped + 1] = b end
                elseif t < bt then
                    bt, bb, bc = t, b, chord
                end
            end
        end
    end
    return bt, bb, bc
end

local function nearestPocket(x, y, dx, dy)
    local bt, bp = huge, nil
    for _, p in ipairs(TBL.POCKETS) do
        local t = rayCircle(x, y, dx, dy, p[1], p[2], TBL.POCKET_R)
        if t and t < bt then bt, bp = t, p end
    end
    if not bp then return bt, nil, 0 end
    local ox, oy = bp[1] - x, bp[2] - y
    local perp = abs(ox * dy - oy * dx)
    local r2 = TBL.POCKET_R * TBL.POCKET_R - perp * perp
    return bt, bp, r2 > 0 and 2 * sqrt(r2) or 0
end

local function traceBall(x, y, dx, dy, balls, skip, depth, z, color, budget)
    local step = (CFG.discrete and stepTrusted()) and stepFromPower(POWER.value) or 0
    local minChord = step > 1e-4 and step or nil
    if depth == 0 then SKIPPED = {} end
    local firstWhat, firstDist = nil, 0
    local traveled = 0

    for seg = 1, CFG.maxBounces + 1 do
        local skipped = {}
        local tb, hitBall = nearestBall(x, y, dx, dy, balls, skip, minChord, skipped)
        local tp, pocket, pchord = nearestPocket(x, y, dx, dy)
        local tw, axis = distToRail(x, y, dx, dy)
        local t = min(tb, tp, tw)

        for _, b in ipairs(skipped) do
            circleLocal(b.lx, b.ly, z, CFG.ballR, 0xC0FF3D00, 12)
            circleLocal(b.lx, b.ly, z, CFG.ballR * 0.5, 0xC0FF3D00, 8)
            if depth == 0 then SKIPPED[#SKIPPED + 1] = b end
        end

        local ex, ey = x + dx * t, y + dy * t
        if budget and budget < t and budget > 0 then
            local sx2, sy2 = x + dx * budget, y + dy * budget
            pathLocal(x, y, sx2, sy2, z, color)
            pathLocal(sx2, sy2, ex, ey, z, 0x30FFFFFF)
            circleLocal(sx2, sy2, z, CFG.ballR, color, 12)
            if not firstWhat then firstWhat, firstDist = 'nie dojedzie', traveled + budget end
        else
            pathLocal(x, y, ex, ey, z, color)
        end
        traveled = traveled + t

        if t == tp then
            local col, what = COL_POCKET, WHAT_POCKET
            if minChord and pchord < step then col, what = 0xFFFF3D00, WHAT_POCKET .. ' (przeskoczy)'
            elseif minChord and pchord < step * 1.6 then col, what = 0xFFFFC107, WHAT_POCKET .. ' (na styk)' end
            circleLocal(pocket[1], pocket[2], z, TBL.POCKET_R, col, 14)
            return firstWhat or what, firstDist ~= 0 and firstDist or traveled, nil
        end

        if t == tb then
            if depth >= CFG.maxDepth then return firstWhat or 'bila', traveled, hitBall end
            -- bile skacza o krok fizyki: dosun punkt styku do wielokrotnosci kroku
            if minChord and depth == 0 then
                local tNear = (hitBall.lx - x) * dx + (hitBall.ly - y) * dy
                local tAdj = math.ceil(t / step) * step
                if tAdj > tNear then tAdj = tNear end
                if tAdj > t then
                    lineLocal(ex, ey, x + dx * tAdj, y + dy * tAdj, z, 0x60FF3D00, 1)
                    ex, ey = x + dx * tAdj, y + dy * tAdj
                    traveled = traveled + (tAdj - t)
                end
            end
            circleLocal(ex, ey, z, CFG.ballR, COL_GHOST, 14)

            local nx, ny = hitBall.lx - ex, hitBall.ly - ey
            local nl = sqrt(nx * nx + ny * ny)
            if nl < 1e-6 then return 'bila', traveled, hitBall end
            nx, ny = nx / nl, ny / nl
            local vn = dx * nx + dy * ny
            if vn <= 1e-6 then return 'bila', traveled, hitBall end

            local rem = budget and max(0, budget - traveled) or nil
            local wT, dT = traceBall(hitBall.lx, hitBall.ly, nx, ny, balls, hitBall, depth + 1, z,
                depth == 0 and COL_TARGET or COL_CHAIN, rem and rem * vn * vn)
            if depth == 0 then
                REQ.valid = seg == 1 and type(wT) == 'string' and wT:find(WHAT_POCKET, 1, true) ~= nil
                REQ.len, REQ.cos2, REQ.dc = dT or 0, vn * vn, traveled
            end
            local tx, ty = dx - nx * vn, dy - ny * vn
            local tl = sqrt(tx * tx + ty * ty)
            if tl > 1e-4 then
                traceBall(ex, ey, tx / tl, ty / tl, balls, hitBall, depth + 1, z, 0x70FFFFFF, rem and rem * (1 - vn * vn))
            end
            return 'bila', traveled, hitBall
        end

        if not firstWhat then firstWhat, firstDist = 'banda', traveled end
        if budget then budget = max(0, (budget - t) * CFG.railE * CFG.railE) end
        x, y = ex, ey
        if axis == 'x' then dx = -dx else dy = -dy end
        skip = nil
    end
    return firstWhat or 'banda', firstDist ~= 0 and firstDist or traveled, nil
end

--------------------------------------------------------------------------------
-- HUD (wzgledem BX, BY)
--------------------------------------------------------------------------------
local function placeHud()
    BX, BY = A.hudPlace('pool', 430, 100, 30 / A.sw, 300 / A.sh)
end

local function textTop(msg)
    if FONT and A.drawOk then
        placeHud()
        renderFontDrawText(FONT, msg, BX, BY, 0xFFFF3D00)
    end
end

local function drawPowerPanel()
    local f, p = FONT, POWER.value
    local need
    if REQ.valid and REQ.cos2 > 0.02 then
        need = powerFromDist(REQ.dc + REQ.len / REQ.cos2)
        if need then need = max(0, min(100, need)) end
    end
    REQ.power = need

    local needTxt = ''
    if need then needTxt = fmt('   trzeba ~%.0f%%', need)
    elseif REQ.valid then needTxt = fmt('   trzeba: za malo pomiarow (%d)', #POWER.distSamples) end
    local y = BY + 28
    renderFontDrawText(f, fmt('POWER %5.1f%%%s%s', p, needTxt, POWER.charging and '   <<<' or ''), BX, y, 0xFFFFFFFF)
    renderDrawBox(BX, y + 16, 134, 7, 0x50000000)
    renderDrawBox(BX, y + 16, 134 * p / 100, 7, p > 66 and 0xFFFF3D00 or 0xFF00E676)
    y = y + 30
    if need then
        renderDrawBox(BX + 134 * need / 100 - 1, y - 17, 2, 13, 0xFFFFFF00)
        local rate = POWER.rate or 0
        local pred = p + rate * POWER.lead
        local tol = max(2.0, abs(rate) * 0.05)
        if POWER.charging and abs(pred - need) < tol then
            renderFontDrawText(f, '{00E676}>>> PUSC <<<', BX, y, 0xFFFFFFFF)
            y = y + 14
        elseif POWER.charging and rate ~= 0 then
            local togo = (need - pred) / rate
            if togo > 0 and togo < 5 then
                renderFontDrawText(f, fmt('za %.2f s', togo), BX, y, 0xFFB0B0B0)
                y = y + 14
            end
        end
    end
    if POWER.released then
        renderFontDrawText(f, fmt('ostatnie uderzenie: %.1f%%', POWER.released), BX, y, 0xFFB0B0B0)
        y = y + 14
    end
    if #SKIPPED > 0 then
        renderFontDrawText(f, fmt('{FF3D00}fizyka przeskoczy %d bil: cieciwa < krok %.4f',
            #SKIPPED, stepFromPower(POWER.value)), BX, y, 0xFFFFFFFF)
    end
end

local function drawDebug(lx, ly, tblDist, what, dist, firstBall, nBalls)
    renderFontDrawText(FONT, fmt('cel %.2f deg (zr %d)  b %s  c %s  bil %d  styk: %s %.3f m%s',
        AIM.use, AIM.src,
        AIM.hasB and fmt('%+.2f', wrap180(AIM.b - AIM.a)) or '-',
        AIM.hasC and fmt('%+.2f', wrap180(AIM.c - AIM.a)) or '-',
        nBalls, what, dist, firstBall and fmt(' (bila %d)', BALL_NUM[firstBall.model] or -1) or ''),
        BX, BY, 0xFFFFFFFF)
    renderFontDrawText(FONT, fmt('biala lok. (%.4f, %.4f)   stol %.2f m, obrot %.1f deg (%s)',
        lx, ly, tblDist or -1, Frame.angle, Frame.src), BX, BY + 14, 0xFFFFFFFF)
end

--------------------------------------------------------------------------------
-- GLOWNA KLATKA
--------------------------------------------------------------------------------
-- surowy kierunek zrodla i (1 kij, 2 kamera, 3 postac, 4 gracz->biala)
local function srcRaw(i)
    if i == 1 then return AIM.hasC and AIM.c or nil end
    if i == 2 then return AIM.hasCam and AIM.cam or nil end
    if i == 3 then return AIM.a end
    if i == 4 then return AIM.hasB and AIM.b or nil end
end

-- stala poprawka zrodla = mediana znakowanych bledow (od 3 uderzen), jakosc = mediana |bledu|
local function srcOffset(i)
    local e = AIMERR[i]
    if not e or #e < 3 then return 0 end
    local m = median(e)
    return abs(m) < 20 and m or 0
end

local function srcQuality(i)
    local e = AIMERR[i]
    if not e or #e < 3 then return nil end
    local t = {}
    for k, v in ipairs(e) do t[k] = abs(v) end
    return median(t)
end

local function updateAim(heading, px, py, bx, by, stick)
    AIM.a = heading % 360
    local pdx, pdy = bx - px, by - py
    local pl = sqrt(pdx * pdx + pdy * pdy)
    AIM.hasB = pl > 0.3
    if AIM.hasB then AIM.b = bearing(pdx / pl, pdy / pl) end
    AIM.hasC = false
    if stick then
        local _, _, sfx, sfy = objAxes(stick.obj)
        if sfx then
            if CFG.stickFlip then sfx, sfy = -sfx, -sfy end
            AIM.c, AIM.hasC = bearing(sfx, sfy), true
        end
    end
    -- kamera patrzy wzdluz kierunku uderzenia (widok zza kija): najpewniejsze zrodlo, gdy kija nie widac
    AIM.hasCam = false
    local okc, cx, cy = pcall(getActiveCameraCoordinates)
    local oka, ax, ay = pcall(getActiveCameraPointAt)
    if okc and oka and cx and ax then
        local dx, dy = ax - cx, ay - cy
        local l = sqrt(dx * dx + dy * dy)
        if l > 0.05 then AIM.cam, AIM.hasCam = bearing(dx / l, dy / l), true end
    end

    local pick = CFG.aimSrc
    if pick < 1 or pick > 4 or srcRaw(pick) == nil then
        -- auto: zrodlo o najmniejszym bledzie z dotychczasowych uderzen; bez danych: kij, kamera, postac
        pick = 0
        local bestQ
        for i = 1, 4 do
            local q = srcRaw(i) ~= nil and srcQuality(i) or nil
            if q and q < 25 and (not bestQ or q < bestQ) then pick, bestQ = i, q end
        end
        if pick == 0 then pick = srcRaw(1) and 1 or 3 end
    end
    AIM.src = pick
    AIM.use, AIM.ok = (srcRaw(pick) + srcOffset(pick)) % 360, true
end

local function watchShot(bx, by)
    local now = clock()
    if not SHOT.ready then SHOT.ready, SHOT.sx, SHOT.sy = true, bx, by end
    local ourAim = AIMING.on or (AIMING.lastOff and now - AIMING.lastOff < K.AIM_GRACE)
    local moved = (bx - SHOT.sx) ^ 2 + (by - SHOT.sy) ^ 2
    if not SHOT.moving then
        if moved > K.SHOT_START2 then
            if ourAim then SHOT.moving, SHOT.t0 = true, now else SHOT.sx, SHOT.sy, SHOT.snap = bx, by, nil end
        else
            SHOT.sx, SHOT.sy = bx, by
            SHOT.snap = { a = AIM.a, b = AIM.hasB and AIM.b or nil, c = AIM.hasC and AIM.c or nil, cam = AIM.hasCam and AIM.cam or nil }
        end
    elseif moved > K.SHOT_DONE2 or now - SHOT.t0 > K.SHOT_TIMEOUT then
        if moved > K.SHOT_DONE2 and SHOT.snap and now - SHOT.t0 < K.SHOT_WINDOW then
            local adx, ady = bx - SHOT.sx, by - SHOT.sy
            local al = sqrt(adx * adx + ady * ady)
            local fact = bearing(adx / al, ady / al)
            local sn = SHOT.snap
            local raw = { sn.c, sn.cam, sn.a, sn.b }
            local msg = fmt('[aim] fakt %.2f', fact)
            for i = 1, 4 do
                if raw[i] then
                    local err = wrap180(fact - raw[i])
                    local l = AIMERR[i]
                    l[#l + 1] = err
                    if #l > 12 then table.remove(l, 1) end
                    msg = msg .. fmt(' | %s %+.2f', SRC_NAME[i], err)
                end
            end
            msg = msg .. fmt(' | uzywane: %s', SRC_NAME[AIM.src] or '?')
            note('{99CCFF}', msg)
            SHOT.snap = nil
        end
        SHOT.moving, SHOT.sx, SHOT.sy = false, bx, by
    end
end

local function tableBalls(balls)
    local out = {}
    local mx, my = TBL.HX + K.TABLE_MARGIN, TBL.HY + K.TABLE_MARGIN
    for _, b in ipairs(balls) do
        b.lx, b.ly = Frame:toLocal(b.x, b.y)
        if abs(b.lx) < mx and abs(b.ly) < my then
            out[#out + 1] = b
            if not BALL_NUM[b.model] and not SEEN_MODELS[b.model] then
                SEEN_MODELS[b.model] = true
                A.log('bilard', 'na stole obiekt z modelem ' .. b.model .. ', nie ma go na liscie bil')
            end
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- PLANER: najlepsze zagranie (bila biala -> kula -> luza)
-- Dla kazdej pary (kula, luza) liczymy "bile-widmo" G: pozycje bialej w chwili zetkniecia, po ktorej kula
-- poleci dokladnie do luzy. Zagranie jest mozliwe, gdy droga bialej do G i droga kuli do luzy sa wolne, a kat
-- ciecia nie jest zbyt ostry. Moc z kalibracji: droga bialej + droga kuli / cos^2 (jak przy torze).
--------------------------------------------------------------------------------
local RM = { down = false, t0 = 0 }
local PLAN = nil
local AUTO = { down = false, since = 0, lastShot = -1e9, alignedSince = nil }

local function segDist(px, py, x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    local l2 = dx * dx + dy * dy
    if l2 < 1e-12 then return sqrt((px - x1) ^ 2 + (py - y1) ^ 2) end
    local t = max(0, min(1, ((px - x1) * dx + (py - y1) * dy) / l2))
    return sqrt((px - (x1 + t * dx)) ^ 2 + (py - (y1 + t * dy)) ^ 2)
end

local function pathClear(x1, y1, x2, y2, balls, skip, minD)
    for _, b in ipairs(balls) do
        if b ~= skip and segDist(b.lx, b.ly, x1, y1, x2, y2) < minD then return false end
    end
    return true
end

local function planShot(cx, cy, balls)
    local R2 = CFG.ballR * 2
    local best
    for _, t in ipairs(balls) do
        for _, pk in ipairs(TBL.POCKETS) do
            local pdx, pdy = pk[1] - t.lx, pk[2] - t.ly
            local pl = sqrt(pdx * pdx + pdy * pdy)
            if pl > 1e-3 then
                local ux, uy = pdx / pl, pdy / pl
                local gx, gy = t.lx - ux * R2, t.ly - uy * R2
                if abs(gx) < TBL.HX - CFG.ballR and abs(gy) < TBL.HY - CFG.ballR then
                    local cdx, cdy = gx - cx, gy - cy
                    local cl = sqrt(cdx * cdx + cdy * cdy)
                    if cl > 1e-3 then
                        local dx, dy = cdx / cl, cdy / cl
                        local cos = dx * ux + dy * uy
                        if cos > 0.3 and pathClear(cx, cy, gx, gy, balls, t, R2 * 0.97)
                            and pathClear(t.lx, t.ly, pk[1], pk[2], balls, t, R2 * 0.97) then
                            local score = cl + pl + (1 - cos) * 1.5 + (BALL_NUM[t.model] == 8 and 0.6 or 0)
                            if not best or score < best.score then
                                best = { score = score, t = t, p = pk, gx = gx, gy = gy, dx = dx, dy = dy, cl = cl, pl = pl, cos = cos }
                            end
                        end
                    end
                end
            end
        end
    end
    if not best then return nil end
    best.cx, best.cy = cx, cy
    local wx1, wy1 = Frame:toWorld(cx, cy)
    local wx2, wy2 = Frame:toWorld(best.gx, best.gy)
    best.heading = bearing(wx2 - wx1, wy2 - wy1)
    local need = powerFromDist(best.cl + best.pl / (best.cos * best.cos))
    best.power = need and max(0, min(100, need)) or nil
    return best
end

local function rmb(down)
    pcall(function() A.ffi.C.mouse_event(down and 0x0008 or 0x0010, 0, 0, 0, 0) end)   -- RIGHTDOWN / RIGHTUP
end

local function drawPlan(bz)
    local pl = PLAN
    if not pl then return end
    circleLocal(pl.gx, pl.gy, bz, CFG.ballR, 0xFFFF66FF, 14)                       -- gdzie ma byc biala w chwili uderzenia
    lineLocal(pl.cx, pl.cy, pl.gx, pl.gy, bz, 0xA0FF66FF, 1)
    lineLocal(pl.t.lx, pl.t.ly, pl.p[1], pl.p[2], bz, 0xFFFF66FF, 2)               -- droga kuli do luzy
    circleLocal(pl.p[1], pl.p[2], bz, TBL.POCKET_R, 0xFFFF66FF, 14)
end

-- auto celowanie (obraca postac) i auto strzal (przytrzymuje PPM i puszcza przy wyliczonej mocy)
-- Obrot celownika ruchem myszy: serwer sam ustawia kierunek postaci co klatke, wiec setCharHeading nic nie daje
-- (i wirowal postacia). Mierzymy, o ile stopni obraca 1 px, i dobieramy kroki; brak reakcji = wylaczamy.
local ROT = { g = nil, lastU = nil, lastDx = 0, nextAt = 0, fails = 0, steps = 0, e0 = 0, planT = nil, locked = false }

local function mouseMoveX(dx)
    local v = dx < 0 and dx + 4294967296 or dx
    pcall(function() A.ffi.C.mouse_event(0x0001, v, 0, 0, 0) end)       -- MOUSEEVENTF_MOVE
end

local function autoRotate(pl, now, e)
    if now < ROT.nextAt then return end
    ROT.nextAt = now + 0.06
    if ROT.lastU and ROT.lastDx ~= 0 then
        local moved = wrap180(AIM.use - ROT.lastU)
        if abs(moved) > 0.01 then
            local g = moved / ROT.lastDx
            ROT.g = ROT.g and (ROT.g * 0.5 + g * 0.5) or g
            ROT.fails = 0
        else
            ROT.fails = ROT.fails + 1
            if ROT.fails >= 12 then
                CFG.autoAim, ROT.fails, ROT.lastDx = false, 0, 0
                CAL_DIRTY = true
                note('{FF8888}', '[plan] ruch myszy nie obraca kierunku celowania - auto celowanie wylaczone')
                return
            end
        end
    end
    ROT.lastU = AIM.use
    ROT.steps = ROT.steps + 1
    if ROT.steps > 60 and abs(e) > ROT.e0 * 0.8 and abs(e) > 1 then                    -- brak postepu = nie kreci sie w dobra strone
        CFG.autoAim, ROT.steps, ROT.lastDx = false, 0, 0
        CAL_DIRTY = true
        note('{FF8888}', '[plan] celownik nie zbliza sie do celu - auto celowanie wylaczone')
        return
    end
    if abs(e) < 0.25 then
        if not ROT.locked then
            ROT.locked = true
            A.log('bilard', fmt('auto celowanie: wyrownano (blad %.2f, %.3f deg/px)', e, ROT.g or 0))
        end
        ROT.lastDx = 0
        return
    end
    ROT.locked = false
    local dx
    if ROT.g and abs(ROT.g) > 0.004 then dx = e / ROT.g * 0.7 else dx = e > 0 and 6 or -6 end
    dx = max(-40, min(40, floor(dx + (dx > 0 and 0.5 or -0.5))))
    if dx == 0 then dx = e > 0 and 1 or -1 end
    mouseMoveX(dx)
    ROT.lastDx = dx
end

local function autoPlay(aiming, now)
    local pl = PLAN
    if not pl or not AIM.ok or A.menuOpen or not POWER.atTable then
        if AUTO.down then rmb(false); AUTO.down = false end
        AUTO.alignedSince = nil
        return
    end
    local e = wrap180(pl.heading - AIM.use)
    pl.err = e
    if CFG.autoAim and aiming and not AUTO.down and not RM.down then
        local planKey = tostring(pl.t.obj) .. ':' .. fmt('%.2f', pl.p[1]) .. fmt('%.2f', pl.p[2])      -- ta sama kula i luza = ten sam plan
        if ROT.planT ~= planKey then ROT.planT, ROT.steps, ROT.e0, ROT.locked = planKey, 0, abs(e), false end
        autoRotate(pl, now, e)
    end
    if abs(e) < 0.4 then AUTO.alignedSince = AUTO.alignedSince or now else AUTO.alignedSince = nil end
    if not CFG.autoShoot then
        if AUTO.down then rmb(false); AUTO.down = false end
        return
    end
    if not AUTO.down then
        if aiming and pl.power and AUTO.alignedSince and now - AUTO.alignedSince > 0.5 and now - AUTO.lastShot > 2.0 then
            rmb(true)
            AUTO.down, AUTO.since = true, now
        end
    else
        local rate = POWER.rate or 0
        local pred = POWER.value + rate * POWER.lead
        local tol = max(2.0, abs(rate) * 0.05)
        if (pl.power and abs(pred - pl.power) < tol) or now - AUTO.since > 8 or not pl.power then
            rmb(false)
            AUTO.down, AUTO.lastShot = false, now
            note('{FF66FF}', '[plan] uderzenie: moc %.0f%% (cel %.0f%%), kat %+.2f', POWER.value, pl.power or -1, e)
        end
    end
end

-- Moc z czasu przytrzymania PPM (gdy pasek mocy nie jest wykryty w textdrawach): PS % na sekunde.
-- Dziala tez dla PPM wcisnietego przez skrypt (auto strzal).
local PS = 50

local function rmbTrack(now)
    if POWER.tdId then return end
    if not POWER.atTable or A.menuOpen then
        if RM.down then RM.down, POWER.charging = false, false end
        return
    end
    POWER.rmbMode, POWER.rate = true, PS
    local d = isKeyDown(0x02)
    if d and not RM.down then
        RM.down, RM.t0 = true, now
        POWER.released, POWER.charging = nil, true
    end
    if RM.down then
        if d then
            POWER.value = min(100, (now - RM.t0) * PS)
            POWER.raw, POWER.lastUpdate = POWER.value, clock()
            AIMING.on = true
        else
            RM.down, POWER.charging = false, false
            if POWER.value > 3 then POWER.released = POWER.value end
            AIMING.on, AIMING.lastOff = false, clock()
        end
    end
end

-- DIAGNOSTYKA (Bilard -> Diagnostyka): do moonloader.log trafia, co sie zmienia na ekranie i wokol bialej
-- przy wciskaniu/puszczaniu PPM. Z tego da sie ustalic pasek mocy (textdraw), kij (obiekt) i zrodlo kierunku.
local DG = { prev = nil, nextAt = 0, rmb = false }
local DIAG_KEYS = { W = 0x57, A = 0x41, S = 0x53, D = 0x44, LEFT = 0x25, RIGHT = 0x27, UP = 0x26, DOWN = 0x28,
    LMB = 0x01, SHIFT = 0x10, CTRL = 0x11, SPACE = 0x20, Q = 0x51, E = 0x45 }

local function tdSnapshot()
    local snap = {}
    for id = 0, 2303 do
        if sampTextdrawIsExists(id) then
            local ok, text = pcall(sampTextdrawGetString, id)
            local okp, x, y = pcall(sampTextdrawGetPos, id)
            local okb, en, _, sx, sy = pcall(sampTextdrawGetBoxEnabledColorAndSize, id)
            snap[id] = fmt('"%s" @%.1f,%.1f%s', ok and tostring(text):gsub('[\r\n]', ' '):sub(1, 60) or '?', okp and x or -1, okp and y or -1,
                (okb and type(sx) == 'number') and fmt(' box %s %.1fx%.1f', tostring(en), sx, sy or 0) or '')
        end
    end
    return snap
end

local function diagTick(now, bx, by)
    local rd = isKeyDown(0x02)
    if rd ~= DG.rmb then
        DG.rmb = rd
        local okc, cx, cy = pcall(getActiveCameraCoordinates)
        local oka, ax, ay = pcall(getActiveCameraPointAt)
        local cam = (okc and oka and cx and ax) and bearing(ax - cx, ay - cy) or -1
        local keys = {}
        for name, vk in pairs(DIAG_KEYS) do if isKeyDown(vk) then keys[#keys + 1] = name end end
        local near = {}
        for _, o in ipairs(Scan.others) do
            local _, ox, oy = getObjectCoordinates(o.obj)
            local d = sqrt((ox - bx) ^ 2 + (oy - by) ^ 2)
            if d < 3.0 and #near < 10 then near[#near + 1] = fmt('%d(%.2fm)', o.model, d) end
        end
        A.log('bilard', fmt('[diag] PPM %s | postac %.1f | kamera %.1f | biala %.3f %.3f | klawisze %s | obiekty <3m: %s',
            rd and 'WCISNIETY' or 'PUSZCZONY', getCharHeading(PLAYER_PED), cam, bx or 0, by or 0,
            #keys > 0 and table.concat(keys, ',') or '-', #near > 0 and table.concat(near, ' ') or 'brak'))
    end
    if now < DG.nextAt then return end
    DG.nextAt = now + (rd and 0.15 or 1.0)
    local snap = tdSnapshot()
    local n = 0
    if DG.prev then
        for id, s in pairs(snap) do
            if DG.prev[id] ~= s and n < 12 then n = n + 1; A.log('bilard', fmt('[diag] td %d %s %s', id, DG.prev[id] and 'zmiana:' or 'nowy:', s)) end
        end
        for id in pairs(DG.prev) do
            if not snap[id] and n < 12 then n = n + 1; A.log('bilard', fmt('[diag] td %d zniknal', id)) end
        end
    else
        for id, s in pairs(snap) do
            if n < 60 then n = n + 1; A.log('bilard', fmt('[diag] td %d start: %s', id, s)) end
        end
    end
    DG.prev = snap
end

local function frame()
    local px, py = getCharCoordinates(PLAYER_PED)
    local heading = getCharHeading(PLAYER_PED)
    local fdx, fdy = fromBearing(heading)
    local cue, bx, by, bz, tbl, tblDist, balls, stick = findPool(px, py, fdx, fdy)
    POWER.atTable = cue ~= nil and (px - bx) ^ 2 + (py - by) ^ 2 <= K.AT_TABLE_R2
    if not POWER.atTable then return end

    if tbl then
        if not frameFromTable(tbl) and not Warn.heading then
            Warn.heading = true
            say('nie udalo sie okreslic obrotu stolu, licze ze nieobrocony')
        end
    else
        Frame.ok = false
    end
    if not Frame.ok then textTop('stol (2964) nie znaleziony'); return end

    updateAim(heading, px, py, bx, by, stick)
    watchShot(bx, by)
    if CFG.diag then pcall(diagTick, clock(), bx, by) end
    if not stick and clock() - (DIAG_AT or -1e9) > 60 then
        DIAG_AT = clock()
        local parts = {}
        for _, o in ipairs(Scan.others) do
            if not BALL_NUM[o.model] then
                local _, ox, oy = getObjectCoordinates(o.obj)
                local d = sqrt((ox - bx) ^ 2 + (oy - by) ^ 2)
                if d < 1.6 then parts[#parts + 1] = fmt('model %d (%.2f m)', o.model, d) end
            end
        end
        A.log('bilard', 'kij (model ' .. STICK_MODEL .. ') nie znaleziony, kierunek z: ' .. (SRC_NAME[AIM.src] or '?')
            .. '; obiekty przy bialej: ' .. (#parts > 0 and table.concat(parts, ', ') or 'brak'))
    end

    local lx, ly = Frame:toLocal(bx, by)
    local ldx, ldy = Frame:dirToLocal(fromBearing(AIM.use))
    balls = tableBalls(balls)

    local aiming = AIMING.on or AIMING.force
    if aiming or REC.phase > 0 then
        trackBall(cue, lx, ly, true)
        for _, b in ipairs(balls) do trackBall(b.obj, b.lx, b.ly, false) end
    elseif next(TRK) then
        TRK = {}
    end

    REQ.valid = false
    if not AIM.ok then textTop('kij nie znaleziony, kierunek nieznany'); return end

    local draw = A.drawOk
    local what, dist, firstBall = '-', 0, nil
    if aiming and draw then
        camUpdate()
        if CFG.rail then drawRail(bz) end
        for _, b in ipairs(balls) do circleLocal(b.lx, b.ly, bz, CFG.ballR * 0.25, 0xA0FFFFFF, 6) end
        local budget
        local dAcc, dN = decelMedian()
        if dAcc and dN >= 4 then budget = distFromPower(POWER.value) end
        what, dist, firstBall = traceBall(lx, ly, ldx, ldy, balls, nil, 0, bz, COL_CUE, budget)
    end
    if CFG.plan or CFG.autoAim or CFG.autoShoot then
        PLAN = (#balls > 0) and planShot(lx, ly, balls) or nil
        if PLAN and aiming and draw and CFG.plan then drawPlan(bz) end
        autoPlay(aiming and (AIMING.on or not AIMING.seen), clock())
    else
        PLAN = nil
    end
    recUpdate(balls, lx, ly, what, dist, firstBall, ldx, ldy, AIMING.on)

    if FONT and draw and (aiming or CFG.hud) then
        placeHud()
        if aiming then drawPowerPanel() end
        if CFG.hud then drawDebug(lx, ly, tblDist, what, dist, firstBall, #balls) end
        if aiming and CFG.plan and PLAN then
            local pl = PLAN
            renderFontDrawText(FONT, fmt('{FF66FF}plan: bila %s do luzy, obrot %+.1f%s', tostring(BALL_NUM[pl.t.model] or '?'), pl.err or wrap180(pl.heading - AIM.use),
                pl.power and fmt(', moc ~%.0f%%', pl.power) or ', brak kalibracji mocy'), BX, BY + 96, 0xFFFFFFFF)
        elseif aiming and CFG.plan then
            renderFontDrawText(FONT, '{FF8888}plan: brak czystego zagrania', BX, BY + 96, 0xFFFFFFFF)
        end
    end
end

--------------------------------------------------------------------------------
-- PASEK SILY: textdrawy (samp.events albo odczyt)
--------------------------------------------------------------------------------
local evSeen = false

local function tdMatches(td, ref)
    local pos = td.position
    if type(pos) ~= 'table' or type(pos.x) ~= 'number' then return false end
    if abs(pos.x - ref.x) > ref.tol or abs(pos.y - ref.y) > ref.tol then return false end
    return type(td.text) == 'string' and td.text:find(ref.text, 1, true) ~= nil
end

local function onShowTextDraw(id, td)
    if type(td) ~= 'table' or type(td.lineWidth) ~= 'number' then return end
    if POWER.spy then
        local pos = td.position
        A.log('bilard', fmt('[spy] id=%d line=%.2f,%.2f pos=%.1f,%.1f text=%q', id, td.lineWidth,
            td.lineHeight or -1, pos and pos.x or -1, pos and pos.y or -1, tostring(td.text)))
    end

    local bar = tdMatches(td, TD_BAR)
    if bar or tdMatches(td, TD_LABEL) or tdMatches(td, TD_FRAME) then
        AIMING.ids[id], AIMING.seen = true, true
        if not AIMING.on then AIMING.on, AIMING.since = true, clock() end
    end

    if bar then
        local c = POWER.cands[id]
        if not c then
            c = { w = td.lineWidth, changes = 0 }
            POWER.cands[id] = c
        elseif abs(c.w - td.lineWidth) > 0.05 then
            c.changes, c.w = c.changes + 1, td.lineWidth
        end
        if c.changes >= 2 and POWER.tdId ~= id then
            POWER.tdId = id
            A.log('bilard', 'pasek sily: id=' .. id)
        end
        if POWER.tdId ~= id and c.changes == 0 and td.lineWidth > (POWER.bgWidth or 0) then
            POWER.bgId, POWER.bgWidth = id, td.lineWidth
            A.log('bilard', fmt('podklad: id=%d, skala 100%% = %.2f', id, td.lineWidth))
        end
    end

    if id == POWER.tdId then
        local w = td.lineWidth
        POWER.raw = w
        if not POWER.obsMax or w > POWER.obsMax then POWER.obsMax = w end
        local scale = POWER.bgWidth or POWER.scaleFallback
        if scale and scale > 0.5 then
            POWER.calibrated = true
            POWER.value = max(0, min(100, w / scale * 100))
        else
            POWER.calibrated = false
        end
        local now = clock()
        if POWER.rateT and scale and scale > 0.5 then
            local dt = now - POWER.rateT
            local dw = (w - (POWER.rateW or w)) / scale * 100
            if dt > 0.004 and dt < 0.5 and abs(dw) > 0.05 then
                local r = dw / dt
                if POWER.rate and POWER.rate * r > 0 then POWER.rate = POWER.rate * 0.6 + r * 0.4 else POWER.rate = r end
            end
        end
        POWER.rateT, POWER.rateW = now, w
        POWER.charging, POWER.released, POWER.lastUpdate = true, nil, now
    end
end

local function onTextDrawHide(id)
    if AIMING.ids[id] then
        AIMING.ids[id] = nil
        AIMING.on, AIMING.lastOff = false, clock()
    end
    if id == POWER.tdId and POWER.charging then
        POWER.charging, POWER.released = false, POWER.value
        if CFG.hud then say('uderzenie: sila %.1f%% (szerokosc %.2f)', POWER.released, POWER.raw) end
    end
end

-- odczyt textdrawow przez SF.lua (gdy samp.events nic nie daje)
local TDP = { known = {}, nextScan = 0 }
local function tdPollable()
    return type(sampTextdrawIsExists) == 'function' and type(sampTextdrawGetString) == 'function'
        and type(sampTextdrawGetPos) == 'function' and type(sampTextdrawGetBoxEnabledColorAndSize) == 'function'
end

local function tdRead(id)
    local text = sampTextdrawGetString(id)
    local x, y = sampTextdrawGetPos(id)
    local _, _, sx, sy = sampTextdrawGetBoxEnabledColorAndSize(id)
    return { text = text, position = { x = x, y = y }, lineWidth = sx, lineHeight = sy }
end

local function tdInteresting(td)
    return tdMatches(td, TD_BAR) or tdMatches(td, TD_LABEL) or tdMatches(td, TD_FRAME)
end

local function tdPoll(now)
    for id, last in pairs(TDP.known) do
        if not sampTextdrawIsExists(id) then
            TDP.known[id] = nil
            onTextDrawHide(id)
        else
            local td = tdRead(id)
            if td.lineWidth ~= last.w or td.text ~= last.text then
                last.w, last.text = td.lineWidth, td.text
                onShowTextDraw(id, td)
            end
        end
    end
    if now >= TDP.nextScan and POWER.atTable then
        TDP.nextScan = now + 1.0
        for id = 0, 2303 do
            if not TDP.known[id] and sampTextdrawIsExists(id) then
                local td = tdRead(id)
                if type(td.lineWidth) == 'number' and tdInteresting(td) then
                    TDP.known[id] = { w = td.lineWidth, text = td.text }
                    onShowTextDraw(id, td)
                end
            end
        end
    end
end

local function usePolling()
    if CFG.tdSource == 2 then return true end
    if CFG.tdSource == 1 then return false end
    return not evSeen
end

if A.sev then
    A.sev.onShowTextDraw = function(id, td)
        evSeen = true
        if A.isOn('pool') and CFG.enable and not usePolling() then onShowTextDraw(id, td) end
    end
    A.sev.onTextDrawHide = function(id)
        if A.isOn('pool') and CFG.enable and not usePolling() then onTextDrawHide(id) end
    end
end

--------------------------------------------------------------------------------
-- ZAPIS / ODCZYT
--------------------------------------------------------------------------------
local OWNER = { [TBL] = 't_', [CFG] = 'c_', [POWER] = 'p_' }
local NUM_FIELDS = {
    {TBL, 'HX', 0.20, 1.50}, {TBL, 'HY', 0.40, 3.00}, {TBL, 'OFF_X', -0.30, 0.30}, {TBL, 'OFF_Y', -0.30, 0.30},
    {TBL, 'POCKET_R', 0.01, 0.30}, {TBL, 'OUT_CORNER', -0.10, 0.30}, {TBL, 'OUT_MID', -0.10, 0.30},
    {CFG, 'ballR', 0.01, 0.15}, {CFG, 'railE', 0.10, 1.00}, {CFG, 'phyDt', 0.001, 0.20},
    {CFG, 'aimSource', 1, 3}, {CFG, 'aimSrc', 0, 4}, {CFG, 'maxBounces', 0, 10}, {CFG, 'tdSource', 0, 2}, {POWER, 'lead', 0.0, 1.0},
}
local BOOL_FIELDS = { {CFG, 'diag'}, {CFG, 'mig14'}, {CFG, 'plan'}, {CFG, 'autoAim'}, {CFG, 'autoShoot'}, {CFG, 'stickFlip'}, {CFG, 'axisSwap'}, {CFG, 'enable'}, {CFG, 'hud'}, {CFG, 'rail'},
    {CFG, 'wide'}, {CFG, 'discrete'} }
local lastSaved = ''

local function serialize()
    local o = { 'return {' }
    for _, f in ipairs(NUM_FIELDS) do o[#o + 1] = fmt('  %s%s = %.10g,', OWNER[f[1]], f[2], f[1][f[2]]) end
    for _, f in ipairs(BOOL_FIELDS) do o[#o + 1] = fmt('  %s%s = %s,', OWNER[f[1]], f[2], tostring(f[1][f[2]])) end
    local function list(name, src)
        o[#o + 1] = '  ' .. name .. ' = {'
        for _, s in ipairs(src) do
            local p = {}
            for i = 1, #s do p[i] = fmt('%.10g', s[i]) end
            o[#o + 1] = '    {' .. table.concat(p, ', ') .. '},'
        end
        o[#o + 1] = '  },'
    end
    list('speed', POWER.speedSamples)
    list('dist', POWER.distSamples)
    o[#o + 1] = '}'
    return table.concat(o, '\n') .. '\n'
end

local function saveConfig(force)
    local s = serialize()
    if s == lastSaved and not force then return true end
    if not A.writeFile(FILE, s) then
        A.ensureDirs()
        if not A.writeFile(FILE, s) then return false end
    end
    lastSaved = s
    return true
end

local function loadConfig()
    local chunk = loadfile(FILE) or loadfile(OLD_FILE)
    if not chunk then return end
    local ok, d = pcall(chunk)
    if not ok or type(d) ~= 'table' then
        A.log('bilard', 'uszkodzony plik konfiguracji, ignoruje')
        return
    end
    for _, f in ipairs(NUM_FIELDS) do
        local v = d[OWNER[f[1]] .. f[2]]
        if type(v) == 'number' and v >= f[3] and v <= f[4] then f[1][f[2]] = v end
    end
    for _, f in ipairs(BOOL_FIELDS) do
        local v = d[OWNER[f[1]] .. f[2]]
        if type(v) == 'boolean' then f[1][f[2]] = v end
    end
    CFG.aimSource, CFG.maxBounces, CFG.tdSource = floor(CFG.aimSource), floor(CFG.maxBounces), floor(CFG.tdSource)
    local function take(dst, src, n)
        if type(src) ~= 'table' then return end
        for _, s in ipairs(src) do
            if type(s) == 'table' and #s == n then pushSample(dst, s) end
        end
    end
    take(POWER.speedSamples, d.speed, 3)
    take(POWER.distSamples, d.dist, 4)
    rebuildPockets()
end

--------------------------------------------------------------------------------
-- DIAGNOSTYKA (przyciski w menu -> wynik na czacie)
--------------------------------------------------------------------------------
local function measureRadius()
    local px, py = getCharCoordinates(PLAYER_PED)
    local cue, cx, cy, _, _, _, bl = findPool(px, py)
    local pts = {}
    if cue then pts[1] = { cx, cy } end
    for _, b in ipairs(bl or {}) do pts[#pts + 1] = { b.x, b.y } end
    local best = huge
    for i = 1, #pts do
        for j = i + 1, #pts do
            local d = sqrt((pts[i][1] - pts[j][1]) ^ 2 + (pts[i][2] - pts[j][2]) ^ 2)
            if d > 1e-4 and d < best then best = d end
        end
    end
    if best == huge then lastInfo = 'za malo bil do pomiaru promienia'; return nil end
    lastInfo = fmt('min. odleglosc srodkow %.5f -> R = %.5f (teraz %.5f)', best, best / 2, CFG.ballR)
    return best / 2
end

local function diagTable()
    local px, py = getCharCoordinates(PLAYER_PED)
    local cue, _, _, _, tbl, tblDist = findPool(px, py)
    if not cue then return say('biala (3003) nie znaleziona') end
    if not tbl then return say('stol (2964) nie znaleziony') end
    setFrameFromObject(tbl.obj, tbl.x, tbl.y, tbl.z)
    Frame.obj, Frame.t = tbl.obj, clock()
    say('stol: (%.4f, %.4f, %.4f), do bialej %.2f m', tbl.x, tbl.y, tbl.z, tblDist)
    local axD, ayD, bxD, byD = objAxes(tbl.obj)
    local hRaw = objHeading(tbl.obj)
    say('osie: %s | macierz %s | heading %s | axisSwap %s', Frame.src,
        axD and fmt('%.2f deg', math.deg(math.atan2(-bxD, byD)) % 360) or 'brak',
        hRaw and fmt('%.2f deg', hRaw) or 'brak', tostring(CFG.axisSwap))
    if axD then say('macierz: right (%.3f, %.3f)  forward (%.3f, %.3f)', axD, ayD, bxD, byD) end
    local ref = {   -- pozycje luz z pool.pwn
        {509.61123657, -85.79737091}, {510.67373657, -84.84423065}, {510.61914062, -83.88769531},
        {509.61077881, -83.89227295}, {510.61825562, -85.80107880}, {509.55642700, -84.84602356},
    }
    local worst = 0
    for _, p in ipairs(TBL.POCKETS) do
        local wx, wy = Frame:toWorld(p[1], p[2])
        local best = huge
        for _, r in ipairs(ref) do
            local d = sqrt((wx - r[1]) ^ 2 + (wy - r[2]) ^ 2)
            if d < best then best = d end
        end
        if best > worst then worst = best end
    end
    say('odchylka luz od pool.pwn: %.1f mm %s', worst * 1000, worst < 0.03 and '- OK' or '- sprawdz gabaryty / obrot')
end

local function diagBalls()
    local px, py = getCharCoordinates(PLAYER_PED)
    local n = 0
    for _, obj in ipairs(getAllObjects()) do
        if doesObjectExist(obj) then
            local m = getObjectModel(obj)
            if BALL_NUM[m] then
                local _, x, y = getObjectCoordinates(obj)
                if (x - px) ^ 2 + (y - py) ^ 2 < 25.0 then
                    n = n + 1
                    local lx, ly = 0, 0
                    if Frame.ok then lx, ly = Frame:toLocal(x, y) end
                    say('bila %d (model %d) lok. (%.4f, %.4f)', BALL_NUM[m], m, lx, ly)
                end
            end
        end
    end
    say('razem bil w poblizu: %d', n)
end

local function diagWhy()
    local px, py = getCharCoordinates(PLAYER_PED)
    local cue, bx, by, _, tbl, _, balls = findPool(px, py)
    if not cue then return say('biala nie znaleziona') end
    if not tbl then return say('stol nie przypiety') end
    frameFromTable(tbl)
    if not Frame.ok or not AIM.ok then return say('brak kierunku celowania (wlacz overlay i celuj)') end
    local lx, ly = Frame:toLocal(bx, by)
    local ldx, ldy = Frame:dirToLocal(fromBearing(AIM.use))
    local onT, offT = 0, 0
    local step = stepTrusted() and stepFromPower(POWER.value) or 0
    local D = CFG.ballR * 2
    for _, b in ipairs(balls) do
        local blx, bly = Frame:toLocal(b.x, b.y)
        if abs(blx) < TBL.HX + K.TABLE_MARGIN and abs(bly) < TBL.HY + K.TABLE_MARGIN then
            onT = onT + 1
            local ox, oy = blx - lx, bly - ly
            local along, perp = ox * ldx + oy * ldy, abs(ox * ldy - oy * ldx)
            local verdict
            if along <= 0 then verdict = 'z tylu'
            elseif perp > D then verdict = fmt('obok o %.3f', perp - D)
            else
                local chord = 2 * sqrt(max(0, D * D - perp * perp))
                if step > 1e-4 and chord < step then verdict = fmt('{FF3D00}PRZESKOCZY (cieciwa %.4f < krok %.4f)', chord, step)
                else verdict = fmt('{00E676}ZAHACZY (cieciwa %.4f)', chord) end
            end
            say('model %d lok (%+.3f, %+.3f) %s', b.model, blx, bly, verdict)
        else
            offT = offT + 1
        end
    end
    say('na stole %d, poza stolem %d, krok %.4f (%s)', onT, offT, step, stepTrusted() and 'z sily' or 'filtr wylaczony')
end

local function applyCal()
    local xp, xn, yp, yn = mean(CAL.xp), mean(CAL.xn), mean(CAL.yp), mean(CAL.yn)
    if xp and xn then TBL.HX, TBL.OFF_X = (xp - xn) / 2, TBL.OFF_X + (xp + xn) / 2 end
    if yp and yn then TBL.HY, TBL.OFF_Y = (yp - yn) / 2, TBL.OFF_Y + (yp + yn) / 2 end
    rebuildPockets()
    CAL.xp, CAL.xn, CAL.yp, CAL.yn = {}, {}, {}, {}
    say('zastosowano: HX %.4f HY %.4f, srodek %+.4f %+.4f', TBL.HX, TBL.HY, TBL.OFF_X, TBL.OFF_Y)
    saveConfig()
end

--------------------------------------------------------------------------------
-- MODUL
--------------------------------------------------------------------------------
local lastSave, lastErr, lastErrAt, saveSoon = 0, nil, 0, false

function M.init()
    loadConfig()
    if not CFG.mig14 then CFG.autoAim, CFG.autoShoot, CFG.mig14 = false, false, true end
    CFG.hud = false
    lastSaved = serialize()
    if not A.fileExists(FILE) then saveConfig(true) end
    FONT = renderCreateFont('Arial', 9, 5)
    lastSave = clock()
end

function M.frame(now)
    if POWER.charging and clock() - POWER.lastUpdate > 0.25 then POWER.charging = false end
    if CFG.enable or CFG.diag then
        if usePolling() and tdPollable() then
            local ok, err = pcall(tdPoll, now)
            if not ok then A.log('bilard', 'textdrawy: ' .. tostring(err)) end
        end
        if A.menuOpen and not POWER.atTable and FONT and A.drawOk then
            placeHud()
            renderDrawBox(BX - 4, BY - 2, 180, 18, 0x80000000)
            renderFontDrawText(FONT, 'Bilard: HUD przy stole', BX, BY, 0xFFB48CFF)
        end
        pcall(rmbTrack, clock())
        local ok, err = xpcall(frame, debug.traceback)
        if not ok then
            local t = clock()
            if err ~= lastErr or t - lastErrAt > 5 then
                lastErr, lastErrAt = err, t
                A.log('bilard', 'blad w klatce: ' .. tostring(err))
            end
        end
    end
    if CAL_DIRTY then CAL_DIRTY, saveSoon = false, true end
    if clock() - lastSave > 30 or (saveSoon and clock() - lastSave > 2) then
        lastSave, saveSoon = clock(), false
        saveConfig()
    end
end

M.planShot = planShot
function M.disable()
    if AUTO.down then rmb(false); AUTO.down = false end
    saveConfig()
end
function M.terminate() saveConfig() end

function M.status()
    if not CFG.enable then return 'overlay wylaczony' end
    return POWER.atTable and fmt('przy stole, sila %.0f%%', POWER.value) or 'overlay wlaczony'
end

--------------------------------------------------------------------------------
-- MENU
--------------------------------------------------------------------------------
function M.menu()
    local im, ui = A.imgui, A.ui
    local function chg(fn) return function(v) fn(v); saveSoon = true end end

    ui.cols(function()
        ui.group('Bilard', function()
            ui.check('Tor', function() return CFG.enable end, chg(function(v) CFG.enable = v end),
                'Rysuje tor bili bialej przy stole: odbicia, luzy i zalecana sile uderzenia.')
            ui.check('Podpowiedz ruchu', function() return CFG.plan end, chg(function(v) CFG.plan = v end),
                'Znajduje najlepsze zagranie: ktora kule i do ktorej luzy, pod jakim katem i z jaka moca. Rysuje je na stole (rozowe).')
            ui.check('Auto celowanie', function() return CFG.autoAim end, chg(function(v) CFG.autoAim = v end),
                'Sam obraca postac tak, zeby bila uderzyla pod wyliczonym katem. Dziala podczas celowania.')
            ui.check('Diagnostyka##pool', function() return CFG.diag end, chg(function(v) CFG.diag = v; DG.prev = nil end),
                'Zapisuje do moonloader.log, co sie dzieje przy strzale: textdrawy (pasek mocy), obiekty przy bialej, kierunki, klawisze. Wlacz, zrob 5-10 strzalow i wyslij log.')
            ui.check('Auto strzal', function() return CFG.autoShoot end, chg(function(v) CFG.autoShoot = v end),
                'Gdy kat sie zgadza, sam przytrzymuje prawy przycisk myszy i puszcza go przy wyliczonej mocy. Wymaga skalibrowanej mocy (kilka uderzen w pusty stol).')
            ui.check('Szerokosc bili', function() return CFG.wide end, chg(function(v) CFG.wide = v end))
            ui.check('Ramka', function() return CFG.rail end, chg(function(v) CFG.rail = v end))
            ui.sliderInt('Odbicia', function() return CFG.maxBounces end, chg(function(v) CFG.maxBounces = v end), 0, 10)
        end)
        ui.group('Kalibracja', function()
            local sa = fitLinear(POWER.speedSamples, 3)
            local d100 = distFromPower(100)
            local _, accN = decelMedian()
            local function row(k, ok) ui.kv(k, ok and 'gotowe' or 'zbieram', ok and 0xFF33FF66 or 0xFF8A8A96) end
            row('Sila', POWER.bgWidth ~= nil or POWER.rmbMode == true)
            row('Krok fizyki', sa ~= nil)
            row('Droga', d100 ~= nil and accN >= 4)
            row('Bandy', #CAL.xp + #CAL.xn + #CAL.yp + #CAL.yn > 0)
            im.Spacing()
            ui.buttons({
                { 'Zastosuj', applyCal },
                { 'Od nowa', function()
                    CAL.xp, CAL.xn, CAL.yp, CAL.yn, TRK = {}, {}, {}, {}, {}
                    POWER.speedSamples, POWER.distSamples = {}, {}
                    POWER.tdId, POWER.bgId, POWER.bgWidth, POWER.obsMax, POWER.calibrated, POWER.cands = nil, nil, nil, nil, false, {}
                    saveSoon = true
                end },
            })
        end)
    end, function()
        ui.group('Stol', function()
            ui.sliderFloat('Bila', function() return CFG.ballR end, chg(function(v) CFG.ballR = v end), 0.02, 0.06, '%.4f')
            ui.sliderFloat('Luzy', function() return TBL.POCKET_R end, chg(function(v) TBL.POCKET_R = v end), 0.02, 0.15, '%.4f')
            ui.sliderFloat('Rogi', function() return TBL.OUT_CORNER end,
                chg(function(v) TBL.OUT_CORNER = v; rebuildPockets() end), -0.05, 0.15, '%.3f')
            ui.sliderFloat('Boki', function() return TBL.OUT_MID end,
                chg(function(v) TBL.OUT_MID = v; rebuildPockets() end), -0.05, 0.15, '%.3f')
            ui.sliderFloat('Sprezystosc', function() return CFG.railE end, chg(function(v) CFG.railE = v end), 0.1, 1.0, '%.2f')
            if ui.button('Zmierz bile') then
                local r = measureRadius()
                if r then CFG.ballR = r; saveSoon = true end
            end
        end)
        ui.group('Celowanie', function()
            local q = srcQuality(AIM.src)
            ui.kv('Kierunek z', (SRC_NAME[AIM.src] or '-') .. (q and fmt(' (blad ~%.1f)', q) or ''))
            local pick = ui.seg('plsrc', { 'Auto', 'Kij', 'Kamera', 'Postac', 'Gracz' }, CFG.aimSrc + 1)
            if pick then CFG.aimSrc = pick - 1; saveSoon = true end
            ui.check('Odwroc kij', function() return CFG.stickFlip end, chg(function(v) CFG.stickFlip = v end))
            ui.check('Obroc stol o 90', function() return CFG.axisSwap end, chg(function(v) CFG.axisSwap = v; Frame.t = -1e9 end))
        end)
    end)
end

return M
end)(A))

-- ============================================================================
-- MODUL: SAMPGPT 4.6 (Gemini) - oryginal z drobnymi zmianami pod antek.cc
-- ============================================================================
A.register((function(A)

-- Plik jest celowo w 100% ASCII (bez polskich znakow), zeby kodowanie pliku
-- nie mialo znaczenia dla MoonLoadera.
--
-- Wszystko w menu antek.cc (Insert > SAMPGPT). Na czacie zostalo /ai <pytanie>.

pcall(require, 'moonloader')

local ffi = require 'ffi'
local bit = require 'bit'

--------------------------------------------------------------------------------
-- WLASNY JSON (nie zalezy od moonloader/lib/json.lua - rozne wersje tej
-- biblioteki maja rozne API i przez to odpowiedzi z Gemini sie nie czytaly)
--------------------------------------------------------------------------------

local json = A.json

local ok_encoding, encoding = pcall(require, 'encoding')
local u8 = nil
if ok_encoding and type(encoding) == 'table' then
    pcall(function() encoding.default = 'CP1250' end)
    u8 = encoding.UTF8
end

--------------------------------------------------------------------------------
-- KONFIGURACJA
--------------------------------------------------------------------------------

-- Klucz API. Mozna tez wpisac go do moonloader\config\sampgpt_key.txt
-- (plik ma pierwszenstwo przed tym, co jest tutaj).
local GEMINI_API_KEY = 'AIzaSyDXLjlG9DUPWYTj25iODR3DlZDrk41vPuo'

local CONFIG = {
    ---------------------------------------------------------------- MODELE
    -- Kolejnosc = priorytet. Model przeciazony (503) albo z wyczerpanym limitem
    -- (429) jest pomijany przez busy_skip_sec, model nieistniejacy (404) przez 24 h.
    models_text = {                       -- /ai
        { name = 'gemini-3.7-flash',      thinking = 'LOW' },
        { name = 'gemini-3.5-flash',      thinking = 'LOW' },
        { name = 'gemini-3.5-flash-lite', thinking = 'LOW' },
    },
    models_quiz = {                       -- pytania quizowe, OX
        { name = 'gemini-3.5-flash-lite', thinking = 'LOW' },
        { name = 'gemini-3.1-flash-lite', thinking = 'LOW' },
        { name = 'gemini-3.7-flash',      thinking = 'LOW' },
    },
    models_scramble = {                   -- rozsypanki (odpowiedz jest sprawdzana: te same litery)
        { name = 'gemini-3.7-flash',      thinking = 'LOW' },
        { name = 'gemini-3.5-flash-lite', thinking = 'LOW' },
        { name = 'gemini-3.5-flash',      thinking = 'LOW' },
        { name = 'gemini-3.7-flash',      thinking = 'MEDIUM' },
    },
    models_rebus = {                      -- rebusy: dokladnosc > szybkosc
        { name = 'gemini-3.7-flash',      thinking = 'MEDIUM' },
        { name = 'gemini-3.5-flash',      thinking = 'MEDIUM' },
        { name = 'gemini-3.8-flash',      thinking = 'LOW' },
    },
    models_vision_fast = {                -- OX z ekranu, pojazd z plaskiego obrazka
        { name = 'gemini-3.5-flash-lite', thinking = 'LOW' },
        { name = 'gemini-3.1-flash-lite', thinking = 'LOW' },
        { name = 'gemini-3.7-flash',      thinking = 'LOW' },
    },
    -- "Wyscig": ile modeli pytac jednoczesnie. Wygrywa pierwsza (poprawna) odpowiedz,
    -- reszta jest przerywana. Kazdy model ma w darmowym planie osobny limit. 1 = po kolei.
    race = 2,
    busy_skip_sec = 60,
    request_timeout = 30,
    max_output_tokens = 2048,
    web_search = true,                    -- /ai szuka w Google (grounding Gemini)
    history_messages = 6,                 -- ile ostatnich wiadomosci pamieta /ai

    ---------------------------------------------------------------- QUIZY
    quiz_on_start = true,                 -- zabawy z czatu i z ramek na ekranie
    autotype = true,                      -- odpowiedz sama wpisuje sie w czat (Ty tylko Enter)
    autocopy = true,                      -- odpowiedz od razu w schowku (Ctrl+V)
    panel = true,                         -- panel z odpowiedzia (pojawia sie tylko, gdy cos sie dzieje)
    panel_y = 0.32,                       -- wysokosc panelu (0 = gora ekranu, 1 = dol)
    sound = false,                         -- sygnal dzwiekowy, gdy odpowiedz jest gotowa
    sound_id = 1057,                      -- dzwiek z GTA (ten sam numer co PlayerPlaySound w Pawn)
    auto_rebus = false,                    -- sam rozwiazuje rebus, gdy serwer go oglosi
    vehicle_vision_fallback = false,       -- pojazd z plaskiego obrazka: rozpoznanie przez AI
    ox_session_min = 30,                  -- OX wykryty automatycznie trwa tyle minut od ostatniej wzmianki
    ox_auto_vision = false,                -- OX: przy nowej rundzie sam robi screena i ocenia duzy napis
    ox_guide = true,                      -- OX: pokazuje, w ktora strone isc (strefy podpisane napisami 3D)

    ---------------------------------------------------------------- CZAT
    chat_chunk = 96,                      -- dlugosc jednej linii odpowiedzi
    max_chat_lines = 8,
    show_time = true,                     -- czas odpowiedzi na koncu (szary)

    ---------------------------------------------------------------- KLAWISZE
    -- Kody VK: F1 = 0x70 ... F12 = 0x7B, 0 = wylaczone.
    key_type   = 0x7A,                    -- F11 wpisuje ostatnia odpowiedz w czat (zostaje Enter)
    key_ox     = 0x7B,                    -- F12 OX: ocen pytanie widoczne teraz na ekranie (duzy napis)
    key_map    = 0x79,                    -- F10 mapa z pamieci gry: strefy, ikonki, znacznik (natychmiast)

    ---------------------------------------------------------------- OBRAZKI
    image_max_width = 1280,               -- screen jest zmniejszany i wysylany jako JPEG
    rebus_image_width = 1600,             -- rebusy ostrzej (drobne litery/obrazki)
    image_jpeg_quality = 85,
    max_image_bytes = 15 * 1024 * 1024,
    -- Folder ze screenami SA-MP. '' = skrypt sam go znajdzie.
    -- Przyklad: screens_dir = 'C:\\Gry\\GTA San Andreas\\userfiles\\SAMP\\screens',
    screens_dir = '',
    radar_crop = { 0.0, 0.55, 0.30, 1.0 }, -- radar na ekranie (tylko awaryjnie, gdy odczyt z pamieci nie dziala)
    zone_color_swap = false,              -- gdyby kolory stref wychodzily zamienione (czerwona <-> niebieska)
    -- Szukanie graczy (/ai gdzie jest <nick>, F10) dziala na kazdym serwerze.
    own_servers = {},
}

local KEY_FILE = getWorkingDirectory() .. '\\config\\sampgpt_key.txt'

local SYSTEM = [[
You are SAMPGPT, a fast AI assistant living inside GTA San Andreas Multiplayer (SA-MP 0.3.7).
Your reply goes straight into the in-game chat, so:
- reply in the language of the question (default Polish),
- plain ASCII only: no Polish diacritics, no emoji, no markdown, no lists, no line breaks,
- be short and direct: 1-2 sentences (max ~300 characters) unless the user asks for more; no greetings or filler.
You can answer ANY question (general knowledge, news, sports, weather, facts), not only about the game. When Google Search results are available, use them for current or factual questions and never claim you have no internet access.
You know GTA San Andreas and SA-MP very well: vehicles and their model IDs (400-611), skins (0-311),
weapons, locations, cheats, SA-MP client commands and Pawn scripting.
Use exact data from GAME CONTEXT when it is provided and never invent IDs or numbers.
When SERVER KNOWLEDGE is provided, use it for questions about the server (commands, systems, how to do things).
STRICT RULES - never break them:
- Only mention server commands that appear in SERVER KNOWLEDGE. Commands marked there as NOT EXISTING must never be
  suggested. If no fitting command is known, say you don't know it and tell the player to check the server help: /Pomoc.
- Other players' positions from LOCATION AND MAP data can be reported directly.
- Never present a guess as a fact. If something is not in the provided data, say you don't know.
For arithmetic, calculate carefully. Delta means b^2 - 4ac.
When an image is attached: read visible text/UI carefully and solve puzzles or rebuses.
You cannot know exact skin IDs from an image; if asked, give only an estimate.
]]

-- dopisywane do polecen, gdzie chcemy osobno sama odpowiedz (do wpisania w czat)
local STRUCT_HINT = '\n\nReply exactly in this format: ANSWER | very short explanation (max 10 words). '
    .. 'ANSWER must contain only the answer itself.'

--------------------------------------------------------------------------------
-- STAN
--------------------------------------------------------------------------------

local pending = false          -- zapytanie z komendy / AUTO w toku
local quiz_pending = false     -- zapytanie quizu (osobno, zeby quiz nie czekal)
local samp_ready = false
local sf_loaded = false
local sf_error = nil
local ffi_ready = false
local CURL_EXE = nil
local request_counter = 0
local last_vision = -10

local thinking_state = {}      -- nil = jak w CONFIG, 'LOW' = zapasowo, 'none' = bez thinkingConfig
local dead_models = {}         -- 404 - pomijane przez 24 h (zapamietywane na dysku)
local busy_until = {}          -- 503/429 - pomijane chwilowo
local last_model_used = nil
local last_latency = nil
local screens_dir_cache = nil
local chat_history = {}
local last_answer = nil        -- ostatnia odpowiedz (F11, schowek)

local quiz_enabled = false
local worker_restarts = 0     -- ile razy watek skanera padl przez blad SF.lua i zostal wznowiony
-- dane dla panelu: ostatnia odpowiedz, czas, reakcja, licznik z ramki
local HUD = { display = nil, src = nil, dt = nil, t = -1e9, reaction = nil, won = false, timer = nil, timer_t = -1e9 }
local quiz_img_until = 0       -- do kiedy obrazek z modelem traktujemy jako zagadke
local ox_until = 0             -- do kiedy trwa wykryta zabawa OX (odswiezane przy kazdej wzmiance)
local ox_manual = nil          -- true = wlaczony /aiox (do wylaczenia), false = wylaczony recznie
local ox_block_until = 0       -- po recznym wylaczeniu nie wlaczaj sie sam przez 10 min
local ox_marker = nil          -- znacznik strefy OX rysowany na ekranie

local command_queue = {}
local last_queued = { key = nil, t = 0 }
local swallow_enter_char = false

local crypt32, shell32 = nil, nil

local handle_quiz, handle_quiz_td, start_rebus, start_ox_vision   -- definicje w sekcji QUIZ

local COMMANDS = { 'ai' }   -- reszta komend jest w menu
local COMMAND_SET = {}
for _, c in ipairs(COMMANDS) do COMMAND_SET[c] = true end

--------------------------------------------------------------------------------
-- POMOCNICZE
--------------------------------------------------------------------------------

local function now()
    if type(localClock) == 'function' then
        local ok, t = pcall(localClock)
        if ok and type(t) == 'number' then return t end
    end
    return os.clock()
end

local function trim(s)
    s = tostring(s or '')
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s
end

local function safe_call(fn, ...)
    if type(fn) ~= 'function' then return nil end
    local res = { pcall(fn, ...) }
    if not res[1] then return nil end
    return res[2], res[3], res[4], res[5]
end

local function read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local data = f:read('*a')
    f:close()
    return data
end

local function write_file(path, data)
    local f = io.open(path, 'wb')
    if not f then return false end
    f:write(data)
    f:close()
    return true
end

-- Pamiec miedzy sesjami: ktore modele nie istnieja, jaki poziom myslenia
-- przyjmuja i gdzie sa screeny. Dzieki temu po starcie gry od razu idzie szybka sciezka.
local CACHE_FILE = getWorkingDirectory() .. '\\config\\sampgpt_cache.txt'

-- stare wersje trzymaly ustawienia w pliku cache - odczytujemy je jednorazowo
local OPT_DEFAULTS = { autotype = CONFIG.autotype, autocopy = CONFIG.autocopy, panel = CONFIG.panel, sound = CONFIG.sound }

local function load_cache()
    local d = read_file(CACHE_FILE)
    if not d then return end
    for line in d:gmatch('[^\r\n]+') do
        local k, v = line:match('^([%w_]+)=(.*)$')
        if k == 'opt' then
            local name, val = v:match('^(%S+)%s+(%S+)$')
            if name and OPT_DEFAULTS[name] ~= nil then
                CONFIG[name] = (val == '1') -- stary zapis ustawien (przenoszony do pliku ustawien)
            end
        elseif k == 'screens_dir' and v ~= '' then
            screens_dir_cache = v
        elseif k == 'dead' and v ~= '' then
            local name, t = v:match('^(%S+)%s*(%d*)$')
            t = tonumber(t) or os.time()
            if name and os.time() - t < 86400 then dead_models[name] = t end -- po 24 h sprobuj znowu
        elseif k == 'thinking' then
            local m, lv = v:match('^(%S+)%s+(%S+)$')
            if m then thinking_state[m] = lv end
        end
    end
end

-- USTAWIENIA GRACZA: osobny plik, ktory przetrwa podmiane skryptu na nowa wersje.
-- Zapisywany przy kazdej zmianie w menu, wczytywany przy starcie.
local SETTINGS_FILE = getWorkingDirectory() .. '\\config\\sampgpt_ustawienia.txt'
local SAVED = { -- nazwa w pliku -> pole w CONFIG
    { 'quizy', 'quiz_on_start' }, { 'wpis', 'autotype' }, { 'schowek', 'autocopy' },
    { 'panel', 'panel' }, { 'internet', 'web_search' }, { 'rebus_auto', 'auto_rebus' },
    { 'ox_ekran', 'ox_auto_vision' }, { 'ox_kierunek', 'ox_guide' }, { 'czas', 'show_time' },
    { 'pojazd_ai', 'vehicle_vision_fallback' },
}

-- folder moonloader\config moze nie istniec - bez niego nic by sie nie zapisalo
local function ensure_config_dir()
    local dir = getWorkingDirectory() .. '\\config'
    if type(createDirectory) == 'function' then
        pcall(createDirectory, dir)
    else
        pcall(function() ffi.C.CreateDirectoryA(dir, nil) end)
    end
end

local function load_settings()
    local d = read_file(SETTINGS_FILE)
    if not d then return false end
    for name, val in d:gmatch('([%a_]+)%s*=%s*(%S+)') do
        for _, e in ipairs(SAVED) do
            if e[1] == name then CONFIG[e[2]] = (val == '1' or val:lower() == 'on' or val:lower() == 'tak') end
        end
    end
    return true
end

local function save_settings()
    local out = { '# SAMPGPT - Twoje ustawienia (zmieniaj w grze: Insert > SAMPGPT). 1 = wlaczone, 0 = wylaczone' }
    for _, e in ipairs(SAVED) do out[#out + 1] = e[1] .. ' = ' .. (CONFIG[e[2]] and '1' or '0') end
    if not write_file(SETTINGS_FILE, table.concat(out, '\r\n') .. '\r\n') then
        ensure_config_dir()
        return write_file(SETTINGS_FILE, table.concat(out, '\r\n') .. '\r\n')
    end
    return true
end

local function save_cache()
    local out = {}
    if screens_dir_cache then out[#out + 1] = 'screens_dir=' .. screens_dir_cache end
    for m, t in pairs(dead_models) do out[#out + 1] = 'dead=' .. m .. ' ' .. tostring(tonumber(t) or os.time()) end
    for m, lv in pairs(thinking_state) do out[#out + 1] = 'thinking=' .. m .. ' ' .. lv end
    if not write_file(CACHE_FILE, table.concat(out, '\n') .. '\n') then
        ensure_config_dir()
        pcall(write_file, CACHE_FILE, table.concat(out, '\n') .. '\n')
    end
end

local function temp_dir()
    local t = os.getenv('TEMP') or os.getenv('TMP')
    if t and t ~= '' then return t end
    return getWorkingDirectory()
end

local function file_exists(path)
    if type(doesFileExist) == 'function' then
        local ok, r = pcall(doesFileExist, path)
        if ok then return r == true end
    end
    local f = io.open(path, 'rb')
    if f then f:close(); return true end
    return false
end

local function q(path)
    return '"' .. tostring(path) .. '"'
end

--------------------------------------------------------------------------------
-- STATYSTYKI: zadania, wygrane, czas reakcji (zapisywane miedzy sesjami)
local STATS = { file = getWorkingDirectory() .. '\\config\\sampgpt_staty.txt',
    d = { zadania = 0, wygrane = 0, reakcje = 0, suma = 0, rekord = 0 } }

function STATS.load()
    local f = read_file(STATS.file)
    if not f then return end
    for k, v in f:gmatch('([%w_]+)=([%d%.]+)') do
        if STATS.d[k] ~= nil then STATS.d[k] = tonumber(v) or 0 end
    end
end

function STATS.save()
    local out = {}
    for k, v in pairs(STATS.d) do out[#out + 1] = k .. '=' .. string.format('%.3f', v) end
    pcall(write_file, STATS.file, table.concat(out, '\n') .. '\n')
end

function STATS.add(k, v)
    STATS.d[k] = (STATS.d[k] or 0) + (v or 1)
    STATS.save()
end

function STATS.reaction(sec)
    local d = STATS.d
    d.reakcje, d.suma = d.reakcje + 1, d.suma + sec
    if d.rekord == 0 or sec < d.rekord then d.rekord = sec end
    STATS.save()
end

function STATS.avg()
    return STATS.d.reakcje > 0 and STATS.d.suma / STATS.d.reakcje or nil
end

--------------------------------------------------------------------------------
-- KODOWANIE ZNAKOW
-- Gra (czat SA-MP) = CP1250.  Gemini (JSON) = UTF-8.  Wyswietlanie = ASCII.
--------------------------------------------------------------------------------

local CP1250_FOLD = {
    [0xB9] = 'a', [0xA5] = 'A', [0xE6] = 'c', [0xC6] = 'C', [0xEA] = 'e', [0xCA] = 'E',
    [0xB3] = 'l', [0xA3] = 'L', [0xF1] = 'n', [0xD1] = 'N', [0xF3] = 'o', [0xD3] = 'O',
    [0x9C] = 's', [0x8C] = 'S', [0x9F] = 'z', [0x8F] = 'Z', [0xBF] = 'z', [0xAF] = 'Z',
}

local function cp1250_to_ascii(s)
    s = tostring(s or '')
    s = s:gsub('[\128-\255]', function(c) return CP1250_FOLD[c:byte()] or '?' end)
    return s
end

-- tekst z gry -> poprawny UTF-8 do JSON-a
local function game_to_utf8(s)
    s = tostring(s or '')
    if not s:find('[\128-\255]') then return s end
    if u8 then
        local ok, out = pcall(u8, s)
        if ok and type(out) == 'string' then return out end
    end
    return cp1250_to_ascii(s)
end

local UTF8_FOLD = {
    ['\196\133'] = 'a', ['\196\132'] = 'A', ['\196\135'] = 'c', ['\196\134'] = 'C',
    ['\196\153'] = 'e', ['\196\152'] = 'E', ['\197\130'] = 'l', ['\197\129'] = 'L',
    ['\197\132'] = 'n', ['\197\131'] = 'N', ['\195\179'] = 'o', ['\195\147'] = 'O',
    ['\197\155'] = 's', ['\197\154'] = 'S', ['\197\186'] = 'z', ['\197\185'] = 'Z',
    ['\197\188'] = 'z', ['\197\187'] = 'Z',
    ['\194\160'] = ' ', ['\226\128\147'] = '-', ['\226\128\148'] = '-',
    ['\226\128\152'] = "'", ['\226\128\153'] = "'", ['\226\128\156'] = '"',
    ['\226\128\157'] = '"', ['\226\128\158'] = '"', ['\226\128\166'] = '...',
    ['\195\151'] = 'x', ['\194\176'] = ' st.', ['\226\136\146'] = '-',
}

-- tekst z Gemini (UTF-8) -> czyste ASCII do czatu SA-MP
local function utf8_to_ascii(s)
    s = tostring(s or '')
    s = s:gsub('[\192-\247][\128-\191]*', function(ch) return UTF8_FOLD[ch] or '?' end)
    s = s:gsub('[\128-\255]', '?')
    return s
end

local function strip_colors(s)
    return (tostring(s or ''):gsub('{%x%x%x%x%x%x}', ''))
end

--------------------------------------------------------------------------------
-- WYSWIETLANIE W CZACIE
--------------------------------------------------------------------------------

local PREFIX = '{66CCFF}[SAMPGPT] {FFFFFF}'
local ERR_PREFIX = '{FF5555}[SAMPGPT] {FFFFFF}'
local WARN_PREFIX = '{FF6666}[SAMPGPT] {FFFFFF}'
local INFO_PREFIX = '{AAAAAA}[SAMPGPT] '
local QUIZ_PREFIX = '{FFCC00}[QUIZ-AI] {FFFFFF}'

local function chat_print(s)
    s = utf8_to_ascii(s):gsub('[\r\n\t]+', ' ')
    -- '%' potrafi wywalic gre, jesli funkcja czatu traktuje tekst jak format printf
    s = s:gsub('%%', ' proc.')
    if samp_ready and type(sampAddChatMessage) == 'function' then
        local ok = pcall(sampAddChatMessage, s, -1)
        if ok then return end
    end
    print('[SAMPGPT] ' .. s)
end

local function clean_answer(s)
    s = utf8_to_ascii(s)
    s = s:gsub('%*%*', ''):gsub('`', ''):gsub('[\r\n\t]+', ' '):gsub('%s+', ' ')
    return trim(s)
end

local function split_chunks(s, limit)
    local out = {}
    while #s > 0 do
        if #s <= limit then
            out[#out + 1] = s
            break
        end
        local cut = s:sub(1, limit):match('^.*()%s')
        if not cut or cut < limit * 0.5 then cut = limit + 1 end
        out[#out + 1] = s:sub(1, cut - 1)
        s = s:sub(cut):gsub('^%s+', '')
    end
    return out
end

-- dzieli dlugi tekst na kilka linii czatu (tylko w lua_thread - uzywa wait)
local function send_lines(s, prefix, max_lines, suffix)
    prefix = prefix or PREFIX
    max_lines = max_lines or CONFIG.max_chat_lines
    local chunks = split_chunks(clean_answer(s), CONFIG.chat_chunk)
    local n = math.min(#chunks, max_lines)
    for i = 1, n do
        local line = chunks[i]
        if i == n and #chunks > n then line = line .. ' (...)' end
        if i == n and suffix then line = line .. suffix end
        chat_print(prefix .. line)
        if i < n then wait(15) end
    end
end

local function send_error(s)
    send_lines('BLAD: ' .. tostring(s), ERR_PREFIX, 3)
end

local function time_suffix(sec)
    if not CONFIG.show_time or not sec then return nil end
    return string.format(' {777777}%.1fs', sec)
end

-- zapamietuje odpowiedz dla F11 i schowka (max 1 linia czatu)
local function set_last_answer(s, raw)
    if not raw then s = clean_answer(s) end
    s = trim(s)
    if s == '' then return end
    if #s > 140 then s = split_chunks(s, 140)[1] end
    last_answer = s
end

-- odpowiedz "do wpisania": zapamietaj + (opcjonalnie) do schowka
local function offer_answer(s, raw)
    set_last_answer(s, raw)
    if CONFIG.autocopy and last_answer and type(setClipboardText) == 'function' then
        pcall(setClipboardText, last_answer)
    end
end

-- duzy napis na ekranie (styl GTA)
local function show_big(text, color, raw)
    if not raw or type(printStringNow) ~= 'function' then return end
    local t = raw and text or clean_answer(game_to_utf8(text)):gsub('~', '')
    pcall(printStringNow, (color or '~y~') .. t, 4000)
end

-- otwiera czat z wpisanym tekstem (zostaje Enter); nie nadpisuje tego, co wlasnie piszesz
local function type_into_chat(text, force)
    if not text or text == '' then return false end
    if type(sampSetChatInputEnabled) ~= 'function' or type(sampSetChatInputText) ~= 'function' then return false end
    if safe_call(sampIsDialogActive) == true then return false end
    if not force and safe_call(sampIsChatInputActive) == true then
        local cur = safe_call(sampGetChatInputText)
        if type(cur) == 'string' and trim(cur) ~= '' then return false end
    end
    pcall(sampSetChatInputEnabled, true)
    pcall(sampSetChatInputText, text)
    return true
end

-- krotki sygnal z gry przy postaci (zeby bylo slychac nawet bez patrzenia na czat)
local function play_sound()
    if not CONFIG.sound or type(addOneOffSound) ~= 'function' then return end
    local x, y, z = safe_call(getCharCoordinates, PLAYER_PED)
    if x then pcall(addOneOffSound, x, y, z, CONFIG.sound_id) end
end

-- nowa odpowiedz w panelu
local function hud_answer(display, src, dt)
    HUD.display, HUD.src, HUD.dt, HUD.t = display, src, dt, now()
    HUD.reaction, HUD.won = nil, false
end

-- odpowiedz "do wpisania" (quizy, rebusy, obrazki): czat + schowek + wpisanie + duzy napis
-- ans w kodowaniu gry (CP1250); o = { display, extra, quiet }
local delivered = {}
local function deliver_answer(ans, dt, o)
    o = o or {}
    local la = cp1250_to_ascii(tostring(ans)):lower()
    if la:find('zabojstw', 1, true) or la:find('smierc', 1, true) or la:find('zgon', 1, true)
        or la:find('kills', 1, true) or la:find('deaths', 1, true) then
        return
    end
    local dk = la:gsub('%s+', ' ')
    if delivered[dk] and now() - delivered[dk] < 120 then return end
    delivered[dk] = now()
    local line = QUIZ_PREFIX .. (o.display or game_to_utf8(ans))
    if o.extra and o.extra ~= '' then line = line .. ' {AAAAAA}(' .. o.extra:sub(1, 50) .. ')' end
    chat_print(line .. (time_suffix(dt) or ''))
    if o.quiet then
        set_last_answer(ans, true)
        return
    end
    offer_answer(ans, true)
    if CONFIG.autotype then type_into_chat(last_answer) end
    if not CONFIG.panel then show_big(ans) end -- z panelem duzy napis bylby dublem
    hud_answer(clean_answer(game_to_utf8(ans)), o.extra, dt)
    STATS.add('zadania')
    play_sound()
end

local function onoff(v) return v and 'ON' or 'OFF' end

-- czy trwa tryb OX: wlaczony recznie albo wykryty (i nie wylaczony recznie)
local function ox_active()
    if ox_manual == true then return true end
    if now() < ox_block_until then return false end
    return now() < ox_until
end

local function key_name(vk)
    if not vk or vk == 0 then return 'brak' end
    if vk >= 0x70 and vk <= 0x7B then return 'F' .. (vk - 0x6F) end
    return string.format('0x%02X', vk)
end

--------------------------------------------------------------------------------
-- SF.lua
--------------------------------------------------------------------------------

local function export_module(mod)
    if type(mod) ~= 'table' then return end
    for k, v in pairs(mod) do
        if type(k) == 'string' and type(v) == 'function' and rawget(_G, k) == nil then
            _G[k] = v
        end
    end
end

local function load_sf()
    if sf_loaded then return true end
    if type(sampAddChatMessage) == 'function' and type(sampGetChatString) == 'function' then
        sf_loaded = true
        return true
    end
    local names = { 'SFlua', 'sflua', 'SF', 'sf', 'SFlua.init', 'sflua.init' }
    for _, name in ipairs(names) do
        local ok, mod = pcall(require, name)
        if ok then
            export_module(mod)
            sf_loaded = true
            return true
        end
        local msg = tostring(mod)
        if not msg:find("module '" .. name .. "' not found", 1, true) then
            sf_error = msg -- biblioteka jest, ale wywalila blad przy ladowaniu
        end
    end
    local init = getWorkingDirectory() .. '\\lib\\SFlua\\init.lua'
    if file_exists(init) then
        local ok, mod = pcall(dofile, init)
        if ok then
            export_module(mod)
            sf_loaded = true
            return true
        end
        sf_error = tostring(mod)
    end
    sf_error = sf_error or 'nie znaleziono SF.lua w moonloader\\lib'
    return false
end

local function samp_available()
    if type(isSampAvailable) == 'function' then
        local ok, r = pcall(isSampAvailable)
        return ok and r == true
    end
    if type(isSampLoaded) == 'function' then
        local ok, r = pcall(isSampLoaded)
        return ok and r == true
    end
    return nil
end

local function samp_dll_loaded()
    if type(getModuleHandle) == 'function' then
        local ok, h = pcall(getModuleHandle, 'samp.dll')
        if ok then return h ~= nil and h ~= 0 end
    end
    return nil
end

--------------------------------------------------------------------------------
-- FFI (WinAPI) - deklarowane PO zaladowaniu SF.lua, kazda osobno,
-- zeby nie kolidowac z deklaracjami sampapi.
--------------------------------------------------------------------------------

local function cdef(s) pcall(ffi.cdef, s) end

local function init_ffi()
    if ffi_ready then return end
    cdef[[
        typedef struct {
            uint32_t cb; char *lpReserved; char *lpDesktop; char *lpTitle;
            uint32_t dwX; uint32_t dwY; uint32_t dwXSize; uint32_t dwYSize;
            uint32_t dwXCountChars; uint32_t dwYCountChars; uint32_t dwFillAttribute; uint32_t dwFlags;
            uint16_t wShowWindow; uint16_t cbReserved2; uint8_t *lpReserved2;
            void *hStdInput; void *hStdOutput; void *hStdError;
        } AK_STARTUPINFOA;
    ]]
    cdef[[
        typedef struct { void *hProcess; void *hThread; uint32_t dwProcessId; uint32_t dwThreadId; } AK_PROCESS_INFORMATION;
    ]]
    cdef[[ typedef struct { uint32_t dwLowDateTime; uint32_t dwHighDateTime; } AK_FILETIME; ]]
    cdef[[
        typedef struct {
            uint32_t dwFileAttributes;
            AK_FILETIME ftCreationTime; AK_FILETIME ftLastAccessTime; AK_FILETIME ftLastWriteTime;
            uint32_t nFileSizeHigh; uint32_t nFileSizeLow; uint32_t dwReserved0; uint32_t dwReserved1;
            char cFileName[260]; char cAlternateFileName[14];
        } AK_WIN32_FIND_DATAA;
    ]]
    cdef[[ int CreateProcessA(const char *app, char *cmd, void *pa, void *ta, int inherit, uint32_t flags, void *env, const char *cwd, AK_STARTUPINFOA *si, AK_PROCESS_INFORMATION *pi); ]]
    cdef[[ uint32_t WaitForSingleObject(void *h, uint32_t ms); ]]
    cdef[[ int GetExitCodeProcess(void *h, uint32_t *code); ]]
    cdef[[ int TerminateProcess(void *h, uint32_t code); ]]
    cdef[[ int CloseHandle(void *h); ]]
    cdef[[ uint32_t GetLastError(void); ]]
    cdef[[ void *FindFirstFileA(const char *pattern, AK_WIN32_FIND_DATAA *fd); ]]
    cdef[[ int FindNextFileA(void *h, AK_WIN32_FIND_DATAA *fd); ]]
    cdef[[ int FindClose(void *h); ]]
    cdef[[ void keybd_event(uint8_t vk, uint8_t scan, uint32_t flags, uintptr_t extra); ]]
    cdef[[ int CryptBinaryToStringA(const char *data, uint32_t len, uint32_t flags, char *out, uint32_t *outlen); ]]
    cdef[[ int SHGetFolderPathA(void *hwnd, int csidl, void *token, uint32_t flags, char *path); ]]
    cdef[[ int CreateDirectoryA(const char *path, void *security); ]]
    cdef[[ int IsBadReadPtr(const void *lp, uintptr_t ucb); ]]

    local ok1, c32 = pcall(ffi.load, 'crypt32')
    if ok1 then crypt32 = c32 end
    local ok2, s32 = pcall(ffi.load, 'shell32')
    if ok2 then shell32 = s32 end
    ffi_ready = true
end

-- Procesy (curl.exe) uruchamiane BEZ okna konsoli i BEZ blokowania gry.
local function proc_spawn(cmdline)
    local si = ffi.new('AK_STARTUPINFOA')
    si.cb = ffi.sizeof('AK_STARTUPINFOA')
    si.dwFlags = 0x00000001   -- STARTF_USESHOWWINDOW
    si.wShowWindow = 0        -- SW_HIDE
    local pi = ffi.new('AK_PROCESS_INFORMATION')
    local buf = ffi.new('char[?]', #cmdline + 1)
    ffi.copy(buf, cmdline)
    if ffi.C.CreateProcessA(nil, buf, nil, nil, 0, 0x08000000, nil, nil, si, pi) == 0 then -- CREATE_NO_WINDOW
        return nil, 'CreateProcess nie zadzialal (kod ' .. tostring(ffi.C.GetLastError()) .. ')'
    end
    ffi.C.CloseHandle(pi.hThread)
    return { h = pi.hProcess }
end

local function proc_running(p)
    return p.h ~= nil and ffi.C.WaitForSingleObject(p.h, 0) == 258 -- WAIT_TIMEOUT
end

local function proc_close(p)
    if p.h == nil then return nil end
    local code = ffi.new('uint32_t[1]')
    ffi.C.GetExitCodeProcess(p.h, code)
    ffi.C.CloseHandle(p.h)
    p.h = nil
    return tonumber(code[0])
end

local function proc_kill(p)
    if p.h == nil then return end
    ffi.C.TerminateProcess(p.h, 1)
    ffi.C.CloseHandle(p.h)
    p.h = nil
end

--------------------------------------------------------------------------------
-- BASE64
--------------------------------------------------------------------------------

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local B64T = {}
for i = 1, 64 do B64T[i - 1] = B64:sub(i, i) end

local function base64_lua(data)
    local out, n = {}, 0
    local len = #data
    for i = 1, len, 3 do
        local a, b, c = data:byte(i, i + 2)
        b = b or 0
        c = c or 0
        local triple = a * 65536 + b * 256 + c
        n = n + 1
        out[n] = B64T[math.floor(triple / 262144) % 64]
            .. B64T[math.floor(triple / 4096) % 64]
            .. ((i + 1 <= len) and B64T[math.floor(triple / 64) % 64] or '=')
            .. ((i + 2 <= len) and B64T[triple % 64] or '=')
        if n % 20000 == 0 then wait(0) end -- nie zamrazaj gry na duzych plikach
    end
    return table.concat(out)
end

local function base64_encode(data)
    if crypt32 then
        local ok, res = pcall(function()
            local flags = 0x40000001 -- CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF
            local n = ffi.new('uint32_t[1]')
            if crypt32.CryptBinaryToStringA(data, #data, flags, nil, n) == 0 then return nil end
            local buf = ffi.new('char[?]', n[0] + 1)
            if crypt32.CryptBinaryToStringA(data, #data, flags, buf, n) == 0 then return nil end
            return ffi.string(buf)
        end)
        if ok and type(res) == 'string' and #res > 0 then return res end
    end
    return base64_lua(data)
end

--------------------------------------------------------------------------------
-- MATEMATYKA LOKALNIE (bez API)
--------------------------------------------------------------------------------

local function parse_math(expr)
    local pos = 1
    local parse_expr, parse_term, parse_power, parse_unary

    local function skip()
        while expr:sub(pos, pos):match('%s') do pos = pos + 1 end
    end

    local function number()
        skip()
        local start = pos
        while expr:sub(pos, pos):match('[%d%.]') do pos = pos + 1 end
        if start == pos then error('number expected') end
        local n = tonumber(expr:sub(start, pos - 1))
        if not n then error('bad number') end
        return n
    end

    local function primary()
        skip()
        if expr:sub(pos, pos) == '(' then
            pos = pos + 1
            local v = parse_expr()
            skip()
            if expr:sub(pos, pos) ~= ')' then error('missing )') end
            pos = pos + 1
            return v
        end
        return number()
    end

    parse_unary = function()
        skip()
        local c = expr:sub(pos, pos)
        if c == '+' then pos = pos + 1; return parse_unary() end
        if c == '-' then pos = pos + 1; return -parse_unary() end
        return primary()
    end

    parse_power = function()
        local left = parse_unary()
        skip()
        if expr:sub(pos, pos) == '^' then
            pos = pos + 1
            return left ^ parse_power()
        end
        return left
    end

    parse_term = function()
        local v = parse_power()
        while true do
            skip()
            local c = expr:sub(pos, pos)
            if c ~= '*' and c ~= '/' and c ~= '%' and c ~= 'x' and c ~= ':' then return v end
            pos = pos + 1
            local r = parse_power()
            if c == '*' or c == 'x' then v = v * r
            elseif c == '/' or c == ':' then v = v / r
            else v = v % r end
        end
    end

    parse_expr = function()
        local v = parse_term()
        while true do
            skip()
            local c = expr:sub(pos, pos)
            if c ~= '+' and c ~= '-' then return v end
            pos = pos + 1
            local r = parse_term()
            if c == '+' then v = v + r else v = v - r end
        end
    end

    local value = parse_expr()
    skip()
    if pos <= #expr then error('unexpected input') end
    return value
end

local function fmt_number(v)
    if math.abs(v - math.floor(v + 0.5)) < 1e-10 and math.abs(v) < 1e15 then
        return string.format('%d', math.floor(v + 0.5))
    end
    return string.format('%.10g', v)
end

local function try_math(s)
    local x = cp1250_to_ascii(s):lower():gsub(',', '.')
    x = trim(x):gsub('%s*[=!?]+%s*$', '')
    local expr = x:match('^ile%s+to%s+(.+)$')
        or x:match('^ile%s+jest%s+(.+)$')
        or x:match('^what%s+is%s+(.+)$')
        or x:match('^calculate%s+(.+)$')
        or x:match('^policz%s+(.+)$')
        or x
    expr = trim(expr)
    -- tylko cyfry i operatory, i przynajmniej jeden operator
    if not expr:match('^[%d%.%s%+%-%*/%^%%%(%)x:]+$') then return nil end
    if not expr:find('[%+%*/%^%%x:]') and not expr:find('%d%s*%-') then return nil end
    local ok, value = pcall(parse_math, expr)
    if not ok or type(value) ~= 'number' or value ~= value then return nil end
    if value == math.huge or value == -math.huge then return nil end
    return fmt_number(value)
end

local function try_delta(s)
    local x = cp1250_to_ascii(s):lower():gsub(',', '.')
    local a, b, c = x:match('delta%s*[:=]?%s*([%-%.%d]+)%s+([%-%.%d]+)%s+([%-%.%d]+)')
    if not (a and b and c) then return nil end
    a, b, c = tonumber(a), tonumber(b), tonumber(c)
    if not (a and b and c) then return nil end
    local d = b * b - 4 * a * c
    local out = 'Delta = ' .. fmt_number(d)
    if a ~= 0 then
        if d > 0 then
            local sd = math.sqrt(d)
            out = out .. ' | x1 = ' .. fmt_number((-b - sd) / (2 * a)) .. ', x2 = ' .. fmt_number((-b + sd) / (2 * a))
        elseif d == 0 then
            out = out .. ' | x0 = ' .. fmt_number(-b / (2 * a))
        else
            out = out .. ' | brak pierwiastkow rzeczywistych'
        end
    end
    return out
end

--------------------------------------------------------------------------------
-- NAZWY POJAZDOW (ID 400-611), dokladne dane z GTA SA
--------------------------------------------------------------------------------

local VEHICLE_NAMES = {
    [400] = 'Landstalker', [401] = 'Bravura', [402] = 'Buffalo', [403] = 'Linerunner',
    [404] = 'Perennial', [405] = 'Sentinel', [406] = 'Dumper', [407] = 'Firetruck',
    [408] = 'Trashmaster', [409] = 'Stretch', [410] = 'Manana', [411] = 'Infernus',
    [412] = 'Voodoo', [413] = 'Pony', [414] = 'Mule', [415] = 'Cheetah',
    [416] = 'Ambulance', [417] = 'Leviathan', [418] = 'Moonbeam', [419] = 'Esperanto',
    [420] = 'Taxi', [421] = 'Washington', [422] = 'Bobcat', [423] = 'Mr Whoopee',
    [424] = 'BF Injection', [425] = 'Hunter', [426] = 'Premier', [427] = 'Enforcer',
    [428] = 'Securicar', [429] = 'Banshee', [430] = 'Predator', [431] = 'Bus',
    [432] = 'Rhino', [433] = 'Barracks', [434] = 'Hotknife', [435] = 'Article Trailer',
    [436] = 'Previon', [437] = 'Coach', [438] = 'Cabbie', [439] = 'Stallion',
    [440] = 'Rumpo', [441] = 'RC Bandit', [442] = 'Romero', [443] = 'Packer',
    [444] = 'Monster', [445] = 'Admiral', [446] = 'Squalo', [447] = 'Seasparrow',
    [448] = 'Pizzaboy', [449] = 'Tram', [450] = 'Article Trailer 2', [451] = 'Turismo',
    [452] = 'Speeder', [453] = 'Reefer', [454] = 'Tropic', [455] = 'Flatbed',
    [456] = 'Yankee', [457] = 'Caddy', [458] = 'Solair', [459] = "Berkley's RC Van",
    [460] = 'Skimmer', [461] = 'PCJ-600', [462] = 'Faggio', [463] = 'Freeway',
    [464] = 'RC Baron', [465] = 'RC Raider', [466] = 'Glendale', [467] = 'Oceanic',
    [468] = 'Sanchez', [469] = 'Sparrow', [470] = 'Patriot', [471] = 'Quad',
    [472] = 'Coastguard', [473] = 'Dinghy', [474] = 'Hermes', [475] = 'Sabre',
    [476] = 'Rustler', [477] = 'ZR-350', [478] = 'Walton', [479] = 'Regina',
    [480] = 'Comet', [481] = 'BMX', [482] = 'Burrito', [483] = 'Camper',
    [484] = 'Marquis', [485] = 'Baggage', [486] = 'Dozer', [487] = 'Maverick',
    [488] = 'News Chopper', [489] = 'Rancher', [490] = 'FBI Rancher', [491] = 'Virgo',
    [492] = 'Greenwood', [493] = 'Jetmax', [494] = 'Hotring', [495] = 'Sandking',
    [496] = 'Blista Compact', [497] = 'Police Maverick', [498] = 'Boxville',
    [499] = 'Benson', [500] = 'Mesa', [501] = 'RC Goblin', [502] = 'Hotring Racer A',
    [503] = 'Hotring Racer B', [504] = 'Bloodring Banger', [505] = 'Rancher (lure)',
    [506] = 'Super GT', [507] = 'Elegant', [508] = 'Journey', [509] = 'Bike',
    [510] = 'Mountain Bike', [511] = 'Beagle', [512] = 'Cropduster', [513] = 'Stunt',
    [514] = 'Tanker', [515] = 'Roadtrain', [516] = 'Nebula', [517] = 'Majestic',
    [518] = 'Buccaneer', [519] = 'Shamal', [520] = 'Hydra', [521] = 'FCR-900',
    [522] = 'NRG-500', [523] = 'HPV1000', [524] = 'Cement Truck', [525] = 'Tow Truck',
    [526] = 'Fortune', [527] = 'Cadrona', [528] = 'FBI Truck', [529] = 'Willard',
    [530] = 'Forklift', [531] = 'Tractor', [532] = 'Combine', [533] = 'Feltzer',
    [534] = 'Remington', [535] = 'Slamvan', [536] = 'Blade', [537] = 'Freight',
    [538] = 'Streak', [539] = 'Vortex', [540] = 'Vincent', [541] = 'Bullet',
    [542] = 'Clover', [543] = 'Sadler', [544] = 'Firetruck LA', [545] = 'Hustler',
    [546] = 'Intruder', [547] = 'Primo', [548] = 'Cargobob', [549] = 'Tampa',
    [550] = 'Sunrise', [551] = 'Merit', [552] = 'Utility Van', [553] = 'Nevada',
    [554] = 'Yosemite', [555] = 'Windsor', [556] = 'Monster A', [557] = 'Monster B',
    [558] = 'Uranus', [559] = 'Jester', [560] = 'Sultan', [561] = 'Stratum',
    [562] = 'Elegy', [563] = 'Raindance', [564] = 'RC Tiger', [565] = 'Flash',
    [566] = 'Tahoma', [567] = 'Savanna', [568] = 'Bandito', [569] = 'Freight Flat',
    [570] = 'Streak Carriage', [571] = 'Kart', [572] = 'Mower', [573] = 'Dune',
    [574] = 'Sweeper', [575] = 'Broadway', [576] = 'Tornado', [577] = 'AT-400',
    [578] = 'DFT-30', [579] = 'Huntley', [580] = 'Stafford', [581] = 'BF-400',
    [582] = 'Newsvan', [583] = 'Tug', [584] = 'Petrol Trailer', [585] = 'Emperor',
    [586] = 'Wayfarer', [587] = 'Euros', [588] = 'Hotdog', [589] = 'Club',
    [590] = 'Freight Box', [591] = 'Article Trailer 3', [592] = 'Andromada',
    [593] = 'Dodo', [594] = 'RC Cam', [595] = 'Launch', [596] = 'Police Car (LSPD)',
    [597] = 'Police Car (SFPD)', [598] = 'Police Car (LVPD)', [599] = 'Police Ranger',
    [600] = 'Picador', [601] = 'S.W.A.T.', [602] = 'Alpha', [603] = 'Phoenix',
    [604] = 'Glendale (damaged)', [605] = 'Sadler (damaged)', [606] = 'Baggage Trailer A',
    [607] = 'Baggage Trailer B', [608] = 'Tug Stairs', [609] = 'Boxburg',
    [610] = 'Farm Trailer', [611] = 'Utility Trailer'
}

local WEAPON_MODELS = {
    [321] = 'Dildo', [322] = 'Dildo 2', [323] = 'Vibrator', [324] = 'Vibrator 2',
    [325] = 'Flowers', [326] = 'Cane', [331] = 'Brass Knuckles', [333] = 'Golf Club',
    [334] = 'Nightstick', [335] = 'Knife', [336] = 'Baseball Bat', [337] = 'Shovel',
    [338] = 'Pool Cue', [339] = 'Katana', [341] = 'Chainsaw', [342] = 'Grenade',
    [343] = 'Tear Gas', [344] = 'Molotov', [346] = 'Colt 45', [347] = 'Silenced Pistol',
    [348] = 'Desert Eagle', [349] = 'Shotgun', [350] = 'Sawn-off Shotgun', [351] = 'Combat Shotgun',
    [352] = 'Micro Uzi', [353] = 'MP5', [355] = 'AK-47', [356] = 'M4',
    [357] = 'Country Rifle', [358] = 'Sniper Rifle', [359] = 'Rocket Launcher',
    [360] = 'Heat-Seeker', [361] = 'Flamethrower', [362] = 'Minigun',
    [363] = 'Satchel Charge', [364] = 'Detonator', [365] = 'Spraycan',
    [366] = 'Fire Extinguisher', [367] = 'Camera', [368] = 'Night Vision',
    [369] = 'Thermal Goggles', [371] = 'Parachute', [372] = 'Tec-9'
}

local function vehicle_name(id)
    return VEHICLE_NAMES[tonumber(id) or -1]
end

--------------------------------------------------------------------------------
-- KONTEKST GRY
--------------------------------------------------------------------------------

local function get_local_context()
    local c = {}
    local found, id = safe_call(sampGetPlayerIdByCharHandle, PLAYER_PED)
    if found == nil and id == nil then found = safe_call(sampGetLocalPlayerId) end
    if found == true then
        c.id = id
    elseif type(found) == 'number' then
        c.id = found
    else
        c.id = safe_call(sampGetLocalPlayerId)
    end
    if c.id then c.nick = safe_call(sampGetPlayerNickname, c.id) end
    c.server = safe_call(sampGetCurrentServerName)
    return c
end

local function context_to_text(t)
    local ok, encoded = pcall(json.encode, t)
    if ok and type(encoded) == 'string' then return game_to_utf8(encoded) end
    return 'none'
end

local take_screenshot, gdip
do
--------------------------------------------------------------------------------
-- SCREENSHOT (F8)
--------------------------------------------------------------------------------

local function documents_dir()
    if shell32 then
        local buf = ffi.new('char[260]')
        local ok, hr = pcall(function() return shell32.SHGetFolderPathA(nil, 5, nil, 0, buf) end) -- CSIDL_PERSONAL
        if ok and hr == 0 then return ffi.string(buf) end
    end
    return (os.getenv('USERPROFILE') or 'C:') .. '\\Documents'
end

local function game_dir()
    if type(getGameDirectory) == 'function' then
        local ok, d = pcall(getGameDirectory)
        if ok and type(d) == 'string' and d ~= '' then return d end
    end
    return (getWorkingDirectory():gsub('\\[^\\]+$', ''))
end

local function screen_dirs()
    local dirs, seen = {}, {}
    local function add(d)
        if d and d ~= '' and not seen[d:lower()] then
            seen[d:lower()] = true
            dirs[#dirs + 1] = d
        end
    end
    if CONFIG.screens_dir ~= '' then add(CONFIG.screens_dir) end
    add(screens_dir_cache)
    local docs_list = { documents_dir() }
    local up = os.getenv('USERPROFILE')
    if up then
        docs_list[#docs_list + 1] = up .. '\\Documents'
        docs_list[#docs_list + 1] = up .. '\\OneDrive\\Documents'
        docs_list[#docs_list + 1] = up .. '\\OneDrive\\Dokumenty'
    end
    for _, docs in ipairs(docs_list) do
        add(docs .. '\\GTA San Andreas User Files\\SAMP\\screens')
        add(docs .. '\\GTA San Andreas User Files\\SAMP')
    end
    local gd = game_dir()
    add(gd .. '\\userfiles\\SAMP\\screens')
    add(gd .. '\\userfiles\\SAMP')
    add(gd .. '\\SAMP\\screens')
    add(gd .. '\\screens')
    add(gd)
    add(getWorkingDirectory() .. '\\screens')
    return dirs
end

local function list_images(dir, into)
    local fd = ffi.new('AK_WIN32_FIND_DATAA')
    local h = ffi.C.FindFirstFileA(dir .. '\\*', fd)
    if h == nil or tonumber(ffi.cast('intptr_t', h)) == -1 then return end
    repeat
        if bit.band(fd.dwFileAttributes, 0x10) == 0 then
            local name = ffi.string(fd.cFileName)
            local low = name:lower()
            if low:match('%.png$') or low:match('%.jpe?g$') then
                into[dir .. '\\' .. name] = {
                    t = fd.ftLastWriteTime.dwHighDateTime * 4294967296 + fd.ftLastWriteTime.dwLowDateTime,
                    size = fd.nFileSizeHigh * 4294967296 + fd.nFileSizeLow,
                }
            end
        end
    until ffi.C.FindNextFileA(h, fd) == 0
    ffi.C.FindClose(h)
end

local function snapshot(dirs)
    local all = {}
    for _, d in ipairs(dirs) do list_images(d, all) end
    return all
end

local function press_key(vk)
    ffi.C.keybd_event(vk, 0, 0, 0)
    wait(30)
    ffi.C.keybd_event(vk, 0, 2, 0) -- KEYEVENTF_KEYUP
end

local function is_invalid_handle(h)
    return h == nil or tonumber(ffi.cast('intptr_t', h)) == -1
end

local function file_size(path)
    local fd = ffi.new('AK_WIN32_FIND_DATAA')
    local h = ffi.C.FindFirstFileA(path, fd)
    if is_invalid_handle(h) then return nil end
    local size = fd.nFileSizeHigh * 4294967296 + fd.nFileSizeLow
    ffi.C.FindClose(h)
    return size
end

-- szuka pliku w podfolderach (z limitem, zeby nie zamulic gry)
local function find_file_recursive(root, name, depth, budget)
    if not root or budget.n <= 0 then return nil end
    local direct = root .. '\\' .. name
    if file_size(direct) then return direct end
    if depth <= 0 then return nil end
    local fd = ffi.new('AK_WIN32_FIND_DATAA')
    local h = ffi.C.FindFirstFileA(root .. '\\*', fd)
    if is_invalid_handle(h) then return nil end
    local subs = {}
    repeat
        local attr = fd.dwFileAttributes
        if bit.band(attr, 0x10) ~= 0 and bit.band(attr, 0x406) == 0 then
            local n = ffi.string(fd.cFileName)
            if n ~= '.' and n ~= '..' then subs[#subs + 1] = n end
        end
    until ffi.C.FindNextFileA(h, fd) == 0
    ffi.C.FindClose(h)
    for _, sub in ipairs(subs) do
        budget.n = budget.n - 1
        if budget.n <= 0 then return nil end
        if budget.n % 100 == 0 then wait(0) end
        local r = find_file_recursive(root .. '\\' .. sub, name, depth - 1, budget)
        if r then return r end
    end
    return nil
end

-- nazwy screenow z ostatnich linii czatu ("Screenshot Taken - sa-mp-005.png")
local function chat_screenshot_names()
    local names = {}
    if type(sampGetChatString) ~= 'function' then return names end
    for i = 80, 99 do
        local text = safe_call(sampGetChatString, i)
        if type(text) == 'string' then
            local n = text:match('[Ss]creenshot.-([%w%-_%.]+%.[pP][nN][gG])')
                or text:match('[Ss]creenshot.-([%w%-_%.]+%.[jJ][pP][eE]?[gG])')
                or text:match('(sa%-mp%-%d+%.%a+)')
            if n then names[n] = true end
        end
    end
    return names
end

--------------------------------------------------------------------------------
-- ZMNIEJSZANIE SCREENA (GDI+ z Windowsa): PNG kilka MB -> JPEG ~200 KB
--------------------------------------------------------------------------------

gdip = nil
local JPEG_CLSID, QUALITY_GUID = nil, nil

local function make_guid(d1, d2, d3, b)
    local g = ffi.new('AK_GUID')
    g.Data1, g.Data2, g.Data3 = d1, d2, d3
    for i = 0, 7 do g.Data4[i] = b[i + 1] end
    return g
end

local function init_gdiplus()
    if gdip ~= nil then return gdip ~= false end
    local ok = pcall(function()
        cdef[[ typedef struct { uint32_t GdiplusVersion; void *DebugEventCallback; int SuppressBackgroundThread; int SuppressExternalCodecs; } AK_GdiplusStartupInput; ]]
        cdef[[ typedef struct { uint32_t Data1; uint16_t Data2; uint16_t Data3; uint8_t Data4[8]; } AK_GUID; ]]
        cdef[[ typedef struct { AK_GUID Guid; uint32_t NumberOfValues; uint32_t Type; void *Value; } AK_EncoderParameter; ]]
        cdef[[ typedef struct { uint32_t Count; AK_EncoderParameter Parameter[1]; } AK_EncoderParameters; ]]
        cdef[[ int __stdcall GdiplusStartup(uintptr_t *token, const AK_GdiplusStartupInput *input, void *output); ]]
        cdef[[ int __stdcall GdipCreateBitmapFromFile(const uint16_t *filename, void **bitmap); ]]
        cdef[[ int __stdcall GdipGetImageWidth(void *image, uint32_t *w); ]]
        cdef[[ int __stdcall GdipGetImageHeight(void *image, uint32_t *h); ]]
        cdef[[ int __stdcall GdipCreateBitmapFromScan0(int w, int h, int stride, int format, uint8_t *scan0, void **bitmap); ]]
        cdef[[ int __stdcall GdipGetImageGraphicsContext(void *image, void **graphics); ]]
        cdef[[ int __stdcall GdipSetInterpolationMode(void *graphics, int mode); ]]
        cdef[[ int __stdcall GdipDrawImageRectI(void *graphics, void *image, int x, int y, int w, int h); ]]
        cdef[[ int __stdcall GdipDrawImageRectRectI(void *graphics, void *image, int dx, int dy, int dw, int dh, int sx, int sy, int sw, int sh, int unit, void *attr, void *cb, void *cbdata); ]]
        cdef[[ int __stdcall GdipDeleteGraphics(void *graphics); ]]
        cdef[[ int __stdcall GdipSaveImageToFile(void *image, const uint16_t *filename, const AK_GUID *clsid, const AK_EncoderParameters *params); ]]
        cdef[[ int __stdcall GdipDisposeImage(void *image); ]]
        cdef[[ int __stdcall MultiByteToWideChar(uint32_t cp, uint32_t flags, const char *src, int srclen, uint16_t *dst, int dstlen); ]]
        local lib = ffi.load('gdiplus')
        local input = ffi.new('AK_GdiplusStartupInput')
        input.GdiplusVersion = 1
        local token = ffi.new('uintptr_t[1]')
        if lib.GdiplusStartup(token, input, nil) ~= 0 then error('GdiplusStartup') end
        JPEG_CLSID = make_guid(0x557CF401, 0x1A04, 0x11D3, { 0x9A, 0x73, 0x00, 0x00, 0xF8, 0x1E, 0xF3, 0x2E })
        QUALITY_GUID = make_guid(0x1D5BE4B5, 0xFA4A, 0x452D, { 0x9C, 0xDD, 0x5D, 0xB3, 0x51, 0x05, 0xE7, 0xEB })
        gdip = lib
    end)
    if not ok then gdip = false end
    return gdip ~= false
end

local function to_wide(str)
    local n = ffi.C.MultiByteToWideChar(0, 0, str, -1, nil, 0)
    if n <= 0 then return nil end
    local buf = ffi.new('uint16_t[?]', n)
    ffi.C.MultiByteToWideChar(0, 0, str, -1, buf, n)
    return buf
end

local function compress_image(src_path, max_w, crop)
    if not init_gdiplus() then return nil end
    local dst = temp_dir() .. '\\sampgpt_shot_' .. tostring(os.time()) .. '.jpg'
    local wsrc, wdst = to_wide(src_path), to_wide(dst)
    if not wsrc or not wdst then return nil end
    local img = ffi.new('void*[1]')
    if gdip.GdipCreateBitmapFromFile(wsrc, img) ~= 0 or img[0] == nil then return nil end
    local ok, result = pcall(function()
        local wv, hv = ffi.new('uint32_t[1]'), ffi.new('uint32_t[1]')
        gdip.GdipGetImageWidth(img[0], wv)
        gdip.GdipGetImageHeight(img[0], hv)
        local w, h = tonumber(wv[0]), tonumber(hv[0])
        if w == 0 or h == 0 then return nil end
        local sx, sy, sw, sh = 0, 0, w, h
        if crop then
            sx, sy = math.floor(w * crop[1]), math.floor(h * crop[2])
            sw, sh = math.max(1, math.floor(w * (crop[3] - crop[1]))), math.max(1, math.floor(h * (crop[4] - crop[2])))
        end
        local scale = math.min(crop and 2 or 1, (max_w or CONFIG.image_max_width) / sw)
        local nw = math.max(1, math.floor(sw * scale + 0.5))
        local nh = math.max(1, math.floor(sh * scale + 0.5))
        local target, scaled = img[0], nil
        if scale ~= 1 or crop then
            local sb = ffi.new('void*[1]')
            if gdip.GdipCreateBitmapFromScan0(nw, nh, 0, 0x21808, nil, sb) ~= 0 then return nil end
            scaled = sb[0]
            local g = ffi.new('void*[1]')
            if gdip.GdipGetImageGraphicsContext(scaled, g) ~= 0 then
                gdip.GdipDisposeImage(scaled)
                return nil
            end
            gdip.GdipSetInterpolationMode(g[0], 7)
            if crop then
                gdip.GdipDrawImageRectRectI(g[0], img[0], 0, 0, nw, nh, sx, sy, sw, sh, 2, nil, nil, nil)
            else
                gdip.GdipDrawImageRectI(g[0], img[0], 0, 0, nw, nh)
            end
            gdip.GdipDeleteGraphics(g[0])
            target = scaled
        end
        local quality = ffi.new('uint32_t[1]', CONFIG.image_jpeg_quality)
        local params = ffi.new('AK_EncoderParameters')
        params.Count = 1
        params.Parameter[0].Guid = QUALITY_GUID
        params.Parameter[0].NumberOfValues = 1
        params.Parameter[0].Type = 4
        params.Parameter[0].Value = quality
        local st = gdip.GdipSaveImageToFile(target, wdst, JPEG_CLSID, params)
        if scaled then gdip.GdipDisposeImage(scaled) end
        if st ~= 0 then return nil end
        return read_file(dst)
    end)
    gdip.GdipDisposeImage(img[0])
    os.remove(dst)
    if ok and type(result) == 'string' and #result > 0 then return result end
    return nil
end

function take_screenshot(max_w, crop)
    local dirs = screen_dirs()
    local before = snapshot(dirs)
    local names_before = chat_screenshot_names()
    press_key(0x77) -- F8 = screenshot SA-MP
    local deadline = now() + 10
    local found, last_size, stable = nil, -1, 0
    local chat_name, searched = nil, 0
    while now() < deadline do
        wait(50)
        if not chat_name then
            for n in pairs(chat_screenshot_names()) do
                if not names_before[n] then chat_name = n; break end
            end
        end
        if not found then
            if chat_name then
                for _, d in ipairs(dirs) do
                    if file_size(d .. '\\' .. chat_name) then found = d .. '\\' .. chat_name; break end
                end
            end
            if not found then
                local after = snapshot(dirs)
                for path, info in pairs(after) do
                    local b = before[path]
                    if not b or b.t ~= info.t or b.size ~= info.size then
                        found = path
                        break
                    end
                end
            end
            if not found and chat_name and searched < 2 then
                searched = searched + 1
                local budget = { n = 4000 }
                found = find_file_recursive(game_dir(), chat_name, 4, budget)
                    or find_file_recursive(documents_dir(), chat_name, 4, budget)
                    or find_file_recursive(os.getenv('USERPROFILE'), chat_name, 3, budget)
            end
            if found then
                local dir = found:match('^(.*)\\[^\\]+$')
                if dir and dir ~= screens_dir_cache then
                    if chat_name then chat_print('{AAAAAA}[SAMPGPT] Folder screenow: ' .. dir) end
                    screens_dir_cache = dir
                    save_cache()
                end
            end
        end
        if found then
            if chat_name and found:sub(-#chat_name):lower() == chat_name:lower() then break end
            local size = file_size(found) or -1
            if size > 0 and size == last_size then
                stable = stable + 1
                if stable >= 1 then break end
            else
                stable = 0
            end
            last_size = size
        end
    end
    if not found then
        if chat_name then
            return nil, 'Screen ' .. chat_name .. ' zostal zapisany, ale nie znalazlem go na dysku. '
                .. 'Wpisz sciezke folderu do CONFIG.screens_dir na gorze pliku.'
        end
        return nil, 'Nie wykryto nowego screena (F8). Sprawdz, czy F8 robi screena w SA-MP.'
    end
    local data = compress_image(found, max_w, crop)
    local mime = 'image/jpeg'
    if not data then
        data = read_file(found)
        if not data or #data == 0 then return nil, 'Nie mozna odczytac pliku screena.' end
        mime = found:lower():match('%.png$') and 'image/png' or 'image/jpeg'
    end
    if #data > CONFIG.max_image_bytes then return nil, 'Screen jest za duzy (' .. #data .. ' B).' end
    return base64_encode(data), mime
end

end -- screenshot

--------------------------------------------------------------------------------
-- GEMINI API: curl.exe w tle, kilka modeli naraz ("wyscig"), anulowanie
--------------------------------------------------------------------------------

local function find_curl()
    local windir = os.getenv('WINDIR') or 'C:\\Windows'
    local wd = getWorkingDirectory()
    local candidates = {
        wd .. '\\curl.exe',
        wd .. '\\lib\\curl.exe',
        windir .. '\\System32\\curl.exe',
        windir .. '\\Sysnative\\curl.exe',
        windir .. '\\SysWOW64\\curl.exe',
    }
    for _, p in ipairs(candidates) do
        if file_exists(p) then return p end
    end
    return nil
end

local function get_api_key()
    local k = GEMINI_API_KEY
    local f = read_file(KEY_FILE)
    if f and trim(f) ~= '' then k = f end
    k = tostring(k or ''):gsub('^\239\187\191', '')
    k = trim(k):match('^[^\r\n]*') or ''
    k = k:gsub('"', '')
    return trim(k)
end

local cancel_epoch = 0
local CANCELLED = 'Anulowano.'
local ask_gemini, cancel_all_requests
do
local active_reqs = {}

local function api_cleanup(req)
    os.remove(req.fin)
    os.remove(req.fout)
    os.remove(req.ferr)
    active_reqs[req] = nil
end

local function api_start(body, model)
    if not CURL_EXE then CURL_EXE = find_curl() end
    if not CURL_EXE then return nil, 'Nie znaleziono curl.exe (wrzuc curl.exe do folderu moonloader).', true end
    local key = get_api_key()
    if key == '' then return nil, 'Brak klucza API (Insert > SAMPGPT > Klucz API).', true end
    request_counter = request_counter + 1
    local base = temp_dir() .. '\\sampgpt_' .. tostring(os.time()) .. '_' .. tostring(request_counter)
    local req = { fin = base .. '_in.json', fout = base .. '_out.json', ferr = base .. '_err.txt', model = model }
    if not write_file(req.fin, body) then return nil, 'Nie mozna zapisac pliku tymczasowego.', true end
    local url = 'https://generativelanguage.googleapis.com/v1beta/models/' .. model .. ':generateContent'
    local cmd = q(CURL_EXE)
        .. ' --silent --show-error --connect-timeout 8 --max-time ' .. tostring(CONFIG.request_timeout)
        .. ' -X POST'
        .. ' -H "Content-Type: application/json"'
        .. ' -H "x-goog-api-key: ' .. key .. '"'
        .. ' --data-binary @' .. q(req.fin)
        .. ' -o ' .. q(req.fout)
        .. ' --stderr ' .. q(req.ferr)
        .. ' ' .. q(url)
    local p, err = proc_spawn(cmd)
    if not p then
        os.remove(req.fin)
        return nil, err, true
    end
    req.proc = p
    req.deadline = now() + CONFIG.request_timeout + 3
    active_reqs[req] = true
    return req
end

local function api_poll(req)
    if proc_running(req.proc) then
        if now() > req.deadline then
            proc_kill(req.proc)
            api_cleanup(req)
            return 'error', 'przekroczono czas oczekiwania (' .. tostring(CONFIG.request_timeout) .. ' s)'
        end
        return 'running'
    end
    local code = proc_close(req.proc)
    local raw = read_file(req.fout)
    local errtxt = read_file(req.ferr) or ''
    api_cleanup(req)
    if not raw or raw == '' then
        errtxt = trim(errtxt:gsub('[\r\n]+', ' ')):sub(1, 120)
        return 'error', 'Brak odpowiedzi (curl=' .. tostring(code) .. ') ' .. errtxt
    end
    return 'done', raw
end

local function api_cancel(req)
    if req.proc then proc_kill(req.proc) end
    api_cleanup(req)
end

function cancel_all_requests()
    local list = {}
    for req in pairs(active_reqs) do list[#list + 1] = req end
    for _, req in ipairs(list) do api_cancel(req) end
end

local IMG_MARK = '@@SAMPGPT_IMAGE_DATA@@'

local function thinking_for(m)
    local st = thinking_state[m.name]
    if st == 'none' then return nil end
    if st then return st end
    if m.thinking and m.thinking ~= '' then return m.thinking:upper() end
    return nil
end

local function build_body(contents, m, web)
    local gen = { maxOutputTokens = CONFIG.max_output_tokens }
    local level = thinking_for(m)
    if level then gen.thinkingConfig = { thinkingLevel = level } end
    local body = {
        systemInstruction = { parts = { { text = SYSTEM } } },
        contents = contents,
        generationConfig = gen,
    }
    if web then body.tools = { { google_search = {} } } end
    return json.encode(body)
end

local function parse_candidate(data)
    local cand = type(data.candidates) == 'table' and data.candidates[1] or nil
    if type(cand) ~= 'table' then
        local fb = data.promptFeedback
        if type(fb) == 'table' and fb.blockReason then
            return nil, 'Zapytanie zablokowane: ' .. tostring(fb.blockReason)
        end
        return nil, 'Brak odpowiedzi od modelu.'
    end
    local out = {}
    local content = cand.content
    if type(content) == 'table' and type(content.parts) == 'table' then
        for _, p in ipairs(content.parts) do
            if type(p) == 'table' and type(p.text) == 'string' and not p.thought then
                out[#out + 1] = p.text
            end
        end
    end
    local txt = table.concat(out, ' ')
    if txt:match('^%s*$') then
        return nil, 'Pusta odpowiedz (finishReason=' .. tostring(cand.finishReason) .. ')'
    end
    return txt
end

local function classify_error(code, msg)
    local low = tostring(msg or ''):lower()
    if low:find('think') then return 'thinking' end
    if code == 500 or code == 502 or code == 503 or code == 504
        or low:find('high demand') or low:find('overloaded') or low:find('unavailable') then
        return 'busy'
    end
    if code == 429 or low:find('quota') or low:find('rate limit') then return 'quota' end
    if code == 404 or low:find('not found') then return 'nomodel' end
    return 'fatal'
end

local function interpret(raw)
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then
        local msg = raw:match('"message"%s*:%s*"(.-)"%s*[,}]')
        local code = tonumber(raw:match('"code"%s*:%s*(%d+)'))
        if msg then return nil, msg, classify_error(code, msg) end
        return nil, 'Nieczytelna odpowiedz: ' .. utf8_to_ascii(raw):sub(1, 120), 'fatal'
    end
    if type(data.error) == 'table' then
        local msg = tostring(data.error.message or data.error.status or 'blad API')
        return nil, msg, classify_error(tonumber(data.error.code), msg)
    end
    local txt, perr = parse_candidate(data)
    if txt then return txt end
    return nil, perr, 'empty'
end

local function model_available(m)
    return not dead_models[m.name] and (busy_until[m.name] or 0) <= now()
end

function ask_gemini(o)
    local models = o.models or CONFIG.models_text
    local web = (o.models == nil) and not o.image_b64 and CONFIG.web_search ~= false   -- tylko zwykle /ai
    local parts = { { text = o.question .. '\n\nGAME CONTEXT:\n' .. (o.context or 'none') } }
    if o.image_b64 then
        parts[2] = { inlineData = { mimeType = o.image_mime or 'image/png', data = IMG_MARK } }
    end
    local contents = {}
    if o.history then
        for _, h in ipairs(o.history) do contents[#contents + 1] = h end
    end
    contents[#contents + 1] = { role = 'user', parts = parts }
    local any_free = false
    for _, m in ipairs(models) do
        if model_available(m) then any_free = true end
    end
    if not any_free then busy_until = {} end
    local queue, qi = {}, 1
    for _, m in ipairs(models) do
        if model_available(m) then queue[#queue + 1] = m end
    end
    if #queue == 0 then
        return nil, 'Zaden model nie jest dostepny. Sprawdz liste modeli w CONFIG.'
    end
    local epoch = cancel_epoch
    local start = now()
    local inflight = {}
    local last_err, fatal = nil, nil
    local busy_hits, other_hits = 0, 0
    local function launch(m)
        local ok_enc, body = pcall(build_body, contents, m, web)
        if not ok_enc then
            fatal = 'JSON: ' .. tostring(body)
            return false
        end
        if o.image_b64 then
            local s, e = body:find(IMG_MARK, 1, true)
            if s then body = body:sub(1, s - 1) .. o.image_b64 .. body:sub(e + 1) end
        end
        local req, err, is_fatal = api_start(body, m.name)
        if not req then
            last_err = err
            if is_fatal then fatal = err end
            return false
        end
        req.m = m
        inflight[#inflight + 1] = req
        return true
    end
    local function launch_next()
        while qi <= #queue and not fatal do
            local m = queue[qi]
            qi = qi + 1
            if model_available(m) and launch(m) then return true end
        end
        return false
    end
    local function stop_all()
        for _, r in ipairs(inflight) do api_cancel(r) end
        inflight = {}
    end
    for _ = 1, math.max(1, o.race or CONFIG.race or 1) do
        if not launch_next() then break end
    end
    if fatal then stop_all(); return nil, fatal end
    if #inflight == 0 then return nil, last_err or 'Nie udalo sie wyslac zapytania.' end
    while #inflight > 0 do
        wait(15)
        if cancel_epoch ~= epoch then
            stop_all()
            return nil, CANCELLED
        end
        local i = 1
        while i <= #inflight do
            local req = inflight[i]
            local status, raw = api_poll(req)
            if status == 'running' then
                i = i + 1
            else
                table.remove(inflight, i)
                local txt, err, kind
                if status == 'done' then
                    txt, err, kind = interpret(raw)
                else
                    err, kind = raw, 'net'
                end
                if txt and o.validate and not o.validate(txt) then
                    o.rejected = o.rejected or txt
                    err, kind, txt = 'odpowiedz nie przeszla sprawdzenia: ' .. clean_answer(txt):sub(1, 40), 'invalid', nil
                end
                if txt then
                    stop_all()
                    last_model_used = req.m.name
                    last_latency = now() - start
                    return txt
                end
                last_err = err
                if kind ~= 'busy' and kind ~= 'quota' and kind ~= 'invalid' then other_hits = other_hits + 1 end
                local m = req.m
                if kind == 'thinking' and thinking_state[m.name] ~= 'none' then
                    if thinking_state[m.name] == nil and thinking_for(m) ~= 'LOW' then
                        thinking_state[m.name] = 'LOW'
                    else
                        thinking_state[m.name] = 'none'
                    end
                    save_cache()
                    launch(m)
                elseif kind == 'busy' or kind == 'quota' then
                    busy_until[m.name] = now() + CONFIG.busy_skip_sec
                    busy_hits = busy_hits + 1
                    launch_next()
                elseif kind == 'nomodel' then
                    dead_models[m.name] = os.time()
                    save_cache()
                    launch_next()
                elseif kind == 'empty' or kind == 'invalid' then
                    launch_next()
                elseif kind == 'net' then
                else
                    stop_all()
                    return nil, err
                end
                if fatal then
                    stop_all()
                    return nil, fatal
                end
            end
        end
    end
    if o.rejected then return nil, 'Zadna odpowiedz nie przeszla sprawdzenia.', o.rejected end
    if busy_hits > 0 and other_hits == 0 then
        return nil, 'Serwery Google sa teraz przeciazone (wszystkie modele). Sprobuj za chwile.'
    end
    return nil, 'Brak odpowiedzi z zadnego modelu. Ostatni blad: ' .. tostring(last_err)
end

end -- api

--------------------------------------------------------------------------------
-- TEXTDRAWY: podglad modelu 3D (dokladne ID) + teksty z ramek (quizy na ekranie)
--------------------------------------------------------------------------------

local TD_MAX_ID = 2303
local TD_PER_FRAME = 128

local td_seen = {}
local td_scan_pos = 0
local td_partial = {}
local td_texts = {}
local td_last_full, td_last_full_t = nil, 0

local function td_supported()
    return type(sampTextdrawIsExists) == 'function'
        and type(sampTextdrawGetModelRotationZoomVehColor) == 'function'
end

local function describe_model(m)
    if m >= 400 and m <= 611 then
        local n = tostring(VEHICLE_NAMES[m])
        return 'POJAZD: ' .. n .. ' (ID ' .. m .. ')', n
    elseif m >= 0 and m <= 311 then
        return 'SKIN ID: ' .. m, tostring(m)
    elseif WEAPON_MODELS[m] then
        return 'BRON: ' .. WEAPON_MODELS[m] .. ' (model ' .. m .. ')', WEAPON_MODELS[m]
    end
    return 'OBIEKT model ID: ' .. m, tostring(m)
end

local function td_model_at(id, has_style)
    local style = nil
    if has_style then
        local oks, st = pcall(sampTextdrawGetStyle, id)
        if oks then style = tonumber(st) end
    end
    if style ~= 5 and style ~= nil then return nil end
    local okm, model = pcall(sampTextdrawGetModelRotationZoomVehColor, id)
    model = okm and tonumber(model) or nil
    if model and (style == 5 or model > 0) then return model end
    return nil
end

local function scan_model_textdraws()
    local res = {}
    if not td_supported() then return res end
    local has_style = type(sampTextdrawGetStyle) == 'function'
    for id = 0, TD_MAX_ID do
        local ok, exists = pcall(sampTextdrawIsExists, id)
        if ok and exists == true then
            local model = td_model_at(id, has_style)
            if model then res[#res + 1] = { id = id, model = model } end
        end
    end
    return res
end

local function td_deliver(model, full)
    local text, ans = describe_model(model)
    if full then
        if td_last_full == model and now() - td_last_full_t < 20 then return end
        td_last_full, td_last_full_t = model, now()
        deliver_answer(ans, nil, { display = text })
    else
        set_last_answer(ans)
        chat_print('{FFCC00}[SAMPGPT] {FFFFFF}' .. text .. ' {777777}(F11 wpisze)')
    end
end

local function quiz_model(m)
    return (m >= 0 and m <= 311) or (m >= 400 and m <= 611)
end

local function td_scan_restart()
    td_scan_pos = 0
    td_partial = {}
    td_texts = {}
end

local function td_auto_step()
    if type(sampTextdrawIsExists) ~= 'function' then return end
    local want_models = td_supported()
    local want_text = quiz_enabled and type(sampTextdrawGetString) == 'function'
    if not want_models and not want_text then return end
    local has_style = type(sampTextdrawGetStyle) == 'function'
    local has_pos = type(sampTextdrawGetPos) == 'function'
    local last = math.min(td_scan_pos + TD_PER_FRAME - 1, TD_MAX_ID)
    for id = td_scan_pos, last do
        local ok, exists = pcall(sampTextdrawIsExists, id)
        if ok and exists == true then
            if want_models then
                local model = td_model_at(id, has_style)
                if model then td_partial[id .. ':' .. model] = model end
            end
            if want_text then
                local oks, s = pcall(sampTextdrawGetString, id)
                if oks and type(s) == 'string' and s ~= '' then
                    local item = { s = s, id = id }
                    if has_pos then
                        local okp, x, y = pcall(sampTextdrawGetPos, id)
                        if okp then item.x, item.y = tonumber(x), tonumber(y) end
                    end
                    td_texts[#td_texts + 1] = item
                end
            end
        end
    end
    td_scan_pos = last + 1
    if td_scan_pos <= TD_MAX_ID then return end
    td_scan_pos = 0
    if want_models then
        local fresh, dup = {}, {}
        for key, model in pairs(td_partial) do
            if not td_seen[key] and quiz_model(model) and not dup[model] then
                dup[model] = true
                fresh[#fresh + 1] = model
            end
        end
        local full = now() < quiz_img_until
        if full then
            local done = false
            for _, model in ipairs(fresh) do
                if not done then
                    td_deliver(model, true)
                    done = true
                end
            end
        elseif #fresh > 3 then
            chat_print(INFO_PREFIX .. 'Pojawilo sie ' .. #fresh .. ' obrazkow aut/skinow naraz - pomijam.')
        else
            for _, model in ipairs(fresh) do td_deliver(model, false) end
        end
        td_seen = td_partial
    end
    td_partial = {}
    local texts = td_texts
    td_texts = {}
    if want_text and handle_quiz_td then pcall(handle_quiz_td, texts) end
end

local function get_td_strings()
    if type(sampTextdrawIsExists) ~= 'function' or type(sampTextdrawGetString) ~= 'function' then return '' end
    local out, seen = {}, {}
    for id = 0, TD_MAX_ID do
        local ok, ex = pcall(sampTextdrawIsExists, id)
        if ok and ex == true then
            local oks, s = pcall(sampTextdrawGetString, id)
            if oks and type(s) == 'string' and not s:match('^[%w_]+:[%w_]+$') then
                s = s:gsub('~n~', ' '):gsub('~%a~', ''):gsub('_', ' ')
                s = trim(strip_colors(s):gsub('%s+', ' '))
                if #s >= 2 and s:lower() ~= 'usebox' and not seen[s] then
                    seen[s] = true
                    out[#out + 1] = s:sub(1, 80)
                    if #out >= 30 then break end
                end
            end
        end
    end
    return game_to_utf8(table.concat(out, ' || '))
end

local function td_context()
    local tds = get_td_strings()
    if tds == '' then return '' end
    return '\nTEXTDRAW TEXTS ON SCREEN (may help): ' .. tds
end

--------------------------------------------------------------------------------
-- ZADANIA W TLE
--------------------------------------------------------------------------------

local jobs = {}

local function run_job(fn, is_quiz)
    if is_quiz then
        if quiz_pending then return false end
        quiz_pending = true
    else
        if pending then
            chat_print(WARN_PREFIX .. 'Juz przetwarzam zapytanie - chwila.')
            return false
        end
        pending = true
    end
    local job = { quiz = is_quiz }
    job.th = lua_thread.create(function()
        local ok, err = pcall(fn)
        if is_quiz then quiz_pending = false else pending = false end
        job.done = true
        jobs[job] = nil
        if not ok then chat_print(ERR_PREFIX .. 'Blad skryptu: ' .. tostring(err)) end
    end)
    if not job.done then jobs[job] = true end
    return true
end

local function push_history(q_text, a_text)
    chat_history[#chat_history + 1] = { role = 'user', parts = { { text = q_text } } }
    chat_history[#chat_history + 1] = { role = 'model', parts = { { text = a_text } } }
    while #chat_history > CONFIG.history_messages do table.remove(chat_history, 1) end
end

local function split_answer(txt)
    local c = clean_answer(txt)
    local a, e = c:match('^(.-)%s*|%s*(.*)$')
    if a and a ~= '' then return a, e end
    return c, nil
end

local function ai_request(o)
    return run_job(function()
        if o.delay and o.delay > 0 then wait(o.delay) end
        local t0 = now()
        local image, mime
        if o.screenshot then
            if not o.quiet then chat_print(INFO_PREFIX .. 'robie screena...') end
            local img, m_or_err = take_screenshot(o.image_width, o.crop)
            if not img then
                if o.on_fail then o.on_fail(m_or_err) else send_error(m_or_err) end
                return
            end
            image, mime = img, m_or_err
            if o.extra_context then o.context = (o.context or '') .. o.extra_context() end
        end
        if not o.quiet then chat_print(INFO_PREFIX .. (image and 'analizuje obraz...' or 'mysle...')) end
        local answer, err, rejected = ask_gemini({
            question = o.prompt .. (o.structured and STRUCT_HINT or ''),
            context = o.context,
            image_b64 = image,
            image_mime = mime,
            history = o.history and chat_history or nil,
            models = o.models,
            validate = o.validate,
            race = o.race,
        })
        if not answer then
            if err == CANCELLED then
                chat_print(INFO_PREFIX .. 'Anulowano.')
            elseif o.on_fail then
                o.on_fail(err, rejected)
            else
                send_error(err)
            end
            return
        end
        if o.on_answer then
            o.on_answer(answer, now() - t0)
            return
        end
        if o.history then push_history(o.prompt, answer) end
        local suffix = time_suffix(now() - t0)
        local prefix = o.prefix or PREFIX
        if o.structured then
            local a, e = split_answer(answer)
            offer_answer(a)
            if e and e ~= '' then a = a .. ' {AAAAAA}(' .. e .. ')' end
            send_lines(a, prefix, nil, suffix)
        else
            set_last_answer(answer)
            send_lines(answer, prefix, nil, suffix)
        end
    end, o.quiz)
end

--------------------------------------------------------------------------------
-- MATEMATYKA DO QUIZOW (lokalnie, 0 ms)
--------------------------------------------------------------------------------

local solve_math
do

local function feq(a, b)
    return math.abs(a - b) <= 1e-9 * math.max(1, math.abs(a), math.abs(b))
end

local function diffs(a)
    local d = {}
    for i = 2, #a do d[#d + 1] = a[i] - a[i - 1] end
    return d
end

local function all_equal(a)
    for i = 2, #a do
        if not feq(a[i], a[1]) then return false end
    end
    return true
end

local function poly_check(order)
    return function(a)
        local d = a
        for _ = 1, order do d = diffs(d) end
        return #d >= 2 and all_equal(d)
    end
end

local function poly_next(order)
    return function(p)
        local rows = { p }
        for o = 1, order do rows[o + 1] = diffs(rows[o]) end
        local add = rows[order + 1][#rows[order + 1]]
        for o = order, 1, -1 do
            add = rows[o][#rows[o]] + add
        end
        return add
    end
end

local function geo_check(a)
    if #a < 3 or a[1] == 0 then return false end
    local r = a[2] / a[1]
    if r == 0 then return false end
    for i = 2, #a do
        if a[i - 1] == 0 or not feq(a[i] / a[i - 1], r) then return false end
    end
    return true
end

local SEQ = {
    { name = 'arytmetyczny', min = 4, need = 2, check = poly_check(1), next = poly_next(1) },
    { name = 'geometryczny', min = 4, need = 2, check = geo_check,
      next = function(p) if p[#p - 1] == 0 then return nil end return p[#p] * (p[#p] / p[#p - 1]) end },
    { name = 'x*a+b', min = 5, need = 3,
      check = function(a)
          if a[2] == a[1] then return false end
          local m = (a[3] - a[2]) / (a[2] - a[1])
          local c = a[2] - m * a[1]
          for i = 2, #a do
              if not feq(a[i], m * a[i - 1] + c) then return false end
          end
          return true
      end,
      next = function(p)
          local x1, x2, x3 = p[#p - 2], p[#p - 1], p[#p]
          if x2 == x1 then return nil end
          local m = (x3 - x2) / (x2 - x1)
          return m * x3 + (x3 - m * x2)
      end },
    { name = 'fibonacci', min = 4, need = 2,
      check = function(a)
          for i = 3, #a do
              if not feq(a[i], a[i - 1] + a[i - 2]) then return false end
          end
          return true
      end,
      next = function(p) return p[#p] + p[#p - 1] end },
    { name = 'kwadratowy', min = 5, need = 3, check = poly_check(2), next = poly_next(2) },
    { name = 'roznice x r', min = 5, need = 3,
      check = function(a) return geo_check(diffs(a)) end,
      next = function(p)
          local d1, d2 = p[#p - 1] - p[#p - 2], p[#p] - p[#p - 1]
          if d1 == 0 then return nil end
          return p[#p] + d2 * (d2 / d1)
      end },
    { name = 'przeplatany', min = 6, need = 4,
      check = function(a)
          local o, e = {}, {}
          for i = 1, #a do
              if i % 2 == 1 then o[#o + 1] = a[i] else e[#e + 1] = a[i] end
          end
          return (#o < 3 or all_equal(diffs(o))) and (#e < 3 or all_equal(diffs(e)))
      end,
      next = function(p) return p[#p - 1] + (p[#p - 1] - p[#p - 3]) end },
    { name = 'szescienny', min = 6, need = 4, check = poly_check(3), next = poly_next(3) },
}

local function seq_val(t)
    t = t:gsub('^[%(%[]+', ''):gsub('[%)%]!]+$', '')
    if t:match('^%-?%d+%.?%d*$') and not t:match('%.$') then return tonumber(t) end
    if t:match('^%?+$') or t == '_' or t == '...' then return '?' end
    return nil
end

local function seq_extract(text)
    local best, run = nil, {}
    local function flush()
        local nums, q = 0, 0
        for _, t in ipairs(run) do
            if t == '?' then q = q + 1 else nums = nums + 1 end
        end
        if q == 1 and nums >= 2 and (not best or #run > #best) then best = run end
        run = {}
    end
    for piece in (text .. ','):gmatch('([^,;|]*)[,;|]') do
        piece = trim(piece)
        local v = seq_val(piece)
        if v ~= nil then
            run[#run + 1] = v
        else
            local first, last = piece:match('^(%S+)'), piece:match('(%S+)$')
            local vf = first and seq_val(first)
            if vf ~= nil and #run > 0 then run[#run + 1] = vf end
            flush()
            local vl = last and seq_val(last)
            if vl ~= nil then run[#run + 1] = vl end
        end
    end
    flush()
    return best
end

local function is_int(v) return feq(v, math.floor(v + 0.5)) end

local function seq_solve(run)
    local k, n = nil, #run
    local all_int = true
    for i, v in ipairs(run) do
        if v == '?' then k = i elseif not is_int(v) then all_int = false end
    end
    local fallback = nil
    for _, m in ipairs(SEQ) do
        if n >= m.min then
            local x = nil
            if k - 1 >= m.need then
                local pre = {}
                for i = 1, k - 1 do pre[i] = run[i] end
                x = m.next(pre)
            elseif n - k >= m.need then
                local suf = {}
                for i = n, k + 1, -1 do suf[#suf + 1] = run[i] end
                x = m.next(suf)
            end
            if x and x == x and x ~= math.huge and x ~= -math.huge then
                local full = {}
                for i = 1, n do full[i] = (i == k) and x or run[i] end
                if m.check(full) then
                    if is_int(x) or not all_int then return x, m.name end
                    fallback = fallback or x
                end
            end
        end
    end
    return fallback
end

local function eq_solve(low)
    local eq = low:match('([%dx%.%s%+%-%*/%^%(%)]*x[%dx%.%s%+%-%*/%^%(%)]*=[%dx%.%s%+%-%*/%^%(%)]+)')
        or low:match('([%dx%.%s%+%-%*/%^%(%)]+=[%dx%.%s%+%-%*/%^%(%)]*x[%dx%.%s%+%-%*/%^%(%)]*)')
    if not eq then return nil end
    local l, r = eq:match('^(.-)=(.+)$')
    if not l or trim(l) == '' or trim(r) == '' then return nil end
    local function side(sd, v)
        local e = sd:gsub('(%d)%s*x', '%1*x'):gsub('%)%s*x', ')*x'):gsub('x%s*%(', 'x*('):gsub('(%d)%s*%(', '%1*(')
        e = e:gsub('x', '(' .. string.format('%.12g', v) .. ')')
        local ok, res = pcall(parse_math, trim(e))
        return ok and res or nil
    end
    local function f(v)
        local a, b = side(l, v), side(r, v)
        if not a or not b then return nil end
        return a - b
    end
    local f0, f1, f2 = f(0), f(1), f(2)
    if not f0 or not f1 or not f2 or feq(f0, f1) then return nil end
    if not feq(f2 - f0, 2 * (f1 - f0)) then return nil end
    local x = -f0 / (f1 - f0)
    local fx = f(x)
    if fx and math.abs(fx) < 1e-6 then return x end
    return nil
end

local function num(v) return tonumber(v) end

local function math_words(low)
    local changed, lastv = false, nil
    local function put(v)
        changed, lastv = true, v
        return ' ' .. string.format('%.12g', v) .. ' '
    end
    local N = '(%-?%d+%.?%d*)'
    low = low:gsub('pierwiastek%s*%a*%s*z%s*' .. N, function(a) return put(math.sqrt(num(a))) end)
    low = low:gsub(N .. '%s*do%s*kwadratu', function(a) return put(num(a) ^ 2) end)
    low = low:gsub(N .. '%s*do%s*szescianu', function(a) return put(num(a) ^ 3) end)
    low = low:gsub(N .. '%s*do%s*potegi%s*' .. N, function(a, b) return put(num(a) ^ num(b)) end)
    low = low:gsub(N .. '%s*%%%s*z%s*' .. N, function(a, b) return put(num(a) * num(b) / 100) end)
    low = low:gsub(N .. '%s*procent%a*%s*z%s*' .. N, function(a, b) return put(num(a) * num(b) / 100) end)
    low = low:gsub('pomnoz%s*' .. N .. '%s*przez%s*' .. N, function(a, b) return put(num(a) * num(b)) end)
    low = low:gsub('podziel%s*' .. N .. '%s*przez%s*' .. N, function(a, b) return put(num(a) / num(b)) end)
    low = low:gsub('dodaj%s*' .. N .. '%s*do%s*' .. N, function(a, b) return put(num(a) + num(b)) end)
    low = low:gsub('odejmij%s*' .. N .. '%s*od%s*' .. N, function(a, b) return put(num(b) - num(a)) end)
    low = low:gsub('(%d)%s+plus%s+', '%1 + '):gsub('(%d)%s+minus%s+', '%1 - '):gsub('(%d)%s+razy%s+', '%1 * ')
    low = low:gsub('(%d)%s+podzielone%s+przez%s+', '%1 / '):gsub('(%d)%s+pomnozone%s+przez%s+', '%1 * ')
    return low, changed, lastv
end

local function expr_value(low)
    local s = low:gsub('(%d),(%d)', '%1.%2')
    for run in s:gmatch('[%d%.%s%+%-%*/x:%^%(%)]+') do
        local e = trim(run):gsub('^[x:%s]+', ''):gsub('[x:%s%+%-%*/%^]+$', '')
        if e:find('%d%s*[%+%-%*/x:%^]%s*[%(%-]?%s*%d') then
            local ok, v = pcall(parse_math, e)
            if ok and type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
        end
    end
    return nil
end

function solve_math(low, cands)
    local sources = {}
    if cands then
        for _, c in ipairs(cands) do sources[#sources + 1] = cp1250_to_ascii(c):lower() end
    end
    sources[#sources + 1] = low
    local unsolved = nil
    for _, src in ipairs(sources) do
        local run = seq_extract(src)
        if run then
            local v = seq_solve(run)
            if v then return fmt_number(v), 'ciag' end
            unsolved = unsolved or run
        else
            local x = eq_solve(src)
            if x then return fmt_number(x), 'rownanie' end
            local w, changed, lastv = math_words(src)
            local v = expr_value(w)
            if v then return fmt_number(v) end
            if changed and lastv then return fmt_number(lastv) end
        end
    end
    return nil, nil, unsolved
end

end -- matematyka

--------------------------------------------------------------------------------
-- BAZA ODPOWIEDZI
--------------------------------------------------------------------------------

local DB = { file = getWorkingDirectory() .. '\\config\\sampgpt_baza.txt', data = {}, count = 0 }

function DB.key(s)
    s = cp1250_to_ascii(tostring(s or '')):lower():gsub('[^%w%s]', ' '):gsub('%s+', ' ')
    return trim(s)
end

function DB.load()
    DB.data, DB.count = {}, 0
    local d = read_file(DB.file)
    if not d then return end
    local lines = 0
    for line in d:gmatch('[^\r\n]+') do
        local kind, key, ans = line:match('^(%w+)\t([^\t]+)\t(.+)$')
        if kind then
            lines = lines + 1
            DB.data[kind] = DB.data[kind] or {}
            if DB.data[kind][key] == nil then DB.count = DB.count + 1 end
            DB.data[kind][key] = ans
        end
    end
    if lines > DB.count + 200 then
        local out = {}
        for kind, t in pairs(DB.data) do
            for key, ans in pairs(t) do out[#out + 1] = kind .. '\t' .. key .. '\t' .. ans end
        end
        write_file(DB.file, table.concat(out, '\n') .. '\n')
    end
end

function DB.get(kind, key)
    local t = DB.data[kind]
    if not t or not key or key == '' then return nil end
    return t[key]
end

function DB.put(kind, key, ans)
    if not key or key == '' or not ans then return false end
    ans = trim(tostring(ans):gsub('[\t\r\n]', ' '))
    if ans == '' then return false end
    DB.data[kind] = DB.data[kind] or {}
    if DB.data[kind][key] == ans then return false end
    if DB.data[kind][key] == nil then DB.count = DB.count + 1 end
    DB.data[kind][key] = ans
    local f = io.open(DB.file, 'ab')
    if f then
        f:write(kind .. '\t' .. key .. '\t' .. ans .. '\n')
        f:close()
    end
    return true
end

function DB.clear()
    DB.data, DB.count = {}, 0
    os.remove(DB.file)
end

--------------------------------------------------------------------------------
-- WIEDZA O SERWERZE dla /ai
--------------------------------------------------------------------------------

local KB = {
    file = getWorkingDirectory() .. '\\config\\sampgpt_wiedza.txt',
    list = {}, set = {}, tick = 0, last_dialog = nil, MAX = 2000,
    last_cmd = nil, last_cmd_t = -1e9,
}

do

KB.SEED = table.concat({
    'Polski Mega Serwer (samp.gg) - najwiekszy polski serwer SA-MP typu DM/RPG (freeroam). IP: play.samp.gg:7777.'
        .. ' Discord: discord.gg/pms. Gra na PC i Androidzie (launcher open.mp).',
    'Gangi: zaloz albo dolacz do gangu, walczcie o strefy w Los Santos, zdobywajcie respekt (rankingi sezonowe'
        .. ' i ogolne), wspolny skarbiec, baza gangu, pojazd gangu, osiagniecia.',
    'Domy: /Dom - kupno, urzadzanie i zarzadzanie domem; jeden dom na wlasnosc + mozna byc lokatorem w innym;'
        .. ' obiekty w srodku i na zewnatrz, tabliczka, naglosnienie; VIP ma wnetrza premium; osiedla /Tree i'
        .. ' /Underground; trzeba placic czynsz, inaczej traci sie dom.',
    'Lowienie ryb: sprzet kupuje sie w chatce rybackiej (Fishing Hut) i ulepsza razem z plecakiem;'
        .. ' panel ze statystykami i top 10: /Ryby.',
    'Areny: szybka walka z innymi graczami, kazda arena ma swoj zestaw broni (od miniguna po one-shot),'
        .. ' arena Custom z wlasnym zestawem; lider areny i jego zabojca dostaja bonus expa. Pojedynek 1v1: /Solo.',
    'Prace: 8 zawodow (m.in. magazynier, taksowkarz, marynarz, gornik, spedytor) - glowne zrodlo zarobku,'
        .. ' lepiej platne z wyzszym poziomem postaci.',
    'Pojazdy prywatne: kupno w /Salon, tuning w /Warsztat (felgi, lakier, neony); mozna miec kilka aut,'
        .. ' tankowanie na stacjach, auto mozna wystawic na gieldzie albo zezlomowac.',
    'Inne komendy widziane na serwerze: /Pomoc (pomoc i lista komend), /Tele (lista wszystkich teleportow),'
        .. ' /Zadania (zadania do wykonania).',
    'Regulamin: zakaz modow i programow ulatwiajacych gre, spamu, uzywania bugow, przeszkadzania w eventach'
        .. ' i grania na kilku kontach naraz dla korzysci.',
}, '\n')

local STOPW = {}
for w in ('jak jaka jaki jakie gdzie czy jest sie mam moge mozna dla ten tym tak nie czym kto ile mi mnie '
    .. 'what how the and serwer serwerze samp prosze powiedz zrobic robic jesli oraz albo tez'):gmatch('%S+') do
    STOPW[w] = true
end

local HELP_WORDS = {
    'pomoc', 'komend', 'cmd', 'info', 'faq', 'tele', 'aren', 'prac', 'vip', 'regulamin', 'gang', 'dom',
    'zadani', 'event', 'zabaw', 'help', 'command', 'poradnik', 'system',
}
local INFO_WORDS = {
    'wpisz', 'komend', 'uzyj', 'znajdziesz', 'sprawdz', 'zobacz', 'aby ', 'zeby', 'mozesz', 'pod ', 'dostepn', 'wiecej',
}
local NO_CMD = { 'nie ma takiej komend', 'nieznana komend', 'nie znaleziono komend', 'unknown command' }
local INFO_HEADS = {
    info = true, serwer = true, server = true, pomoc = true, porada = true, wskazowka = true, tip = true,
    event = true, zabawa = true, gang = true, dom = true, praca = true, vip = true, system = true,
}

local function any(low, list)
    for _, w in ipairs(list) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

local function fold(s) return cp1250_to_ascii(s):lower() end

function KB.add(text, no_save)
    text = trim(tostring(text or ''))
    local key = DB.key(text)
    if #key < 6 or KB.set[key] or #KB.list >= KB.MAX then return false end
    KB.set[key] = true
    KB.list[#KB.list + 1] = { text = text, low = fold(text) }
    if not no_save then
        local f = io.open(KB.file, 'ab')
        if f then
            f:write(text:gsub('[\r\n]', ' ') .. '\n')
            f:close()
        end
    end
    return true
end

function KB.load()
    local d = read_file(KB.file)
    if not d then return end
    for line in d:gmatch('[^\r\n]+') do KB.add(line, true) end
end

function KB.learn_chat(line)
    if line.prefix ~= '' then return end
    local clean = trim(strip_colors(line.text))
    if KB.last_cmd and now() - KB.last_cmd_t < 3 and any(fold(clean), NO_CMD) then
        KB.add('Komenda ' .. KB.last_cmd .. ' NIE ISTNIEJE na tym serwerze (NOT EXISTING) - nie polecaj jej.')
        KB.last_cmd = nil
    end
    if #clean < 15 or #clean > 200 or not clean:find('/%a%a') then return end
    if clean:find('SAMPGPT', 1, true) or clean:find('[QUIZ-AI]', 1, true) or clean:find('[OX-AI]', 1, true) then return end
    local head = clean:match('^(.-):')
    if head and #head <= 40 then
        local h = fold(trim(head:gsub('^%b[]%s*', '')))
        local nickish = h:match('^%d*%s*[%w_%.%$@=%[%]%-]+%s*%b()$') or h:match('^[%w_%.%$@=%[%]%-]+$')
        if nickish and not INFO_HEADS[h] then return end
    end
    if any(fold(clean), INFO_WORDS) then KB.add(clean) end
end

function KB.learn_dialog(caption, text)
    local helpish = any(fold(caption), HELP_WORDS)
    local n = 0
    for line in (strip_colors(text) .. '\n'):gmatch('([^\n]*)\n') do
        line = trim(line:gsub('\t+', ' - '):gsub('%s+', ' '))
        if #line >= 6 and #line <= 200 and (line:find('/%a') or (helpish and #line >= 12)) then
            if KB.add((caption ~= '' and (caption .. ': ') or '') .. line) then n = n + 1 end
            if n >= 80 then break end
        end
    end
end

function KB.poll_dialog()
    if type(sampIsDialogActive) ~= 'function' or type(sampGetDialogText) ~= 'function' then return end
    if safe_call(sampIsDialogActive) ~= true then
        KB.last_dialog = nil
        return
    end
    local text = safe_call(sampGetDialogText)
    if type(text) ~= 'string' or text == '' or text == KB.last_dialog then return end
    KB.last_dialog = text
    KB.learn_dialog(trim(strip_colors(tostring(safe_call(sampGetDialogCaption) or ''))), text)
end

function KB.context(question)
    local stems = {}
    for w in fold(question):gmatch('%w+') do
        if #w >= 3 and not STOPW[w] then
            stems[#stems + 1] = w:sub(1, math.min(6, math.max(3, #w - 2)))
        end
    end
    local scored = {}
    for _, e in ipairs(KB.list) do
        local sc = 0
        for _, st in ipairs(stems) do
            if e.low:find(st, 1, true) then sc = sc + 1 end
        end
        if sc > 0 then scored[#scored + 1] = { e = e, s = sc } end
    end
    table.sort(scored, function(a, b) return a.s > b.s end)
    local out, total = {}, 0
    for _, e in ipairs(KB.list) do
        if #out < 15 and e.text:find('NIE ISTNIEJE', 1, true) then
            out[#out + 1] = '- ' .. e.text
            total = total + #e.text
        end
    end
    for i = 1, math.min(#scored, 12) do
        local t = scored[i].e.text
        if t:find('NIE ISTNIEJE', 1, true) then t = nil end
        if t and total + #t > 1500 then break end
        if t then
            out[#out + 1] = '- ' .. t
            total = total + #t
        end
    end
    local ctx = 'SERVER KNOWLEDGE (the player is on Polski Mega Serwer, samp.gg - a typical Polish freeroam DM/RPG server):\n'
        .. KB.SEED
    if #out > 0 then
        ctx = ctx .. '\nLEARNED FROM THE SERVER ITSELF (help dialogs, server tips):\n' .. game_to_utf8(table.concat(out, '\n'))
    end
    return ctx
end

end -- wiedza

do
--------------------------------------------------------------------------------
-- QUIZ: zabawy serwera na czacie i w ramkach na ekranie.
--------------------------------------------------------------------------------

local W = {}
local Q = {}

local function has_any(low, list)
    for _, w in ipairs(list) do
        if low:find(w, 1, true) then return true end
    end
    return false
end

local function fold(s) return cp1250_to_ascii(s):lower() end

W.CONTEST = {
    'kto pierwszy', 'kto 1', 'kto jako pierwszy', 'pierwsza osoba', 'pierwszy gracz', 'pierwszy kto',
    'first to', 'first player', 'zabaw', 'konkurs', 'reakcj', 'wygrywa', 'nagrod', 'event', 'quiz',
}
W.IGNORE = {
    'wygral', 'wygrala', 'wygrali', 'zwyciez', 'prawidlowa odpowiedz', 'poprawna odpowiedz',
    'poprawnie odpowiedzial', 'odpowiedzia bylo', 'nikt nie', 'zakonczon', 'przerwan', 'anulowan',
    'brak graczy', 'dolacz', 'zapisy', 'zapisz sie', 'rozpocznie', 'za chwile', 'napisal', 'pm od',
    'pm do', 'prywatn', 'szept', 'whisper',
}
W.MATH_STRONG = {
    'oblicz', 'policz', 'ile to', 'ile jest', 'ile wynosi', 'rozwiaz', 'dzialani', 'rownani', 'ciag liczb',
    'kolejna liczb', 'nastepna liczb', 'brakujaca liczb', 'calculate', 'solve', 'sequence',
}
W.MATH_WEAK = { 'wynik', 'matematyk', 'math', 'ciag' }
W.COPY_VERBS = { 'przepisz', 'wpisz', 'napisz', 'type', 'copy' }
W.COPY_MARKS = { 'kod', 'tekst', 'haslo', 'ciag', 'code', 'text', 'wyraz', 'slowo', 'zdanie' }
W.REVERSE_WORDS = { 'od tylu', 'odwrot', 'wspak', 'reverse', 'backwards' }
W.SCRAMBLE_WORDS = {
    'rozsypank', 'anagram', 'przestaw', 'pomieszan', 'unscramble',
    'uloz slowo', 'uloz wyraz', 'ulozy slowo', 'ulozy wyraz', 'z liter',
}
W.QUESTION_HEADS = { 'pytanie:', 'pytanie -', 'zagadka:', 'quiz:', 'question:' }
W.OX_WORDS = {
    '[ox]', ' ox ', ' ox:', 'ox -', 'zabawa ox', 'prawda czy falsz', 'prawda/falsz', 'prawda lub falsz',
    'true or false', 'o/x',
}
W.OX_ROUND_HINTS = {
    'runda', 'pytanie', 'nastepne', 'kolejne', 'sekund', 'czas na', 'idz na', 'wybierz', 'stan na',
    'odliczani', 'round', 'question',
}
W.OX_TD_SKIP = { 'prawda', 'falsz', 'pozostal', 'graczy', 'runda', 'sekund', 'wygral', 'odpad', 'czas' }
W.VEH_WORDS = { 'pojazd', 'samochod', 'nazwe auta', 'nazwa auta', 'to auto', 'model auta', 'vehicle' }
W.SKIN_WORDS = { 'skin', 'jaka to postac', 'id postaci' }
W.IMG_WORDS = { 'obrazk', 'zdjeci', 'na ekranie', 'widzisz', 'jaki to', 'jakie to', 'zgadnij', 'odgadnij', 'nazwe', 'nazwa' }
W.TD_STRONG = {
    'rozsypank', 'rebus', 'oblicz', 'policz', 'przepisz', 'od tylu', 'wspak', 'zgadnij', 'odgadnij',
    'prawda czy falsz', 'anagram', 'matematyk', 'ciag', 'rownani', 'dzialani',
}
W.TD_TRIGGERS = {
    'rozsypank', 'anagram', 'uloz', 'rebus', 'oblicz', 'policz', 'przepisz', 'wpisz', 'napisz',
    'pytanie', 'zagadk', 'quiz', 'od tylu', 'wspak', 'pojazd', 'skin', 'prawda czy falsz', 'zgadnij', 'odgadnij', 'matematyk', 'ciag', 'rownani', 'dzialani', 'reakcj', 'kalkul',
}
W.STOP = {}
for w in ('rozsypanka rozsypanki rozsypanke slowo slowa wyraz wyrazu liter litery z ze i w na do kto pierwszy '
    .. 'pierwsza uloz ulozy ulozyc wygrywa wygra nagrode nagroda otrzyma dostanie zabawa konkurs reakcja '
    .. 'anagram przestaw haslo kod tekst sekund sekundy pkt punkt punkty exp respekt trwa czas'):gmatch('%S+') do
    W.STOP[w] = true
end

W.ANS_PAT = {
    'poprawn%a* odpowiedz%a*[^:]-:%s*()', 'prawidlow%a* odpowiedz%a*[^:]-:%s*()',
    'poprawn%a* odpowiedz%a* to%s+()', 'prawidlow%a* odpowiedz%a* to%s+()',
    'odpowiedz%a* brzmial%a*:?%s+()', 'odpowiedzia bylo:?%s+()', 'poprawne haslo:?%s+()',
    'haslo brzmial%a*:?%s+()', 'haslem bylo:?%s+()', 'poprawn%a* odpowiedz%a*%s+()',
}
W.WIN_WORDS = {
    'wygral', 'wygrala', 'wygrywa', 'zwyciez', 'jako pierwszy', 'jako pierwsza',
    'poprawnie odpowiedzial', 'odpowiedzial poprawnie', 'zgarnia', 'otrzymuje nagrod',
}
W.OX_END = { 'zakonczon', 'koniec', 'wygral', 'wygrala', 'zwyciez' }
W.OPEN_Q = {}
for w in ('jak jaki jaka jakie jakiego ile kto kogo co czego gdzie kiedy ktory ktora ktore dlaczego czemu '
    .. 'skad dokad what who how where when which why'):gmatch('%S+') do
    W.OPEN_Q[w] = true
end
W.SKIP = { 'odgadnij liczb', 'zgadnij liczb', 'z przedzialu', 'z zakresu', 'przedzial' }
local skip_until = 0
W.NOISE = {
    'zabojstw', 'smierc', 'zgon', 'kills', 'deaths', 'k/d', 'zabil', 'zabity', 'zabita', 'zginal', 'zginela',
    'killstreak', 'seria zab', 'ratio',
}
W.HANG_WORDS = {
    'wisielec', 'wisielca', 'uzupelnij', 'brakujac', 'luk', 'odgadnij haslo', 'zgadnij haslo',
    'odgadnij slowo', 'zgadnij slowo', 'haslo', 'litery',
}

local recent = {}
local function seen_recently(key, ttl)
    local t = recent[key]
    if t and now() - t < (ttl or 30) then return true end
    recent[key] = now()
    return false
end

local function is_player_line(clean)
    local head = clean:match('^(.-):')
    if not head or #head > 45 then return false end
    head = trim(head:gsub('^%b[]%s*', ''))
    local lh = fold(head)
    if has_any(lh, W.CONTEST) or has_any(lh, W.TD_TRIGGERS) or has_any(lh, W.COPY_MARKS) or has_any(' ' .. lh .. ' ', W.OX_WORDS) then
        return false
    end
    return head:match('^%d*%s*[%w_%.%$@=%[%]%-]+%s*%b()$') ~= nil
        or head:match('^%d*%s*[%w_%.%$@=%-]+%s*%b[]$') ~= nil
        or head:match('^%d*%s*[%w_%.%$@=%[%]%-]+$') ~= nil
end

function Q.is_counter(t)
    return t:match('^%d+$') or t:match('^%d+[:/%.]%d+$') or t:match('^%d+%s*s$') or t:match('^%d+%s*sek')
end

function Q.strip_tok(t)
    t = t:gsub('^[%s"\'%(%[]+', ''):gsub('[%s"\'%)%]!,;%.]+$', '')
    return t
end

function Q.codeish(w)
    return w ~= nil and #w >= 3 and (w:find('%d') ~= nil or (w:find('%l') ~= nil and w:find('%u') ~= nil))
end

function Q.good_token(t)
    return t and #t >= 2 and #t <= 60 and not t:find('^/')
end

function Q.extract_token(clean, cands)
    if cands then
        for _, c in ipairs(cands) do
            if not c:find('%s') and not c:find(':%s*$') and not fold(c):find('^poziom') and Q.good_token(c) and not W.STOP[fold(c)] then return c end
        end
    end
    local q = clean:match('"([^"]+)"') or clean:match("'([^']+)'")
    if Q.good_token(q) then return trim(q) end
    local tail = clean:match(':%s*(.+)$')
    if tail then
        tail = tail:gsub('%s+[%(%[].*$', '')
        local first = tail:match('^(%S+)')
        if first and (not tail:find('%s') or Q.codeish(first)) then
            first = Q.strip_tok(first)
            if Q.good_token(first) then return first end
        end
    end
    local after = clean:match('[Kk][Oo][Dd]%a*%s+(%S+)')
    if Q.codeish(after) then
        after = Q.strip_tok(after)
        if Q.good_token(after) then return after end
    end
    return nil
end

function Q.extract_phrase(clean)
    local tail = clean:match(':%s*(.+)$')
    if not tail then return nil end
    local low = fold(tail)
    local cutpos = nil
    for _, w in ipairs({ ' wygrywa', ' otrzyma', ' dostanie', ' zdobywa', ' (', ' [' }) do
        local p = low:find(w, 1, true)
        if p and (not cutpos or p < cutpos) then cutpos = p end
    end
    if cutpos then tail = tail:sub(1, cutpos - 1) end
    tail = Q.strip_tok(trim(tail))
    if Q.good_token(tail) then return tail end
    return nil
end

function Q.extract_scramble(clean, cands)
    local function ok(w)
        return w and #w >= 3 and #w <= 25 and w:match('^[^%s%d%p]+$') ~= nil and not W.STOP[fold(w)]
    end
    if cands then
        for _, c in ipairs(cands) do
            c = Q.strip_tok(c)
            if ok(c) then return c end
        end
    end
    local q = clean:match('"([^"]+)"') or clean:match("'([^']+)'")
    if ok(q) then return q end
    local tail = clean:match(':%s*(.+)$')
    if tail then
        local first = tail:match('^(%S+)')
        first = first and Q.strip_tok(first)
        if ok(first) then return first end
    end
    local best = nil
    for w in clean:gmatch('%S+') do
        w = Q.strip_tok(w)
        if ok(w) and w == w:upper() and w:find('%u') then best = w end
    end
    return best
end

function Q.first_word(txt)
    return clean_answer(txt):match('^[%s"\']*([^%s"\'%.!,;:]+)') or ''
end

function Q.letters_key(s)
    local t = {}
    for c in s:lower():gmatch('%a') do t[#t + 1] = c end
    table.sort(t)
    return table.concat(t)
end

function Q.is_anagram(ans_ascii, scr)
    local a = Q.letters_key(ans_ascii)
    return #a >= 3 and a == Q.letters_key(cp1250_to_ascii(scr))
end

W.CP_LOWER = { [0xA5] = 0xB9, [0xC6] = 0xE6, [0xCA] = 0xEA, [0xA3] = 0xB3, [0xD1] = 0xF1,
    [0xD3] = 0xF3, [0x8C] = 0x9C, [0x8F] = 0x9F, [0xAF] = 0xBF }
W.CP_UPPER = {}
for u, l in pairs(W.CP_LOWER) do W.CP_UPPER[l] = u end

function Q.restore_diacritics(ans, scr)
    if not scr:find('[\128-\255]') then return ans end
    local pool = {}
    for i = 1, #scr do
        local b = scr:byte(i)
        b = W.CP_LOWER[b] or b
        local ch = string.char(b):lower()
        local f = cp1250_to_ascii(ch):lower()
        if f:match('^%a$') then
            pool[f] = pool[f] or {}
            pool[f][#pool[f] + 1] = ch
        end
    end
    local out = {}
    for i = 1, #ans do
        local c = ans:sub(i, i)
        local lc = c:lower()
        local list = pool[lc]
        if list and #list > 0 then
            local pick = table.remove(list, 1)
            if c ~= lc then
                local pb = pick:byte()
                pick = pb >= 128 and string.char(W.CP_UPPER[pb] or pb) or pick:upper()
            end
            out[#out + 1] = pick
        else
            out[#out + 1] = c
        end
    end
    return table.concat(out)
end

W.BAD_ANSWERS = {
    'nie widz', 'nie mog', 'nie podano', 'nie ma ', 'brak ', 'none', 'cannot', "can't", 'unable',
    'no rebus', 'not sure', 'nie wiem', 'niemozliw', 'nie jest ', 'obrazk', 'screen',
}
local function plausible(a)
    a = clean_answer(a)
    if a == '' or #a > 40 or a:find('^/') then return false end
    local words = 0
    for _ in a:gmatch('%S+') do words = words + 1 end
    if words > 5 then return false end
    local low = a:lower()
    for _, b in ipairs(W.BAD_ANSWERS) do
        if low:find(b, 1, true) then return false end
    end
    return true
end

local VEH_BY_NORM = nil
function Q.norm_name(s) return (clean_answer(s):lower():gsub('[^%w]', '')) end
function Q.match_vehicle(txt)
    if not VEH_BY_NORM then
        VEH_BY_NORM = {}
        for id = 400, 611 do VEH_BY_NORM[Q.norm_name(VEHICLE_NAMES[id])] = id end
    end
    return VEH_BY_NORM[Q.norm_name(txt)]
end

local function silent() end

local pending_q = nil

local function remember_question(kind, key, given)
    if key and key ~= '' then pending_q = { kind = kind, key = key, given = given, t = now() } end
end

local function set_given(kind, key, given)
    if pending_q and pending_q.kind == kind and pending_q.key == key then pending_q.given = given end
end

local nick_low = nil
local function my_nick_lower()
    if not nick_low then
        local n = safe_call(sampGetLocalPlayerNickname)
        if type(n) ~= 'string' or n == '' then n = get_local_context().nick end
        if type(n) == 'string' and n ~= '' then nick_low = n:lower() end
    end
    return nick_low
end

local function learn(clean, low)
    local p = pending_q
    if not p or now() - p.t > 180 then return end
    local ans = nil
    for _, pat in ipairs(W.ANS_PAT) do
        local pos = low:match(pat)
        if pos then
            ans = clean:sub(pos):gsub('%s*[%(%[|].*$', '')
            ans = trim(Q.strip_tok(trim(ans)))
            ans = trim(ans:match('^([^%.!]+)') or ans)
            if ans == '' or #ans > 60 then ans = nil end
            break
        end
    end
    if ans then
        if p.kind == 'ox' then
            local la = fold(ans)
            local v = nil
            if la:find('prawda', 1, true) or la == 'o' or la:find('true', 1, true) then v = 'O' end
            if la:find('falsz', 1, true) or la == 'x' or la:find('false', 1, true) then v = 'X' end
            if v then DB.put('ox', p.key, v) end
        elseif DB.put(p.kind, p.key, ans) and p.given and fold(p.given) ~= fold(ans) then
            chat_print(INFO_PREFIX .. 'Zapamietano poprawna odpowiedz: ' .. game_to_utf8(ans))
        end
        pending_q = nil
        return
    end
    local nick = my_nick_lower()
    if p.given and nick and low:find(nick, 1, true) and has_any(low, W.WIN_WORDS) then
        DB.put(p.kind, p.key, p.given)
        pending_q = nil
    end
end

function Q.qtext(clean)
    local s = clean:gsub('^%b[]%s*', '')
    local head, tail = s:match('^(.-):%s*(.+)$')
    if head and #head <= 25 then s = tail end
    return s
end

local function scramble_ai(tok)
    local letters = fold(tok):gsub('[^%a]', '')
    local shown = game_to_utf8(tok)
    local key = Q.letters_key(cp1250_to_ascii(tok))
    local hit = DB.get('s', key)
    if hit then
        deliver_answer(hit, 0, { extra = 'rozsypanka, z bazy' })
        remember_question('s', key, hit)
        return
    end
    remember_question('s', key, nil)
    ai_request({
        prompt = 'Unscramble the letters "' .. shown .. '" into ONE real word - usually a common Polish noun '
            .. '(it can also be a name or a GTA/SA-MP related word). Use every letter exactly once ('
            .. #letters .. ' letters: ' .. letters:upper():gsub('.', '%0 ') .. '). Reply with ONLY the word.',
        models = CONFIG.models_scramble,
        quiet = true,
        quiz = true,
        validate = function(txt) return Q.is_anagram(Q.first_word(txt), tok) end,
        on_answer = function(txt, dt)
            local ans = Q.restore_diacritics(Q.first_word(txt), tok)
            deliver_answer(ans, dt, { extra = 'rozsypanka ' .. shown })
            set_given('s', key, ans)
        end,
        on_fail = function(err, rejected)
            if rejected then
                chat_print(QUIZ_PREFIX .. '{AAAAAA}rozsypanka ' .. shown .. ': brak pewnej odpowiedzi ('
                    .. clean_answer(rejected):sub(1, 25) .. '?)')
            end
        end,
    })
end

local function question_ai(clean)
    local key = DB.key(Q.qtext(clean))
    local hit = DB.get('q', key)
    if hit then
        deliver_answer(hit, 0, { extra = 'z bazy' })
        remember_question('q', key, hit)
        return
    end
    remember_question('q', key, nil)
    ai_request({
        prompt = 'A SA-MP server posted this quiz message: "' .. game_to_utf8(clean) .. '". '
            .. 'If it is a quiz question or contest task for players, reply with ONLY the exact answer to type '
            .. '(a word, number or very short phrase, in the language of the question). '
            .. 'If it is NOT a question or task to answer, reply exactly: NONE',
        models = CONFIG.models_quiz,
        quiet = true,
        quiz = true,
        validate = function(txt)
            local a = clean_answer(txt)
            return a:upper() == 'NONE' or plausible(a)
        end,
        on_answer = function(txt, dt)
            local a = clean_answer(txt)
            if a:upper() ~= 'NONE' then
                deliver_answer(a, dt)
                set_given('q', key, a)
            end
        end,
        on_fail = silent,
    })
end

function Q.extract_pattern(clean)
    local best = nil
    local function consider(p)
        p = p:gsub('%*', '_')
        if #p >= 3 and p:find('_', 1, true) and p:match('^[%w_\128-\255]+$') and not p:match('^%u%l+_%u%l+$')
            and (not best or #p > #best) then
            best = p
        end
    end
    local group = {}
    local function flush()
        if #group >= 3 then consider(table.concat(group)) end
        group = {}
    end
    for t in clean:gmatch('%S+') do
        if #t == 1 and t:match('^[%w_%*\128-\255]$') then
            group[#group + 1] = t
        else
            flush()
            t = Q.strip_tok(t)
            if t:find('[_%*]') then consider(t) end
        end
    end
    flush()
    return best
end

function Q.hangman_fit(word, pat)
    local a, p = fold(word), fold(pat)
    if #a ~= #p then return false end
    for i = 1, #p do
        local c = p:sub(i, i)
        if c ~= '_' and c ~= a:sub(i, i) then return false end
    end
    return true
end

local function hangman_ai(pat, clean)
    local key = DB.key(clean)
    local hit = DB.get('h', key)
    if hit then
        deliver_answer(hit, 0, { extra = 'wisielec, z bazy' })
        remember_question('h', key, hit)
        return
    end
    remember_question('h', key, nil)
    ai_request({
        prompt = 'Word puzzle from a SA-MP server: "' .. game_to_utf8(clean) .. '". Find the word matching the pattern "'
            .. game_to_utf8(pat) .. '" (' .. #pat .. ' letters, _ = missing letter). It is usually a common Polish word. '
            .. 'Reply with ONLY the word.',
        models = CONFIG.models_scramble,
        quiet = true,
        quiz = true,
        validate = function(txt) return Q.hangman_fit(Q.first_word(txt), pat) end,
        on_answer = function(txt, dt)
            local w = Q.first_word(txt):lower()
            local out = {}
            for i = 1, #pat do
                local c = pat:sub(i, i)
                out[i] = (c ~= '_' and c:byte() >= 128) and c or w:sub(i, i)
            end
            local ans = table.concat(out)
            if not pat:find('%l') then
                ans = ans:upper()
            elseif pat:sub(1, 1):find('%u') then
                ans = ans:sub(1, 1):upper() .. ans:sub(2)
            end
            deliver_answer(ans, dt, { extra = 'wisielec ' .. game_to_utf8(pat) })
            set_given('h', key, ans)
        end,
        on_fail = silent,
    })
end

local function ox_statement(clean, cands)
    if cands then
        local best = nil
        for _, c in ipairs(cands) do
            local _, n = c:gsub('%S+', '')
            if n >= 3 and (not best or #c > #best) then best = c end
        end
        return best
    end
    local s = clean:gsub('^%b[]%s*', '')
    local head, tail = s:match('^(.-):%s*(.+)$')
    if head then
        local lh = fold(head)
        if lh:find('ox', 1, true) or lh:find('prawda', 1, true) or lh:find('pytanie', 1, true) then s = tail end
    end
    s = trim(s:gsub('^[Oo][Xx]%s*[%-:]?%s*', ''))
    local _, n = s:gsub('%S+', '')
    if n < 3 or s:find('/%a') then return nil end
    return s
end

local function find_ox_zone(yes)
    if not CONFIG.ox_guide or type(sampIs3dTextDefined) ~= 'function' or type(sampGet3dTextInfoById) ~= 'function' then
        return nil
    end
    local px, py, pz = safe_call(getCharCoordinates, PLAYER_PED)
    if not px then return nil end
    local best, bestd = nil, nil
    for id = 0, 2047 do
        local okd, def = pcall(sampIs3dTextDefined, id)
        if okd and def == true then
            local ok, text, _, x, y, z = pcall(sampGet3dTextInfoById, id)
            if ok and type(text) == 'string' and tonumber(x) then
                local t = trim(fold(strip_colors(text)):gsub('%s+', ' '))
                local is_yes = t:find('prawda', 1, true) or t:find('true', 1, true) or t == 'o' or t == 'tak'
                local is_no = t:find('falsz', 1, true) or t:find('false', 1, true) or t == 'x' or t == 'nie'
                if (yes and is_yes and not is_no) or (not yes and is_no and not is_yes) then
                    local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
                    if d < 200 and (not bestd or d < bestd) then
                        best, bestd = { x = x, y = y, z = z }, d
                    end
                end
            end
        end
    end
    if best then best.dist = bestd end
    return best
end

local atan2 = math.atan2 or math.atan
local function direction_text(zone)
    local dist = math.floor(zone.dist + 0.5) .. ' m'
    local px, py = safe_call(getCharCoordinates, PLAYER_PED)
    local h = safe_call(getCharHeading, PLAYER_PED)
    if not px or not h then return dist end
    local target = math.deg(atan2(-(zone.x - px), zone.y - py))
    local rel = (target - h + 540) % 360 - 180
    local side
    if math.abs(rel) <= 45 then
        side = 'przed Toba'
    elseif rel > 45 and rel < 135 then
        side = 'po lewej'
    elseif rel < -45 and rel > -135 then
        side = 'po prawej'
    else
        side = 'za Toba'
    end
    return side .. ', ' .. dist
end

local function ox_verdict(yes, stmt, dt, src)
    local label = yes and 'O - PRAWDA' or 'X - FALSZ'
    if stmt then remember_question('ox', DB.key(stmt), yes and 'O' or 'X') end
    local zone = find_ox_zone(yes)
    local where = zone and direction_text(zone) or nil
    chat_print('{FFCC00}[OX-AI] ' .. (yes and '{33FF33}' or '{FF4444}') .. label
        .. (where and (' {FFFFFF}' .. where) or '')
        .. (stmt and (' {AAAAAA}(' .. game_to_utf8(stmt):sub(1, 40) .. ')') or '')
        .. (src and (' {777777}' .. src) or (time_suffix(dt) or '')))
    show_big((yes and '~g~' or '~r~') .. label .. (where and ('~n~~w~' .. where) or ''), '', true)
    hud_answer(label .. (where and (' - ' .. where) or ''), 'OX', dt)
    HUD.ox = yes
    play_sound()
    if zone then
        ox_marker = { x = zone.x, y = zone.y, z = zone.z, label = label, yes = yes, until_t = now() + 12 }
    end
end

local function ox_ai(stmt)
    local hit = DB.get('ox', DB.key(stmt))
    if hit then
        ox_verdict(hit == 'O', stmt, 0, 'z bazy')
        return
    end
    ai_request({
        prompt = 'True/false (O/X) quiz on a SA-MP server. Statement or question: "' .. game_to_utf8(stmt) .. '". '
            .. 'Is it true? Reply with ONLY one word: TRUE or FALSE.',
        models = CONFIG.models_quiz,
        quiet = true,
        quiz = true,
        validate = function(txt)
            local a = clean_answer(txt):upper()
            return (a:find('TRUE') or a:find('FALSE') or a:find('PRAWDA') or a:find('FALSZ')) ~= nil
        end,
        on_answer = function(txt, dt)
            local a = clean_answer(txt):upper()
            ox_verdict((a:find('TRUE') or a:find('PRAWDA')) ~= nil and not a:find('FALSE'), stmt, dt)
        end,
        on_fail = silent,
    })
end

function start_ox_vision(auto)
    if not auto and ox_manual ~= false then ox_until = math.max(ox_until, now() + CONFIG.ox_session_min * 60) end
    ai_request({
        prompt = 'An O/X (true or false) quiz is running on a SA-MP server. Read the question or statement that is '
            .. 'shown on the screen right now (usually big text in the middle or at the top; ignore the chat, HUD, '
            .. 'minimap and kill list) and decide whether it is true. Reply exactly in the format: '
            .. 'TRUE | statement  or  FALSE | statement  (the statement as you read it). '
            .. 'If no such statement is visible, reply exactly: NONE',
        context = 'Image is the main source of truth.',
        extra_context = td_context,
        models = CONFIG.models_vision_fast,
        screenshot = true,
        delay = auto and 300 or 0,
        quiet = auto,
        quiz = auto,
        validate = function(txt)
            local a = clean_answer(txt):upper()
            return (a:find('^NONE') or a:find('^TRUE') or a:find('^FALSE')) ~= nil
        end,
        on_answer = function(txt, dt)
            local a = clean_answer(txt)
            local up = a:upper()
            if up:find('^NONE') then
                if not auto then chat_print(INFO_PREFIX .. 'Nie widze pytania OX na ekranie.') end
                return
            end
            local stmt = a:match('|%s*(.+)$')
            if stmt and seen_recently('oxs' .. stmt:lower(), 45) and auto then return end
            local hit = stmt and DB.get('ox', DB.key(stmt))
            if hit then
                ox_verdict(hit == 'O', stmt, dt, 'z bazy')
            else
                ox_verdict(up:find('^TRUE') ~= nil, stmt, dt)
            end
        end,
        on_fail = auto and silent or nil,
    })
end

local function vehicle_vision()
    ai_request({
        prompt = 'This SA-MP screen shows a picture of a GTA San Andreas vehicle for a "guess the vehicle" quiz '
            .. '(usually inside a box or panel). Which vehicle is it? Reply with ONLY its exact GTA San Andreas name.',
        context = 'Image is the main source of truth.',
        models = CONFIG.models_vision_fast,
        screenshot = true,
        quiet = true,
        quiz = true,
        validate = function(txt) return Q.match_vehicle(txt) ~= nil end,
        on_answer = function(txt, dt)
            local id = Q.match_vehicle(txt)
            deliver_answer(VEHICLE_NAMES[id], dt, { display = 'POJAZD: ' .. VEHICLE_NAMES[id] .. ' (ID ' .. id .. ', z obrazka)' })
        end,
        on_fail = silent,
    })
end

local function image_quiz(kind)
    quiz_img_until = now() + 20
    for _, td in ipairs(scan_model_textdraws()) do
        local m = td.model
        if (kind == 'veh' and m >= 400 and m <= 611) or (kind == 'skin' and m >= 0 and m <= 311) then
            td_deliver(m, true)
            return
        end
    end
    if kind == 'veh' and CONFIG.vehicle_vision_fallback then
        lua_thread.create(function()
            wait(1500)
            if now() - td_last_full_t < 3 then return end
            for _, td in ipairs(scan_model_textdraws()) do
                if td.model >= 400 and td.model <= 611 then
                    td_deliver(td.model, true)
                    return
                end
            end
            vehicle_vision()
        end)
    end
end

W.REBUS_PROMPT = 'Solve the Polish rebus shown on this GTA SA-MP screen. It is usually inside a box or panel '
    .. 'with pictures, letters and signs - ignore the game world, HUD, minimap, chat and kill list. '
    .. 'Rebus rules: each picture is a Polish word (singular, nominative unless shown otherwise); letters with '
    .. 'a minus or crossed out are removed from that word; "A=O" or "A->O" replaces letters; numbers tell which '
    .. 'letters to keep or their order; a picture drawn upside down is read backwards; letters or syllables '
    .. 'written next to pictures are added; "+" joins the parts. The solution is a real Polish word, name or '
    .. 'short common phrase. Work it out carefully and check that the result is a real word.'

function start_rebus(auto)
    ai_request({
        prompt = W.REBUS_PROMPT,
        context = 'Image is the main source of truth.',
        extra_context = td_context,
        models = CONFIG.models_rebus,
        screenshot = true,
        image_width = CONFIG.rebus_image_width,
        delay = auto and 400 or 0,
        structured = true,
        quiet = auto,
        quiz = auto,
        on_answer = function(txt, dt)
            local a, e = split_answer(txt)
            if not plausible(a) then
                chat_print(QUIZ_PREFIX .. '{AAAAAA}rebus: ' .. clean_answer(txt):sub(1, 90))
                return
            end
            deliver_answer(a, dt, { extra = e })
        end,
    })
end

local function seq_ai(run)
    local parts = {}
    for _, v in ipairs(run) do parts[#parts + 1] = v == '?' and '?' or fmt_number(v) end
    local shown = table.concat(parts, ', ')
    ai_request({
        prompt = 'Number sequence puzzle: ' .. shown .. '. Find the missing number marked "?". '
            .. 'Reply with ONLY the number.',
        models = CONFIG.models_scramble,
        quiet = true,
        quiz = true,
        validate = function(txt) return clean_answer(txt):match('^%-?%d+[%.,]?%d*$') ~= nil end,
        on_answer = function(txt, dt) deliver_answer(clean_answer(txt), dt, { extra = 'ciag ' .. shown }) end,
        on_fail = silent,
    })
end

local function box_ai(text)
    ai_request({
        prompt = 'A SA-MP server shows this reaction-game box on screen: "' .. game_to_utf8(text) .. '". '
            .. 'Give ONLY the exact answer a player has to type in chat to win (a word, number or short phrase). '
            .. 'If there is nothing to answer, reply exactly: NONE',
        models = CONFIG.models_scramble,
        quiet = true,
        quiz = true,
        validate = function(txt)
            local a = clean_answer(txt)
            return a:upper() == 'NONE' or plausible(a)
        end,
        on_answer = function(txt, dt)
            local a = clean_answer(txt)
            if a:upper() ~= 'NONE' then deliver_answer(a, dt, { extra = 'ramka' }) end
        end,
        on_fail = silent,
    })
end

local function solve(clean, cands, from_td)
    local low = fold(clean)
    local padded = ' ' .. low .. ' '
    local ox_mention = has_any(padded, W.OX_WORDS)
    if ox_mention then
        local was = ox_active()
        if has_any(low, W.OX_END) then
            ox_until = math.min(ox_until, now() + 15)
        else
            ox_until = now() + CONFIG.ox_session_min * 60
            if not was and ox_active() then
                chat_print('{FFCC00}[OX-AI] {FFFFFF}Wykryto zabawe OX - tryb OX wlaczony {AAAAAA}(Insert > SAMPGPT wylacza)')
            end
        end
    end
    if has_any(low, W.IGNORE) then return false end
    local contest = has_any(low, W.CONTEST) or (from_td and has_any(low, W.TD_STRONG))
    local t0 = now()
    if ox_mention then
        local stmt = ox_statement(clean, cands)
        if not stmt then return false end
        if not seen_recently('ox' .. fold(stmt), 60) then ox_ai(stmt) end
        return true
    end
    if ox_active() and not from_td then
        local first = DB.key(Q.qtext(clean)):match('^(%a+)')
        if low:find('?', 1, true) and not (first and W.OPEN_Q[first]) then
            local stmt = ox_statement(clean, nil)
            if stmt then
                if not seen_recently('ox' .. fold(stmt), 60) then ox_ai(stmt) end
                return true
            end
        end
        if CONFIG.ox_auto_vision and has_any(low, W.OX_ROUND_HINTS) and not low:find('?', 1, true)
            and not low:find('pytanie:', 1, true) then
            if not seen_recently('oxv', 6) then start_ox_vision(true) end
            return true
        end
    end
    if low:find('rebus', 1, true) and (contest or from_td) and not low:find('/%a') then
        if CONFIG.auto_rebus and not seen_recently('rebus', 120) then start_rebus(true) end
        return true
    end
    local veh, skin = has_any(low, W.VEH_WORDS), has_any(low, W.SKIN_WORDS)
    if (veh or skin) and (contest or has_any(low, W.IMG_WORDS)) then
        if not seen_recently('img', 5) then image_quiz(veh and 'veh' or 'skin') end
        return true
    end
    if has_any(low, W.MATH_STRONG) or (contest and has_any(low, W.MATH_WEAK)) then
        local v, kind, run = solve_math(low, cands)
        if v then
            if not seen_recently('m' .. v, 60) then deliver_answer(v, now() - t0, { extra = kind }) end
            return true
        end
        if run then
            if not seen_recently('seq' .. table.concat(run, ','), 60) then seq_ai(run) end
            return true
        end
    end
    if has_any(low, W.HANG_WORDS) and not (has_any(low, W.COPY_VERBS) and low:find('kod', 1, true)) then
        local pat = Q.extract_pattern(cands and table.concat(cands, ' ') or clean)
        if pat then
            if not seen_recently('h' .. fold(pat), 30) then hangman_ai(pat, clean) end
            return true
        end
    end
    if has_any(low, W.SCRAMBLE_WORDS) then
        local tok = Q.extract_scramble(clean, cands)
        if not tok then return false end
        if not seen_recently('s' .. fold(tok), 60) then scramble_ai(tok) end
        return true
    end
    if has_any(low, W.REVERSE_WORDS) and contest then
        local tok = Q.extract_token(clean, cands)
        if tok then
            local a = tok:reverse()
            if not seen_recently('r' .. a, 120) then deliver_answer(a, now() - t0) end
            return true
        end
    end
    if has_any(low, W.COPY_VERBS) and has_any(low, W.COPY_MARKS) and (contest or low:find('kod', 1, true)) then
        local tok = Q.extract_token(clean, cands)
        if not tok and contest and not cands then tok = Q.extract_phrase(clean) end
        if tok then
            if not seen_recently('c' .. tok, 120) then deliver_answer(tok, now() - t0) end
            return true
        end
    end
    if has_any(low, W.QUESTION_HEADS) or (contest and low:find('pytani', 1, true) and low:find('?', 1, true)) then
        if cands then
            local best = nil
            for _, c in ipairs(cands) do
                if c:find('?', 1, true) or (not best and #c > 10) then best = c end
            end
            if not best then return false end
            clean = best
        end
        if not seen_recently('q' .. fold(clean), 120) then question_ai(clean) end
        return true
    end
    return false
end

function handle_quiz(line)
    if not quiz_enabled or now() < skip_until then return false end
    local clean = trim(strip_colors(line.text))
    if clean == '' or line.prefix ~= '' then return false end
    if clean:find('SAMPGPT', 1, true) or clean:find('[QUIZ-AI]', 1, true) or clean:find('[OX-AI]', 1, true)
        or clean:find('Screenshot Taken', 1, true) then
        return false
    end
    local low = fold(clean)
    if has_any(low, W.NOISE) then return false end
    if has_any(low, W.SKIP) then
        skip_until = now() + 45
        return false
    end
    if pending_q and (not is_player_line(clean) or low:match('^[%a ]*odpowied')) then learn(clean, low) end
    local nick = my_nick_lower()
    if nick and not HUD.won and now() - HUD.t < 90 and low:find(nick, 1, true)
        and has_any(low, W.WIN_WORDS) then
        HUD.won = true
        STATS.add('wygrane')
    end
    if is_player_line(clean) then return false end
    return solve(clean, nil, false)
end

local td_prev_lines = nil

local function is_td_trigger(low)
    return has_any(low, W.TD_TRIGGERS) or low == 'ox' or low:find('^ox[%s:%-]') ~= nil or low:find('zabawa ox', 1, true) ~= nil
end

function handle_quiz_td(items)
    if now() < skip_until then return false end
    local lines = {}
    for _, it in ipairs(items) do
        local s = it.s
        if not s:match('^[%w_]+:[%w_]+$') then
            s = s:gsub('~n~', '\n'):gsub('~%a~', '')
            local k = 0
            for part in s:gmatch('[^\n]+') do
                part = trim(strip_colors(part):gsub('_', ' '):gsub('%s+', ' '))
                if part ~= '' and not has_any(fold(part), W.NOISE) then
                    lines[#lines + 1] = { t = part, low = fold(part), x = it.x, y = it.y and (it.y + k * 10) }
                    k = k + 1
                end
            end
        end
    end
    for _, l in ipairs(lines) do
        if has_any(l.low, W.SKIP) then
            skip_until = now() + 45
            return false
        end
    end
    if ox_active() then
        local cur = {}
        for _, l in ipairs(lines) do cur[l.t] = true end
        if td_prev_lines then
            for _, l in ipairs(lines) do
                if not td_prev_lines[l.t] then
                    local _, n = l.t:gsub('%S+', '')
                    if (n >= 3 or (n >= 2 and l.t:find('?', 1, true))) and not l.t:find('/%a')
                        and not Q.is_counter(l.t) and not has_any(l.low, W.OX_TD_SKIP) then
                        if not seen_recently('ox' .. l.low, 60) then ox_ai(l.t) end
                        break
                    end
                end
            end
        end
        td_prev_lines = cur
    else
        td_prev_lines = nil
    end
    for i, tl in ipairs(lines) do
        if is_td_trigger(tl.low) then
            local near = {}
            for j, l in ipairs(lines) do
                local close
                if tl.x and l.x and tl.y and l.y then
                    close = math.abs(l.x - tl.x) <= 170 and math.abs(l.y - tl.y) <= 80
                else
                    close = math.abs(j - i) <= 4
                end
                if close then
                    local d = (tl.y and l.y) and (l.y - tl.y) or (j - i)
                    near[#near + 1] = { l = l, d = d }
                end
            end
            table.sort(near, function(a, b)
                local pa, pb = a.d < 0 and 1 or 0, b.d < 0 and 1 or 0
                if pa ~= pb then return pa < pb end
                return math.abs(a.d) < math.abs(b.d)
            end)
            local texts, cands = {}, {}
            for _, n in ipairs(near) do
                texts[#texts + 1] = n.l.t
                if not is_td_trigger(n.l.low) and not Q.is_counter(n.l.t) then cands[#cands + 1] = n.l.t end
            end
            for _, n in ipairs(near) do
                if Q.is_counter(n.l.t) and n.l.t:match('^%d+$') then
                    HUD.timer, HUD.timer_t = tonumber(n.l.t), now()
                    break
                end
            end
            if solve(table.concat(texts, ' | '), cands, true) then return end
            local has_timer, parts = false, {}
            for _, n in ipairs(near) do
                if Q.is_counter(n.l.t) then has_timer = true else parts[#parts + 1] = n.l.t end
            end
            local body = table.concat(parts, ' | ')
            if has_timer and #parts >= 2 and not has_any(fold(body), W.IGNORE) then
                if not seen_recently('box' .. fold(body), 120) then box_ai(body) end
                return
            end
        end
    end
end

end -- quiz

--------------------------------------------------------------------------------
-- MAPA I RADAR Z PAMIECI GRY (natychmiast, bez screenow):
--  - strefy gangow z SA-MP (granice, kolor, czy migaja = atak),
--  - ikonki mapy/radaru z GTA (sklepy, szpitale, ikony serwera...),
--  - dzielnica, kierunek, Twoj znacznik, gracze z pamieci gry.
--------------------------------------------------------------------------------

local LOC = { note = nil, note_t = -1e9, zones_ok = nil, icons_ok = nil }
do

LOC.CITIES = {
    { 'Los Santos', 44, -2892, 2997, -768 },
    { 'San Fierro', -2997, -1115, -1213, 1659 },
    { 'Las Venturas', 869, 596, 2997, 2997 },
}
LOC.DIRS = { 'polnoc', 'polnocny zachod', 'zachod', 'poludniowy zachod',
    'poludnie', 'poludniowy wschod', 'wschod', 'polnocny wschod' }
LOC.ICONS = {
    [5] = 'lotnisko', [6] = 'Ammu-Nation', [7] = 'fryzjer', [9] = 'przystan', [10] = 'Burger Shot',
    [11] = 'kamieniolom', [14] = "Cluckin' Bell", [17] = 'bar', [19] = 'cel ataku', [20] = 'straz pozarna',
    [22] = 'szpital', [25] = 'kasyno', [27] = 'warsztat/tuning', [29] = 'pizzeria', [30] = 'policja',
    [31] = 'dom na sprzedaz', [32] = 'dom (kupiony)', [33] = 'wyscig', [35] = 'dom', [36] = 'szkola jazdy',
    [37] = 'znak zapytania', [39] = 'salon tatuazu', [42] = 'ranczo', [44] = 'kasyno', [45] = 'sklep z ubraniami',
    [48] = 'klub', [49] = 'bar', [50] = 'restauracja', [51] = 'ciezarowka', [52] = 'napad', [53] = 'flaga',
    [54] = 'silownia', [55] = 'parking policyjny', [57] = 'pas startowy', [58] = 'gang', [59] = 'gang',
    [60] = 'gang', [61] = 'gang', [62] = 'gang', [63] = "Pay 'n' Spray",
}

function LOC.city(x, y)
    for _, c in ipairs(LOC.CITIES) do
        if x >= c[2] and x <= c[4] and y >= c[3] and y <= c[5] then return c[1] end
    end
    return 'poza miastem'
end

function LOC.zone(x, y, z)
    if type(getNameOfZone) ~= 'function' then return nil end
    local key = safe_call(getNameOfZone, x, y, z or 0)
    if type(key) ~= 'string' or key == '' then return nil end
    if type(getGxtText) == 'function' then
        local name = safe_call(getGxtText, key)
        if type(name) == 'string' and name ~= '' then return game_to_utf8(name) end
    end
    return key
end

function LOC.heading()
    if safe_call(isCharInAnyCar, PLAYER_PED) == true then
        local car = safe_call(getCarCharIsUsing, PLAYER_PED)
        local h = car and safe_call(getCarHeading, car)
        if h then return h end
    end
    return safe_call(getCharHeading, PLAYER_PED)
end

function LOC.compass(h)
    return LOC.DIRS[math.floor(((h % 360) + 22.5) / 45) % 8 + 1]
end

local atan2 = math.atan2 or math.atan
function LOC.relative(px, py, h, tx, ty)
    local rel = (math.deg(atan2(-(tx - px), ty - py)) - h + 540) % 360 - 180
    if math.abs(rel) <= 30 then return 'przed Toba' end
    if rel > 30 and rel <= 80 then return 'z przodu po lewej' end
    if rel > 80 and rel < 135 then return 'po lewej' end
    if rel < -30 and rel >= -80 then return 'z przodu po prawej' end
    if rel < -80 and rel > -135 then return 'po prawej' end
    return 'za Toba'
end

local function where(px, py, h, tx, ty)
    if h then return LOC.relative(px, py, h, tx, ty) end
    return 'na ' .. LOC.compass(math.deg(atan2(-(tx - px), ty - py)))
end

local function color_name(r, g, b)
    local mx, mn = math.max(r, g, b), math.min(r, g, b)
    local d = mx - mn
    if mx < 50 then return 'czarna' end
    if d < 30 then return mx > 200 and 'biala' or 'szara' end
    local hue
    if mx == r then hue = ((g - b) / d) % 6 elseif mx == g then hue = (b - r) / d + 2 else hue = (r - g) / d + 4 end
    hue = hue * 60
    if hue < 15 or hue >= 345 then return 'czerwona' end
    if hue < 40 then return 'pomaranczowa' end
    if hue < 70 then return 'zolta' end
    if hue < 160 then return 'zielona' end
    if hue < 200 then return 'turkusowa' end
    if hue < 250 then return 'niebieska' end
    if hue < 290 then return 'fioletowa' end
    return 'rozowa'
end

local function zone_color(c)
    local r, g, b = bit.band(c, 0xFF), bit.band(bit.rshift(c, 8), 0xFF), bit.band(bit.rshift(c, 16), 0xFF)
    if CONFIG.zone_color_swap then r, b = b, r end
    return color_name(r, g, b)
end

local gz_pool_fn = nil
local function gangzone_pool()
    if gz_pool_fn == nil then
        gz_pool_fn = false
        local ok, sampapi = pcall(require, 'sampapi')
        if ok and type(sampapi) == 'table' and type(sampapi.require) == 'function' then
            local ok2, netgame = pcall(sampapi.require, 'CNetGame', true)
            pcall(sampapi.require, 'CGangZonePool', true)
            if ok2 and netgame then
                gz_pool_fn = function() return netgame.RefNetGame().m_pPools.m_pGangZone end
            end
        end
    end
    if not gz_pool_fn then return nil end
    local ok, pool = pcall(gz_pool_fn)
    if ok and pool ~= nil then return pool end
    return nil
end

function LOC.gang_zones(px, py, h)
    local pool = gangzone_pool()
    if not pool then LOC.zones_ok = false; return nil end
    local list = {}
    local ok = pcall(function()
        for i = 0, 1023 do
            if pool.m_bNotEmpty[i] ~= 0 then
                local zp = pool.m_pObject[i]
                if zp ~= nil then
                    local f, u = ffi.cast('float*', zp), ffi.cast('uint32_t*', zp)
                    local x1, x2 = math.min(f[0], f[2]), math.max(f[0], f[2])
                    local y1, y2 = math.min(f[1], f[3]), math.max(f[1], f[3])
                    local col, alt = tonumber(u[4]), tonumber(u[5])
                    local dx = math.max(x1 - px, 0, px - x2)
                    local dy = math.max(y1 - py, 0, py - y2)
                    list[#list + 1] = {
                        d = math.sqrt(dx * dx + dy * dy), inside = dx == 0 and dy == 0,
                        cx = (x1 + x2) / 2, cy = (y1 + y2) / 2,
                        color = zone_color(col), flash = alt ~= col and bit.band(alt, 0xFF000000) ~= 0,
                    }
                end
            end
        end
    end)
    LOC.zones_ok = ok
    if not ok then return nil end
    table.sort(list, function(a, b) return a.d < b.d end)
    LOC.zone_total = #list
    return list
end

function LOC.map_icons(px, py)
    local out, seen = {}, {}
    local ok = pcall(function()
        if not ffi_ready or ffi.C.IsBadReadPtr(ffi.cast('void*', 0xBA86F0), 175 * 0x28) ~= 0 then
            error('pamiec radaru niedostepna')
        end
        local base = ffi.cast('uint8_t*', 0xBA86F0)
        for i = 0, 174 do
            local e = base + i * 0x28
            local in_use = bit.band(e[0x25], 0x02) ~= 0
            local btype = bit.band(bit.rshift(e[0x26], 2), 0x0F)
            local sprite = e[0x24]
            if in_use and btype >= 4 and btype <= 8 and sprite >= 2 and sprite ~= 41 then
                local pos = ffi.cast('float*', e + 0x08)
                local x, y = pos[0], pos[1]
                if x == x and math.abs(x) < 4000 and math.abs(y) < 4000 then
                    local name = LOC.ICONS[sprite] or ('ikona ' .. sprite)
                    local d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
                    if not seen[name] or d < seen[name].d then
                        seen[name] = { name = name, d = d, x = x, y = y }
                    end
                end
            end
        end
    end)
    LOC.icons_ok = ok
    if not ok then return nil end
    for _, v in pairs(seen) do out[#out + 1] = v end
    table.sort(out, function(a, b) return a.d < b.d end)
    return out
end

local function meters(d)
    if d >= 1000 then return string.format('%.1f km', d / 1000) end
    return math.floor(d + 0.5) .. ' m'
end

function LOC.scan()
    local x, y, z = safe_call(getCharCoordinates, PLAYER_PED)
    if not x then return nil end
    local s = { x = x, y = y, z = z, h = LOC.heading(), zone = LOC.zone(x, y, z), city = LOC.city(x, y) }
    local int = safe_call(getActiveInterior)
    s.interior = int and int ~= 0
    local has, wx, wy, wz = safe_call(getTargetBlipCoordinates)
    if has == true and wx then
        s.wp = { d = math.sqrt((wx - x) ^ 2 + (wy - y) ^ 2), zone = LOC.zone(wx, wy, wz), city = LOC.city(wx, wy),
            dir = where(x, y, s.h, wx, wy) }
    end
    s.zones = LOC.gang_zones(x, y, s.h)
    s.icons = LOC.map_icons(x, y)
    return s
end

local function zones_text(s, max)
    if not s.zones or #s.zones == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#s.zones, max) do
        local zn = s.zones[i]
        if zn.d > 1500 then break end
        local t = zn.inside and ('jestes w ' .. zn.color:gsub('a$', 'ej'))
            or (zn.color .. ' ' .. meters(zn.d) .. ' ' .. where(s.x, s.y, s.h, zn.cx, zn.cy))
        if zn.flash then t = t .. ' (MIGA - atak!)' end
        parts[#parts + 1] = t
    end
    return #parts > 0 and table.concat(parts, ' | ') or nil
end

local function icons_text(s, max)
    if not s.icons or #s.icons == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#s.icons, max) do
        local ic = s.icons[i]
        parts[#parts + 1] = ic.name .. ' ' .. meters(ic.d) .. ' ' .. where(s.x, s.y, s.h, ic.x, ic.y)
    end
    return table.concat(parts, ' | ')
end

-- LOKALIZATOR GRACZY - dziala na kazdym serwerze.
function LOC.finder_allowed()
    return true
end

local function marker_blips()
    local out = {}
    pcall(function()
        if not ffi_ready or ffi.C.IsBadReadPtr(ffi.cast('void*', 0xBA86F0), 175 * 0x28) ~= 0 then return end
        local base = ffi.cast('uint8_t*', 0xBA86F0)
        for i = 0, 174 do
            local e = base + i * 0x28
            if bit.band(e[0x25], 0x02) ~= 0 and bit.band(bit.rshift(e[0x26], 2), 0x0F) == 4 and e[0x24] == 0 then
                local pos = ffi.cast('float*', e + 0x08)
                local col = tonumber(ffi.cast('uint32_t*', e)[0])
                out[#out + 1] = { x = pos[0], y = pos[1], z = pos[2],
                    rgb = bit.band(bit.rshift(col, 8), 0xFFFFFF) }
            end
        end
    end)
    return out
end

function LOC.players()
    local list = {}
    if type(sampIsPlayerConnected) ~= 'function' then return list end
    local my = safe_call(sampGetLocalPlayerId)
    local maxid = tonumber(safe_call(sampGetMaxPlayerId, false)) or 1003
    local by_rgb, no_pos = {}, {}
    for id = 0, math.min(maxid, 1003) do
        if id ~= my and safe_call(sampIsPlayerConnected, id) == true then
            local p = { id = id, name = tostring(safe_call(sampGetPlayerNickname, id) or ('ID ' .. id)) }
            local ok, ped = safe_call(sampGetCharHandleBySampPlayerId, id)
            if ok == true and ped and safe_call(doesCharExist, ped) == true then
                p.x, p.y, p.z = safe_call(getCharCoordinates, ped)
                p.exact = p.x ~= nil
            end
            if not p.x then
                local c = tonumber(safe_call(sampGetPlayerColor, id))
                if c then
                    local rgb = bit.band(c, 0xFFFFFF)
                    by_rgb[rgb] = by_rgb[rgb] and 'many' or p
                end
                no_pos[#no_pos + 1] = p
            end
            list[#list + 1] = p
        end
    end
    if #no_pos > 0 then
        for _, b in ipairs(marker_blips()) do
            local p = by_rgb[b.rgb]
            if type(p) == 'table' and not p.x then p.x, p.y, p.z = b.x, b.y, b.z end
        end
    end
    return list
end

local FIND_STOP = { gdzie = true, jest = true, jak = true, mam = true, znalezc = true, znajdz = true, gracz = true,
    gracza = true, kolega = true, kolege = true, kolegi = true, moj = true, moja = true, sie = true, the = true }
function LOC.find_player(question, list)
    local q = cp1250_to_ascii(question):lower()
    local best, best_len = nil, 0
    for _, p in ipairs(list) do
        local nick = cp1250_to_ascii(p.name):lower()
        if #nick >= 3 and q:find(nick, 1, true) and #nick > best_len then best, best_len = p, #nick end
        for w in q:gmatch('[%w_]+') do
            if #w >= 3 and not FIND_STOP[w] and nick:sub(1, #w) == w and #w > best_len then best, best_len = p, #w end
        end
    end
    return best
end

function LOC.answer_player(p)
    local x, y = safe_call(getCharCoordinates, PLAYER_PED)
    if not p.x or not x then
        chat_print(PREFIX .. p.name .. ' (ID ' .. p.id .. '): poza zasiegiem, serwer nie pokazuje markera. '
            .. 'Spytaj go na czacie/PM, gdzie jest.')
        return
    end
    local h = LOC.heading()
    local d = math.sqrt((p.x - x) ^ 2 + (p.y - y) ^ 2)
    local zone = LOC.zone(p.x, p.y, p.z)
    local wp = ''
    if type(placeWaypoint) == 'function' and pcall(placeWaypoint, p.x, p.y, p.z or 0) then wp = ' {33FF33}- znacznik na mapie' end
    chat_print(PREFIX .. p.name .. ': ' .. meters(d) .. ' ' .. where(x, y, h, p.x, p.y) .. ' {AAAAAA}('
        .. (zone and (zone .. ', ') or '') .. LOC.city(p.x, p.y) .. (p.exact and '' or ', wg markera') .. ')' .. wp)
end

local function players_text(s, max)
    local parts = {}
    local list = LOC.players()
    table.sort(list, function(a, b)
        local da = a.x and math.sqrt((a.x - s.x) ^ 2 + (a.y - s.y) ^ 2) or 1e9
        local db = b.x and math.sqrt((b.x - s.x) ^ 2 + (b.y - s.y) ^ 2) or 1e9
        return da < db
    end)
    for i = 1, math.min(#list, max) do
        local p = list[i]
        if p.x then
            local zone = LOC.zone(p.x, p.y, p.z)
            parts[#parts + 1] = p.name .. ' ' .. meters(math.sqrt((p.x - s.x) ^ 2 + (p.y - s.y) ^ 2)) .. ' '
                .. where(s.x, s.y, s.h, p.x, p.y) .. (zone and (' (' .. zone .. ')') or '')
        else
            parts[#parts + 1] = p.name .. ' (pozycja nieznana)'
        end
    end
    return #parts > 0 and table.concat(parts, ' | ') or nil
end

function LOC.describe()
    local s = LOC.scan()
    if not s then return '' end
    local out = { string.format('Player location: %s%s (x=%.0f, y=%.0f, z=%.0f)%s', s.zone and (s.zone .. ', ') or '',
        s.city, s.x, s.y, s.z, s.interior and ', inside an interior' or '') }
    if s.h then out[#out + 1] = 'Player is facing: ' .. LOC.compass(s.h) end
    if s.wp then
        out[#out + 1] = 'Red map waypoint: ' .. (s.wp.zone and (s.wp.zone .. ', ') or '') .. s.wp.city .. ', '
            .. meters(s.wp.d) .. ', ' .. s.wp.dir
    end
    local zt = zones_text(s, 8)
    if zt then out[#out + 1] = 'Gang zones (territories) nearby, nearest first: ' .. zt end
    local it = icons_text(s, 10)
    if it then out[#out + 1] = 'Map/radar icons, nearest first: ' .. it end
    if LOC.note and now() - LOC.note_t < 300 then out[#out + 1] = 'Last look at the map: ' .. LOC.note end
    local pt = players_text(s, 10)
    if pt then
        out[#out + 1] = 'Other players (exact positions from game memory): ' .. pt
    else
        out[#out + 1] = "Other players' positions: none streamed right now."
    end
    return 'LOCATION AND MAP (exact, read from game memory):\n' .. table.concat(out, '\n')
end

function LOC.look_vision()
    local map_open = type(isPauseMenuActive) == 'function' and safe_call(isPauseMenuActive) == true
    ai_request({
        prompt = 'Describe briefly (max 3 sentences, in Polish) what this GTA San Andreas '
            .. (map_open and 'pause-menu map' or 'radar (minimap, cut out and enlarged, rotates with the camera)')
            .. ' shows: player position, waypoint, coloured gang zones and important icons.',
        context = LOC.describe(),
        models = CONFIG.models_rebus,
        screenshot = true,
        crop = (not map_open) and CONFIG.radar_crop or nil,
        image_width = map_open and 1600 or 900,
        on_answer = function(txt, dt)
            LOC.note, LOC.note_t = clean_answer(txt):sub(1, 400), now()
            send_lines(txt, PREFIX, nil, time_suffix(dt))
        end,
    })
end

function LOC.look()
    local s = LOC.scan()
    if not s then chat_print(WARN_PREFIX .. 'Nie da sie odczytac pozycji.'); return end
    if LOC.zones_ok == false and LOC.icons_ok == false then
        chat_print(INFO_PREFIX .. 'Odczyt mapy z pamieci niedostepny - patrze na ekran...')
        LOC.look_vision()
        return
    end
    local head = (s.zone and (s.zone .. ', ') or '') .. s.city .. (s.h and (' | patrzysz na ' .. LOC.compass(s.h)) or '')
    if s.wp then
        head = head .. ' | znacznik: ' .. (s.wp.zone or s.wp.city) .. ' ' .. meters(s.wp.d) .. ' ' .. s.wp.dir
    end
    chat_print(PREFIX .. head)
    local zt = zones_text(s, 4)
    chat_print(PREFIX .. 'Strefy: ' .. (zt or (s.zones and 'brak w poblizu' or '{AAAAAA}odczyt niedostepny')))
    local it = icons_text(s, 4)
    if it then chat_print(PREFIX .. 'W poblizu: ' .. it) end
    chat_print(PREFIX .. 'Gracze: ' .. (players_text(s, 4) or 'nikogo poza Toba'))
end

end -- mapa

--------------------------------------------------------------------------------
-- KOMENDY: /ai  /rebus  /aiquiz  /aiox  /aiset  /aistatus  /aihelp   (F11, F12)
--------------------------------------------------------------------------------

local process_command, toggle_quiz
do

local function cmd_aihelp()
    local gr = '{AAAAAA}'
    chat_print(PREFIX .. 'Wszystko jest w menu: ' .. A.keyName(A.cfg.menuKey) .. ' > SAMPGPT.' .. gr .. ' Na czacie: /ai <pytanie>')
    chat_print(PREFIX .. key_name(CONFIG.key_type) .. gr .. ' wpisz odpowiedz  {FFFFFF}' .. key_name(CONFIG.key_ox)
        .. gr .. ' OX z ekranu  {FFFFFF}' .. key_name(CONFIG.key_map) .. gr .. ' mapa: strefy i okolica')
end

local function vision_allowed()
    if now() - last_vision < 2 then return false end
    last_vision = now()
    return true
end

local function cmd_ai(arg)
    arg = trim(arg)
    if arg == '' then cmd_aihelp(); return end
    local d = try_delta(arg)
    if d then
        chat_print(PREFIX .. d)
        set_last_answer((d:match('^Delta = (%S+)')) or d)
        return
    end
    local m = try_math(arg)
    if m then
        chat_print(PREFIX .. m)
        set_last_answer(m)
        return
    end
    do
        local p = LOC.find_player(arg, LOC.players())
        if p then LOC.answer_player(p); return end
    end
    ai_request({
        prompt = game_to_utf8(arg),
        context = context_to_text(get_local_context()) .. '\n' .. LOC.describe() .. '\n' .. KB.context(arg),
        history = true,
    })
end

function toggle_quiz()
    quiz_enabled = not quiz_enabled
    CONFIG.quiz_on_start = quiz_enabled
    save_settings()
    td_scan_restart()
    chat_print(PREFIX .. 'Quizy: ' .. onoff(quiz_enabled))
end

local function cmd_aiox(arg)
    arg = trim(arg):lower()
    if arg == 'ekran' then
        if vision_allowed() then start_ox_vision(false) end
        return
    end
    local v
    if arg == 'on' then v = true elseif arg == 'off' then v = false else v = not ox_active() end
    if v then
        ox_manual, ox_block_until = true, 0
        chat_print(PREFIX .. 'Tryb OX: ON {AAAAAA}(do wylaczenia; ' .. key_name(CONFIG.key_ox) .. ' = ocen pytanie z ekranu)')
    else
        ox_manual, ox_until, ox_block_until = false, 0, now() + 600
        ox_marker = nil
        chat_print(PREFIX .. 'Tryb OX: OFF {AAAAAA}(przez 10 min nie wlaczy sie sam)')
    end
end

local SETTINGS = {
    { name = 'wpis',    key = 'autotype', info = 'odpowiedz sama wpisuje sie w czat', need = 'sampSetChatInputText' },
    { name = 'schowek', key = 'autocopy', info = 'odpowiedz w schowku (Ctrl+V)',      need = 'setClipboardText' },
    { name = 'panel',   key = 'panel',    info = 'panel z odpowiedzia na ekranie',    need = 'renderFontDrawText' },
    { name = 'dzwiek',  key = 'sound',    info = 'sygnal, gdy odpowiedz jest gotowa', need = 'addOneOffSound' },
}

local function cmd_aiset(arg)
    local name, val = trim(arg):lower():match('^(%S*)%s*(%S*)$')
    if not name or name == '' then
        local parts = {}
        for _, o in ipairs(SETTINGS) do parts[#parts + 1] = o.name .. ' ' .. onoff(CONFIG[o.key]) end
        chat_print(PREFIX .. table.concat(parts, '  |  ') .. '   {AAAAAA}/aiset <nazwa> przelacza')
        return
    end
    for _, o in ipairs(SETTINGS) do
        if o.name == name then
            local v
            if val == 'on' then v = true elseif val == 'off' then v = false else v = not CONFIG[o.key] end
            CONFIG[o.key] = v
            local saved = save_settings()
            local warn = (v and type(_G[o.need]) ~= 'function') and ' {FF6666}(Twoj SF.lua/MoonLoader tego nie ma)' or ''
            chat_print(PREFIX .. o.name .. ': ' .. onoff(v) .. ' {AAAAAA}- ' .. o.info .. warn
                .. (saved and '' or ' {FF6666}(nie udalo sie zapisac)'))
            return
        end
    end
    chat_print(WARN_PREFIX .. 'Nie ma takiej opcji. Sa: wpis, schowek, panel, dzwiek.')
end

local function cmd_aistatus()
    local key_ok = get_api_key() ~= ''
    local problems = {}
    if not sf_loaded then problems[#problems + 1] = 'brak SF.lua' end
    if not CURL_EXE then problems[#problems + 1] = 'brak curl.exe' end
    if not key_ok then problems[#problems + 1] = 'brak klucza API' end
    chat_print(PREFIX .. (#problems == 0 and '{33FF33}Wszystko dziala' or ('{FF6666}' .. table.concat(problems, ', ')))
        .. '{AAAAAA}  | model: ' .. (last_model_used or CONFIG.models_text[1].name)
        .. (last_latency and string.format(' (%.1f s)', last_latency) or ''))
    local d, avg = STATS.d, STATS.avg()
    chat_print(PREFIX .. 'quizy ' .. onoff(quiz_enabled) .. ' | OX ' .. onoff(ox_active())
        .. ' | mapa ' .. ((LOC.zones_ok == false and LOC.icons_ok == false) and 'z ekranu' or 'z pamieci')
        .. ' | szukanie graczy ON')
    chat_print(PREFIX .. 'baza ' .. DB.count .. ' | wiedza ' .. #KB.list .. ' | zadania ' .. d.zadania
        .. ' | wygrane ' .. d.wygrane .. (avg and string.format(' | reakcja %.2f s (rekord %.2f)', avg, d.rekord) or ''))
    if not sf_loaded and sf_error then chat_print(WARN_PREFIX .. 'SF: ' .. sf_error:sub(1, 100)) end
    if worker_restarts > 0 then
        chat_print(INFO_PREFIX .. 'Bledy SF.lua przechwycone: ' .. worker_restarts .. 'x (skrypt dziala dalej)')
    end
end

local HANDLERS = {
    ai = cmd_ai,
    rebus = function() if vision_allowed() then start_rebus(false) end end,
    aiquiz = function() toggle_quiz() end,
    aiox = cmd_aiox,
    aiset = cmd_aiset,
    aistatus = cmd_aistatus,
    aihelp = cmd_aihelp,
    aimapa = function() LOC.look() end,
    aitype = function()
        if last_answer then
            type_into_chat(last_answer, true)
        else
            chat_print(INFO_PREFIX .. 'Nie ma jeszcze odpowiedzi do wpisania.')
        end
    end,
}

function process_command(cmd, arg)
    local h = HANDLERS[cmd]
    if h then h(arg or '') end
end

end -- komendy

local function queue_command(cmd, arg)
    cmd = tostring(cmd):lower()
    arg = tostring(arg or '')
    local key = cmd .. '\0' .. arg
    if last_queued.key == key and now() - last_queued.t < 0.5 then return end
    last_queued.key, last_queued.t = key, now()
    command_queue[#command_queue + 1] = { cmd = cmd, arg = arg }
end

local function parse_command(text)
    text = trim(text)
    local cmd, arg = text:match('^/(%S+)%s*(.*)$')
    if not cmd then return nil end
    cmd = cmd:lower()
    if not COMMAND_SET[cmd] then return nil end
    return cmd, arg
end

local function register_commands()
    if type(sampRegisterChatCommand) ~= 'function' then return false end
    local all_ok = true
    for _, c in ipairs(COMMANDS) do
        local name = c
        local ok = pcall(sampRegisterChatCommand, name, function(arg)
            queue_command(name, arg)
        end)
        if not ok then all_ok = false end
    end
    return all_ok
end

local function chat_or_dialog_open()
    if safe_call(sampIsChatInputActive) == true then return true end
    if safe_call(sampIsDialogActive) == true then return true end
    return false
end

addEventHandler('onWindowMessage', function(msg, wparam, lparam)
    if not samp_ready then return end
    if msg == 0x0102 and wparam == 0x0D and swallow_enter_char then
        swallow_enter_char = false
        if type(consumeWindowMessage) == 'function' then consumeWindowMessage(true, false) end
        return
    end
    if msg ~= 0x0100 or wparam ~= 0x0D then return end
    if type(sampGetChatInputText) ~= 'function' then return end
    if type(sampIsChatInputActive) == 'function' and safe_call(sampIsChatInputActive) ~= true then return end
    local text = safe_call(sampGetChatInputText)
    if type(text) ~= 'string' or text == '' then return end
    if text:sub(1, 1) == '/' then KB.last_cmd, KB.last_cmd_t = text:match('^(/%S+)'), now() end
    if last_answer and not HUD.reaction and now() - HUD.t < 120
        and trim(text):lower() == trim(last_answer):lower() then
        HUD.reaction = now() - HUD.t
        STATS.reaction(HUD.reaction)
    end
    local cmd, arg = parse_command(text)
    if not cmd then return end
    if type(consumeWindowMessage) == 'function' then consumeWindowMessage(true, false) end
    swallow_enter_char = true
    queue_command(cmd, arg)
    safe_call(sampSetChatInputText, '')
    safe_call(sampSetChatInputEnabled, false)
end)

--------------------------------------------------------------------------------
-- CZAT: linie przychodza ze wspolnego skanera antek.cc (A.onChat)
--------------------------------------------------------------------------------

local function on_chat(lines)
    for i = math.max(1, #lines - 11), #lines do
        local l = lines[i]
        pcall(KB.learn_chat, l)
        if quiz_enabled then pcall(handle_quiz, l) end
    end
end

--------------------------------------------------------------------------------
-- MAIN
--------------------------------------------------------------------------------

addEventHandler('onScriptTerminate', function(scr)
    if type(thisScript) == 'function' and scr == thisScript() then
        pcall(cancel_all_requests)
    end
end)

local ox_font = nil
local function draw_ox_marker()
    local m = ox_marker
    if now() > m.until_t then
        ox_marker = nil
        return
    end
    if type(renderFontDrawText) ~= 'function' or type(convert3DCoordsToScreen) ~= 'function' then return end
    if not ox_font then
        if type(renderCreateFont) ~= 'function' then return end
        ox_font = renderCreateFont('Arial', 16, 5)
    end
    if type(isPointOnScreen) == 'function' and not isPointOnScreen(m.x, m.y, m.z + 1.0, 1.0) then return end
    local sx, sy = convert3DCoordsToScreen(m.x, m.y, m.z + 1.0)
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    local d = math.floor(math.sqrt((m.x - px) ^ 2 + (m.y - py) ^ 2 + (m.z - pz) ^ 2) + 0.5)
    local text = '>> ' .. m.label .. ' <<  ' .. d .. ' m'
    local w = type(renderGetFontDrawTextLength) == 'function' and renderGetFontDrawTextLength(ox_font, text) or 0
    renderFontDrawText(ox_font, text, sx - w / 2, sy, m.yes and 0xFF33FF33 or 0xFFFF4444)
end

local PANEL_SHOW = 20
local panel_font, panel_big = nil, nil
local function draw_panel()
    if type(renderFontDrawText) ~= 'function' or type(renderDrawBox) ~= 'function' then return end
    if not A.drawOk then return end
    local t = now()
    local timer = HUD.timer and t - HUD.timer_t < 1.5
    local fresh = HUD.display and (t - HUD.t < PANEL_SHOW or (timer and t - HUD.t < 120))
    local ox = ox_active()
    if not fresh and not ox and not A.menuOpen then return end
    if not panel_font then
        if type(renderCreateFont) ~= 'function' then return end
        panel_font = renderCreateFont('Arial', 10, 5)
        panel_big = renderCreateFont('Arial', 18, 5)
    end
    local lines = {}
    if fresh then
        local col = (HUD.src == 'OX') and (HUD.ox and '{33FF33}' or '{FF5555}') or '{FFDD33}'
        lines[#lines + 1] = { col .. HUD.display:sub(1, 40), panel_big }
        local l2
        if HUD.reaction then
            l2 = '{33FF33}wyslane w ' .. string.format('%.2f s', HUD.reaction) .. (HUD.won and '   {FFDD33}WYGRANA!' or '')
        elseif HUD.won then
            l2 = '{FFDD33}WYGRANA!'
        else
            local info = {}
            if HUD.src and HUD.src ~= '' and HUD.src ~= 'OX' then info[#info + 1] = HUD.src:sub(1, 28) end
            if HUD.dt then info[#info + 1] = string.format('%.1f s', HUD.dt) end
            if HUD.src ~= 'OX' then info[#info + 1] = '{FFFFFF}Enter = wyslij' end
            l2 = '{AAAAAA}' .. table.concat(info, '  ')
        end
        lines[#lines + 1] = { l2, panel_font }
    elseif ox then
        lines[#lines + 1] = { '{66CCFF}OX {AAAAAA}czekam na pytanie   {FFFFFF}' .. key_name(CONFIG.key_ox) .. ' = ekran', panel_font }
    else
        lines[#lines + 1] = { '{66CCFF}SAMPGPT {AAAAAA}panel odpowiedzi', panel_font }
    end
    if timer and fresh then
        lines[#lines + 1] = { '{FFCC00}zostalo ' .. HUD.timer .. ' s', panel_font }
    end
    local sw, sh = 1280, 720
    if type(getScreenResolution) == 'function' then sw, sh = getScreenResolution() end
    local pad, w, h, hs = 8, 0, 0, {}
    for i, l in ipairs(lines) do
        local plain = strip_colors(l[1])
        local lw = type(renderGetFontDrawTextLength) == 'function' and renderGetFontDrawTextLength(l[2], plain) or #plain * 8
        local lh = type(renderGetFontDrawHeight) == 'function' and renderGetFontDrawHeight(l[2]) or 16
        if lw > w then w = lw end
        hs[i] = lh
        h = h + lh + 2
    end
    w, h = w + pad * 2 + 4, h + pad * 2
    local x, y = A.hudPlace('gpt', w, h, (sw - w - 15) / sw, CONFIG.panel_y)
    renderDrawBox(x, y, w, h, 0xAA000000)
    renderDrawBox(x, y, 3, h, fresh and 0xFFFFDD33 or 0xFF66CCFF)
    local cy = y + pad
    for i, l in ipairs(lines) do
        renderFontDrawText(l[2], l[1], x + pad + 4, cy, 0xFFFFFFFF)
        cy = cy + hs[i] + 2
    end
end

local function key_pressed(vk)
    if not vk or vk == 0 or type(isKeyJustPressed) ~= 'function' then return false end
    local ok, r = pcall(isKeyJustPressed, vk)
    return ok and r == true
end

local workers = {}

local function start_worker(name, body)
    local w = { name = name, fails = 0, next_restart = 0 }
    w.th = lua_thread.create(function()
        while true do
            local ok, err = pcall(body)
            if not ok then
                print('[SAMPGPT] blad w watku ' .. name .. ': ' .. tostring(err))
                wait(1000)
            end
        end
    end)
    workers[#workers + 1] = w
end

local function thread_alive(th)
    local ok, st = pcall(function() return th:status() end)
    if not ok then return true end
    return st ~= 'dead' and st ~= 'error'
end

local function supervise()
    local t = now()
    for _, w in ipairs(workers) do
        if not thread_alive(w.th) and t >= w.next_restart then
            w.fails = w.fails + 1
            worker_restarts = worker_restarts + 1
            w.next_restart = t + math.min(10, w.fails)
            print('[SAMPGPT] watek "' .. w.name .. '" padl (blad SF.lua) - wznawiam (' .. w.fails .. ')')
            pcall(function() w.th:run() end)
        end
    end
    for job in pairs(jobs) do
        if not job.done and not thread_alive(job.th) then
            jobs[job] = nil
            if job.quiz then quiz_pending = false else pending = false end
        end
    end
end

local function worker_input()
    wait(0)
    while #command_queue > 0 do
        local c = table.remove(command_queue, 1)
        local ok, err = pcall(process_command, c.cmd, c.arg)
        if not ok then chat_print(ERR_PREFIX .. 'Blad komendy: ' .. tostring(err)) end
    end
    if A.menuOpen then return end
    if key_pressed(CONFIG.key_type) then queue_command('aitype', '') end
    if key_pressed(CONFIG.key_map) then queue_command('aimapa', '') end
    if key_pressed(CONFIG.key_ox) and not chat_or_dialog_open() then queue_command('aiox', 'ekran') end
end

local function worker_chat()
    wait(50)
    KB.tick = KB.tick + 1
    if KB.tick % 10 == 0 then KB.poll_dialog() end
end

local function worker_td()
    wait(40)
    if quiz_enabled then td_auto_step() end
end

--------------------------------------------------------------------------------
-- MODUL antek.cc
--------------------------------------------------------------------------------

local M = { id = 'gpt', title = 'SAMPGPT' }
local keySetup, keyBuf = nil, nil

function M.init()
    ensure_config_dir()
    load_cache()
    if not load_settings() then save_settings() end
    CONFIG.sound, CONFIG.ox_auto_vision, CONFIG.vehicle_vision_fallback = false, false, false   -- bez dzwieku i bez automatycznych screenow
    DB.load()
    STATS.load()
    KB.load()
    load_sf()
    init_ffi()
    samp_ready = true
    register_commands()
    CURL_EXE = find_curl()
    quiz_enabled = CONFIG.quiz_on_start
    if not sf_loaded then chat_print(ERR_PREFIX .. 'SF.lua nie zaladowany - szczegoly w menu.') end
    if not CURL_EXE then chat_print(ERR_PREFIX .. 'Nie znaleziono curl.exe.') end
    local function gated(fn)
        return function()
            if A.isOn('gpt') then fn() else wait(250) end
        end
    end
    start_worker('komendy', gated(worker_input))
    start_worker('ramki', gated(worker_td))
    start_worker('wiedza', gated(worker_chat))
    A.onChat('gpt', on_chat)
end

function M.frame()
    if not A.menuOpen then keySetup = nil end
    supervise()
    if not A.drawOk then return end
    if ox_marker then pcall(draw_ox_marker) end
    if CONFIG.panel then pcall(draw_panel) end
end

function M.disable()
    pcall(cancel_all_requests)
    ox_marker = nil
end

function M.terminate()
    pcall(cancel_all_requests)
end

function M.status()
    return 'quizy ' .. onoff(quiz_enabled) .. ', OX ' .. onoff(ox_active())
        .. (get_api_key() == '' and ', BRAK KLUCZA' or '')
end

-- ------------------------------------------------------------ menu
local UI_OPTS = {
    { 'autotype', 'Auto wpisywanie', 'Odpowiedz AI sama wpisuje sie w czat i wysyla.' },
    { 'autocopy', 'Schowek', 'Odpowiedz AI trafia do schowka (Ctrl+V).' },
    { 'panel', 'Panel', 'Mala ramka z odpowiedzia AI na ekranie.' },
    { 'web_search', 'Internet', 'Zwykle pytania /ai moga szukac odpowiedzi w Google (aktualnosci, wyniki, fakty).' },
    { 'auto_rebus', 'Auto rebus', 'Rebusy pojawiajace sie na ekranie rozwiazuja sie same.' },
}

function M.menu()
    local ui, im = A.ui, A.imgui
    if keySetup == nil then keySetup = (get_api_key() == '') end
    ui.cols(function()
        if keySetup then
            ui.group('Klucz API', function()
                if not keyBuf then keyBuf = im.new.char[128]() end
                ui.textDim('Klucz Gemini (aistudio.google.com)')
                if ui.input('##gptkey', 'AIza...', keyBuf, 128, im.InputTextFlags.Password) then
                    ensure_config_dir()
                    write_file(KEY_FILE, trim(A.ffi.string(keyBuf)) .. '\n')
                end
            end)
        end
        ui.group('Quizy', function()
            ui.check('Quizy', function() return quiz_enabled end, function() queue_command('aiquiz', '') end,
                'AI sam rozwiazuje quizy i rebusy z czatu oraz ramek na ekranie.')
            A.imgui.Spacing()
            if ui.button('Rebus', nil, 'Rozwiazuje rebus widoczny teraz na ekranie. Menu zamknie sie, zeby nie zaslaniac obrazu.') then A.setMenu(false); queue_command('rebus', '') end
        end)
    end, function()
        ui.group('Opcje', function()
            for _, o in ipairs(UI_OPTS) do
                ui.check(o[2] .. '##gpto', function() return CONFIG[o[1]] end, function(v)
                    CONFIG[o[1]] = v
                    save_settings()
                end, o[3])
            end
        end)
    end)
end

return M
end)(A))

-- ============================================================================
-- MODUL: MAKRO (dawny AutoY.ahk) - szybkie wciskanie klawisza (domyslnie Y)
-- Sterowanie tylko klawiszami (domyslnie Lewo / Prawo). Menu: zakladka Strefy.
-- Tempo dobierane samo: wcisniecie i puszczenie trwaja kazde co najmniej jedna
-- klatke i 18 ms - gra czyta klawiature raz na klatke, wiec kazde wcisniecie
-- jest zauwazone, a przy 60-100 FPS to ok. 25-30 wcisniec na sekunde (jak w AHK).
-- Pauza: czat, dialog, menu, menu pauzy, gra bez fokusu.
-- ============================================================================
A.register((function(A)
local ffi = A.ffi

local M = { id = 'autoy', title = 'Makro', hidden = true }
local FILE = A.DIR .. '\\autoy.json'

local C = {
    keyOn  = 0x25,     -- strzalka w lewo
    keyOff = 0x27,     -- strzalka w prawo
    key    = 0x59,     -- Y
    hud    = true,
    rate   = 30,       -- wcisniec na sekunde
}

-- Stale tempo: kolejne zmiany stanu klawisza sa planowane od poprzedniego terminu (nie od "teraz"),
-- wiec nie ma dryfu; po przycieciu gry nie ma serii nadrabiajacej; kazdy stan trwa min. 1 pelna klatke
-- (gra czyta klawiature raz na klatke, krotsze stuknicie by zgubila).
local on, down, paused = false, false, false
local nextFlip, flipFrame, frameNo = 0, -1, 0
local focused, focusAt = true, 0
local scan = 0x15
local font, pid

local function save() A.saveJson(FILE, C) end

local function updScan()
    local ok, s = pcall(function() return ffi.C.MapVirtualKeyA(C.key, 0) end)   -- MAPVK_VK_TO_VSC
    s = ok and tonumber(s) or 0
    scan = s ~= 0 and s or 0x15
end

local function key(up)
    pcall(function() ffi.C.keybd_event(0, scan, up and 0x000A or 0x0008, 0) end)   -- SCANCODE (+KEYUP)
end

local function release()
    if down then
        key(true)
        down = false
    end
end

-- okno na pierwszym planie nalezy do procesu gry
local function gameFocused()
    local ok, r = pcall(function()
        if not pid then pid = ffi.C.GetCurrentProcessId() end
        local h = ffi.C.GetForegroundWindow()
        if h == nil then return false end
        local p = ffi.new('uint32_t[1]')
        ffi.C.GetWindowThreadProcessId(h, p)
        return p[0] == pid
    end)
    return not ok or r
end

local function set(v)
    on = v and true or false
    if not on then release() end
    nextFlip, focusAt = 0, 0
end

function M.init()
    local t = A.loadJson(FILE)
    if t then
        for _, k in ipairs({ 'keyOn', 'keyOff', 'key' }) do
            if type(t[k]) == 'number' and t[k] > 0 then C[k] = t[k] end
        end
        if type(t.hud) == 'boolean' then C.hud = t.hud end
        if type(t.rate) == 'number' then C.rate = A.clamp(math.floor(t.rate), 5, 60) end
    end
    save()
    updScan()
    font = renderCreateFont('Arial', 9, 5)
end

function M.onKey(vk)
    if vk ~= C.keyOn and vk ~= C.keyOff then return end
    if A.chatInputActive() or A.dialogActive() then return end
    set(vk == C.keyOn)
end

function M.frame(now)
    frameNo = frameNo + 1
    if on then
        if now >= focusAt then focusAt, focused = now + 0.25, gameFocused() end
        paused = A.menuOpen or A.miningBusy or A.minerAuto or A.zoneBotOn or A.pauseActive() or A.chatInputActive()
            or A.dialogActive() or not focused
        if paused then
            release()
            nextFlip = 0
        else
            local phase = 0.5 / C.rate
            if nextFlip == 0 then nextFlip = now end
            if now >= nextFlip and frameNo > flipFrame then
                down = not down
                key(not down)
                flipFrame = frameNo
                nextFlip = nextFlip + phase
                if now - nextFlip > phase then nextFlip = now + phase end   -- po przycieciu: bez serii nadrabiania
            end
        end
    end
    if C.hud and A.drawOk and font and (on or A.menuOpen) then
        local w = renderGetFontDrawTextLength(font, 'Makro')
        local x, y = A.hudPlace('autoy', w + 14, 18, 0.47, 0.02)
        renderDrawBox(x, y, w + 14, 18, 0x90000000)
        renderDrawBox(x, y, 3, 18, not on and 0xFF666666 or (paused and 0xFFFFD24A or 0xFF33FF66))
        renderFontDrawText(font, 'Makro', x + 8, y + 2, 0xFFFFFFFF)
    end
end

function M.disable() set(false) end
function M.terminate() release() end

-- grupa w zakladce Strefy
function M.menuGroup()
    local ui = A.ui
    ui.keyButton('Wlacz', function() return C.keyOn end, function(vk) C.keyOn = vk; save() end,
        'Ten klawisz wlacza makro: bot wciska wybrany klawisz (domyslnie Y) kilkadziesiat razy na sekunde.')
    ui.keyButton('Wylacz', function() return C.keyOff end, function(vk) C.keyOff = vk; save() end,
        'Ten klawisz zatrzymuje makro.')
    ui.keyButton('Klawisz', function() return C.key end, function(vk)
        release()
        C.key = vk
        updScan()
        save()
    end, 'Klawisz, ktory makro ma wciskac.')
    ui.sliderInt('Tempo##mk', function() return C.rate end, function(v) C.rate = v; save() end, 5, 60, '%d / s',
        'Ile wcisniec na sekunde. Rowne odstepy, bez przyspieszania po przycieciu gry. Gora to polowa Twojego FPS (kazdy stan klawisza musi trwac min. 1 klatke). 30 jest bezpieczne.')
    ui.check('HUD##mk', function() return C.hud end, function(v) C.hud = v; save() end,
        'Maly znacznik na ekranie, gdy makro dziala.')
end

return M
end)(A))

-- ============================================================================
-- MODUL: KASYNO - Auto Karty (hotkey, domyslnie F9)
-- Gra: [Graj] -> 3 karty -> klik karty (nagroda + [Graj]) -> [Graj] -> 3 karty...
-- Skrypt patrzy na ekran i robi jedna rzecz naraz:
--   3 zakryte karty                          -> klik w losowa karte
--   nagroda (mniej niz 3 karty) / sam "Graj" -> klik "Graj"
-- Zasady niezawodnosci:
--  * dziala we wlasnym watku (nadzorowanym: padniecie przez SF.lua = automatyczny restart)
--  * nigdy sie sam nie wylacza z powodu kursora/dialogu/utraty fokusu - tylko czeka
--  * czeka az ekran sie USTABILIZUJE (0.25 s bez zmian), zeby nie klikac w polowie animacji
--  * po kliknieciu czeka na zmiane ekranu; bez zmiany ponawia coraz inna metoda, bez konca
--  * wylacza sie tylko: hotkey, mniej niz 15 zetonow (klika Zamknij), 30 s bez gry
-- Diagnostyka: kazda akcja trafia do moonloader.log ([kasyno]).
-- ============================================================================
A.register((function(A)
local ffi = A.ffi

local M = { id = 'karta', title = 'Kasyno', hidden = true }
local FILE = A.DIR .. '\\karta.json'
local C = { key = 0x78, hud = true, reveal = 1500 }      -- reveal: ms od kliku karty do Graj      -- F9

local COST, TD_MAX = 15, 2304
local POLL, FULL_EVERY = 0.05, 1.5
local STABLE_MIN, STABLE_MAX = 0.25, 0.5    -- czas stabilnego ekranu przed kliknieciem (uczy sie sam)
local RETRY, CYCLE, GONE_STOP = 0.8, 5, 30

local click, on, S = nil, false, nil
local toggleReq = false
local win, nextFull, tokId = nil, 0, nil
local font

local function save() A.saveJson(FILE, { key = C.key, hud = C.hud, reveal = C.reveal }) end
local function log(msg) A.log('kasyno', msg) end

-- ------------------------------------------------------------ textdrawy
local function fold(s)
    s = tostring(s or ''):gsub('~%a~', ' '):lower()
    return (s:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''))
end

-- 'card' | 'play' | 'close' | 'tokens', wartosc (dla zetonow)
local function kind(text)
    local t = fold(text)
    if t:find('szcz', 1, true) and t:find('karta', 1, true) then return 'card' end
    if #t <= 24 and t:find('^graj') and not t:find('szcz', 1, true) then return 'play' end
    if #t <= 24 and t:find('^zamknij') then return 'close' end
    local z = t:gsub('%s', ''):match('^z(%d%d%d%d+)$')
    if z then return 'tokens', tonumber(z) end
    return nil
end




local mem = { play = nil, close = nil }          -- ostatnio widziane id przyciskow
local idleUntil, nextQuick = 0, 0

local function finish(r)
    r.sig = #r.cards .. (r.play and 'P' or '-') .. (r.close and 'Z' or '-') .. tostring(r.tokens)
    return r
end

-- Z logu: tekst karty lezy NA SRODKU karty (np. 215,207), a pole karty zaczyna sie ok. 45 w lewo i 57 w gore.
-- Dlatego klikamy dokladnie w pozycje tekstu. "Graj" i "Zamknij" to napisy w dolnej czesci ekranu (y > 250);
-- inne textdrawy z napisem "graj..." wyzej (w rzedzie kart) sa ignorowane.
local function readTd(id, r)
    local ok, text = pcall(sampTextdrawGetString, id)
    if not ok or type(text) ~= 'string' then return end
    local k, v = kind(text)
    if not k then return end
    if k == 'tokens' then
        r.tokens, tokId = v, id
        return
    end
    local okp, x, y = pcall(sampTextdrawGetPos, id)
    if not okp or type(x) ~= 'number' or (x <= 0 and y <= 0) then return end
    if k == 'card' then
        if y >= 90 and y <= 330 then r.cand[#r.cand + 1] = { id = id, x = x, y = y, cx = x, cy = y + 4 } end
    elseif y > 250 then
        local cur = (k == 'play') and r.play or r.close
        if not cur or y > cur.y then                              -- najnizszy napis = prawdziwy przycisk
            local e = { id = id, x = x, y = y, cx = x, cy = y + 5 }
            if k == 'play' then r.play = e else r.close = e end
        end
    end
end

-- jedna karta = jedna kolumna: z kilku textdrawow w kolumnie bierzemy ten nizej (tekst na srodku)
local function pickCards(cand)
    table.sort(cand, function(a, b) return a.x < b.x end)
    local out = {}
    for _, c in ipairs(cand) do
        local last = out[#out]
        if last and c.x - last.x < 60 then
            if c.y > last.y then out[#out] = c end
        else
            out[#out + 1] = c
        end
    end
    return out
end

local function scanRange(now, full)
    local r = { cards = {}, cand = {} }
    local lo, hi = 0, TD_MAX - 1
    if not full then lo, hi = win.lo, win.hi end
    if not full and tokId then
        if sampTextdrawIsExists(tokId) then readTd(tokId, r) else tokId = nil end
    end
    for id = lo, hi do
        if sampTextdrawIsExists(id) then readTd(id, r) end
    end
    if not full then
        if not r.play and mem.play and sampTextdrawIsExists(mem.play) then readTd(mem.play, r) end
        if not r.close and mem.close and sampTextdrawIsExists(mem.close) then readTd(mem.close, r) end
    end
    r.cards = pickCards(r.cand)
    if r.play then mem.play = r.play.id end
    if r.close then mem.close = r.close.id end
    if full then nextFull = now + FULL_EVERY end
    local lo2, hi2 = 1e9, -1
    for _, c in ipairs(r.cards) do
        if c.id < lo2 then lo2 = c.id end
        if c.id > hi2 then hi2 = c.id end
    end
    for _, c in ipairs(r.cand) do                                 -- okno obejmuje tez textdrawy tla kart
        if c.id < lo2 then lo2 = c.id end
        if c.id > hi2 then hi2 = c.id end
    end
    if hi2 >= 0 then
        win = { lo = math.max(0, lo2 - 30), hi = math.min(TD_MAX - 1, hi2 + 30) }
    elseif r.play then
        win = { lo = math.max(0, r.play.id - 30), hi = math.min(TD_MAX - 1, r.play.id + 30) }
    else
        win = nil
    end
    return finish(r)
end

local function scan(now)
    if not win and now < idleUntil then return finish({ cards = {} }) end
    local r = scanRange(now, (not win) or now >= nextFull)
    if not win then idleUntil = now + 0.25 end
    -- brakuje kart albo "Graj": nowe textdrawy moga lezec poza oknem - szybki pelny przeglad
    if win and now >= nextQuick and (#r.cards == 0 or not r.play) then
        nextQuick = now + 0.25
        r = scanRange(now, true)
    end
    return r
end

-- ------------------------------------------------------------ klik mysza (ruch, poprawka ruchu, wcisniecie, puszczenie)
local function clickStep()
    local c = click
    c.f = c.f + 1
    local f = c.f
    pcall(function()
        if f == 1 then
            local h = ffi.C.GetForegroundWindow()
            local r = ffi.new('AK_RECT')
            ffi.C.GetClientRect(h, r)
            local p = ffi.new('AK_POINT')
            p.x = math.floor(c.x / 640 * (r.r - r.l) + 0.5)
            p.y = math.floor(c.y / 448 * (r.b - r.t) + 0.5)
            ffi.C.ClientToScreen(h, p)
            ffi.C.SetCursorPos(p.x, p.y)
        elseif f == 2 then
            ffi.C.mouse_event(0x0001, 1, 0, 0, 0)             -- MOVE +1: gra dostaje zdarzenie ruchu
        elseif f == 3 then
            ffi.C.mouse_event(0x0001, 0xFFFFFFFF, 0, 0, 0)    -- MOVE -1
        elseif f == 4 then
            ffi.C.mouse_event(0x0002, 0, 0, 0, 0)             -- LEFTDOWN
        elseif f == 6 then
            ffi.C.mouse_event(0x0004, 0, 0, 0, 0)             -- LEFTUP
        end
    end)
    if f >= 6 then click = nil end
end

-- proba 0,1,4: mysza (srodek tekstu, potem lekko w bok); 2: klik przez SF.lua w textdraw; 3: w textdraw tuz przed nim.
-- Nigdy w id Zamknij ani jego tla - nie zakonczymy gry przez pomylke.
local RPC_OFFSET = { [2] = 0, [3] = -1 }
local OFFS = { [0] = { 0, 0 }, [1] = { -14, -10 }, [4] = { 14, 10 } }
local CYCLE = 5

local function aim(td, try)
    local o = OFFS[try % CYCLE] or OFFS[0]
    return math.max(2, math.min(638, td.cx + o[1])), math.max(2, math.min(446, td.cy + o[2]))
end

local function press(td, try, close)
    local off = RPC_OFFSET[try % CYCLE]
    local id = off and td.id + off
    if id and close and (id == close.id or id == close.id - 1) then id = nil end
    if id and type(sampSendClickTextdraw) == 'function' then
        pcall(sampSendClickTextdraw, id)
    else
        local ax, ay = aim(td, try)
        click = { x = ax, y = ay, f = 0 }
        log(string.format('kursor -> (%.0f, %.0f) [textdraw %d na %.0f,%.0f]', ax, ay, td.id, td.x, td.y))
    end
end

local function closeClick(td)
    local ax, ay = aim(td, 0)
    click = { x = ax, y = ay, f = 0 }
    if type(sampSendClickTextdraw) == 'function' then
        pcall(sampSendClickTextdraw, td.id)
        pcall(sampSendClickTextdraw, td.id - 1)
    end
end

local function stop(msg)
    if on then log('stop' .. (msg and (': ' .. msg) or '')) end
    on, S, click = false, nil, nil
    if msg then A.say('Kasyno', msg, 'FFB347') end
end

-- ------------------------------------------------------------ logika
-- Gra idzie na zmiane: Graj -> karta -> Graj -> karta... Skrypt pamieta, co jest NASTEPNE (S.expect), i klika tylko to.
-- Zmiana ekranu po kliknieciu potwierdza, ze serwer przyjal klik; bez potwierdzenia ponawiamy te sama akcje.
-- Gdy nastepna akcja jest niemozliwa dluzej (brak Graj / brak kart), skrypt sam sie zsynchronizuje z ekranem.
local function begin(now)
    if type(sampTextdrawIsExists) ~= 'function' then return end
    win, nextFull = nil, 0
    local ok, r = pcall(scan, now)
    if not ok or (#r.cards == 0 and not r.play) then
        A.say('Kasyno', 'Najpierw podejdz do stolika.', 'FFB347')
        return
    end
    S = { stable = 0.22, okRun = 0, try = 0, base = 0, stuck = 0, nextAt = 0, t = now, sig = '', lastSig = '', sigSince = now,
          waiting = false, action = nil, tokAt = nil, rounds = 0, why = 'start', gone = nil, closing = nil,
          close = r.close, memPlay = r.play, expect = r.play and 'play' or 'card' }
    on = true
    log('start, nastepna akcja: ' .. S.expect)
end

local function cursorOff()
    if type(sampIsCursorActive) ~= 'function' then return false end
    local ok, v = pcall(sampIsCursorActive)
    return ok and not v
end

local function step(now)
    if click then return clickStep() end
    if toggleReq then
        toggleReq = false
        if on then return stop() end
        return begin(now)
    end
    if not on then return end

    -- pauzy: nigdy nie wylaczaja, tylko czekaja
    if A.menuOpen or A.chatInputActive() or A.dialogActive() or not A.gameFocused() then
        S.t, S.sigSince, S.why = now, now, 'pauza'
        return
    end
    if now < S.nextAt then return end
    S.nextAt = now + POLL

    local ok, r = pcall(scan, now)
    if not ok then
        S.why = 'blad'
        if S.lastErr ~= r then S.lastErr = r; log('scan: ' .. tostring(r)) end
        return
    end
    local n = #r.cards
    S.close = r.close or S.close
    if r.play then S.memPlay = r.play end

    if S.closing then
        if n == 0 and not r.play then return stop() end
        if now - S.closing.t >= 1.2 then
            S.closing.n, S.closing.t = S.closing.n + 1, now
            if S.closing.n > 4 or not S.close then return stop() end
            closeClick(S.close)
        end
        return
    end

    if n == 0 and not r.play then
        S.gone = S.gone or now
        S.why, S.waiting, S.sigSince = 'brak gry', false, now
        if now - S.gone > GONE_STOP then stop('Nie ma gry w karty - wylaczono.') end
        return
    end
    S.gone = nil
    if n == 0 and cursorOff() then                  -- sam "Graj" bez kursora to nie nasza gra
        S.why, S.t, S.sigSince = 'kursor', now, now
        return
    end

    if r.sig ~= S.lastSig then S.lastSig, S.sigSince = r.sig, now end

    if S.waiting then
        if r.sig ~= S.sig then                      -- ekran sie zmienil: klik przyjety
            S.waiting = false
            S.base = S.try % CYCLE
            if S.try == S.base and S.stuck == 0 then
                S.okRun = S.okRun + 1
                if S.okRun >= 6 then S.okRun, S.stable = 0, math.max(STABLE_MIN, S.stable - 0.02) end
            end
            S.try, S.stuck = S.base, 0
            if S.action == 'card' then
                S.expect, S.revealAt = 'play', S.t           -- odslanianie zaczyna sie od kliku (serwer), nie od chwili, gdy zmiane zobaczylismy
                if r.tokens and S.tokAt and r.tokens < S.tokAt then S.rounds = S.rounds + 1 end
            elseif S.action == 'play' then
                S.expect = 'card'
            end
        elseif now - S.t >= RETRY + math.min(S.stuck, 5) * 0.25 then
            S.waiting = false
            S.okRun, S.stable = 0, math.min(STABLE_MAX, S.stable + 0.06)    -- zgubiony klik: dluzej czekamy na stabilny ekran
            S.try, S.stuck = S.try + 1, S.stuck + 1
            win, nextFull = nil, 0                  -- ekran moze wygladac inaczej niz myslimy: skan od zera
            log(string.format('brak reakcji na %s - ponawiam (proba %d, bez zmian %d)', tostring(S.action), S.try, S.stuck))
        else
            S.why = 'czeka'
            return
        end
    end
    if now - S.sigSince < S.stable then S.why = 'czeka'; return end

    local what = S.expect
    local td

    if what == 'play' then
        if S.revealAt and now - S.revealAt < C.reveal / 1000 then S.why = 'czeka'; return end     -- karta sie jeszcze odslania
        td = r.play
        if not td then
            S.noTarget = S.noTarget or now
            local waited = now - S.noTarget
            if n >= 1 and waited > 4 then                       -- Graj nie pojawia sie, a sa karty: pewnie jestesmy przed wyborem
                S.expect, S.noTarget = 'card', nil
                log('brak Graj od 4 s, widac karty - klikam karte')
            elseif S.memPlay and S.revealAt and waited > 2.5 then
                td = S.memPlay                                  -- Graj nieczytelny: klik w zapamietane miejsce
                log('Graj niewidoczny - klikam zapamietane miejsce')
            else
                S.why = 'czeka'
                return
            end
        end
    else
        if n == 0 then
            S.noTarget = S.noTarget or now
            if r.play and now - S.noTarget > 3 then
                S.expect, S.noTarget = 'play', nil
                log('brak kart od 3 s, widac Graj - klikam Graj')
            end
            S.why = 'czeka'
            return
        end
        if r.tokens and r.tokens < COST then
            if not S.close then return stop('Koniec zetonow.') end
            S.closing, S.why = { t = now, n = 0 }, 'zamykam'
            log('koniec zetonow (' .. r.tokens .. ') - Zamknij')
            closeClick(S.close)
            return
        end
        td = r.cards[math.random(#r.cards)]
    end
    S.noTarget = nil

    S.action, S.sig, S.t, S.waiting, S.why = what, r.sig, now, true, 'klik'
    if what == 'card' then S.tokAt = r.tokens end
    log(string.format('%s | proba %d | kart %d | zetony %s | runda %d', what, S.try, n, tostring(r.tokens), S.rounds))
    press(td, S.try, r.close or S.close)
end

-- ------------------------------------------------------------ modul
function M.init()
    local t = A.loadJson(FILE)
    if t then
        if type(t.key) == 'number' and t.key > 0 then C.key = t.key end
        if type(t.hud) == 'boolean' then C.hud = t.hud end
        if type(t.reveal) == 'number' then C.reveal = A.clamp(math.floor(t.reveal), 800, 2500) end
    end
    save()
    math.randomseed(os.time())
    font = renderCreateFont('Arial', 9, 5)
    local lastErr
    A.worker('kasyno', function()
        wait(0)
        local ok, err = pcall(step, A.now())
        if not ok and err ~= lastErr then
            lastErr = err
            log('blad: ' .. tostring(err))
        end
    end, 'karta')
end

function M.onKey(vk)
    if vk == C.key and not A.chatInputActive() and not A.dialogActive() then toggleReq = true end
end

function M.frame()
    if not C.hud or not A.drawOk or not font or not (on or A.menuOpen) then return end
    local txt = 'Karty'
    if on and S then
        txt = 'Karty ' .. S.rounds
        if S.why == 'pauza' or S.why == 'brak gry' or S.why == 'kursor' or S.why == 'blad' then txt = txt .. '  ' .. S.why end
    end
    local w = renderGetFontDrawTextLength(font, txt)
    local x, y = A.hudPlace('karta', w + 14, 18, 0.47, 0.06)
    renderDrawBox(x, y, w + 14, 18, 0x90000000)
    renderDrawBox(x, y, 3, 18, not on and 0xFF666666 or ((S and S.why == 'czeka' or S and S.why == 'klik') and 0xFF33FF66 or 0xFFFFD24A))
    renderFontDrawText(font, txt, x + 8, y + 2, 0xFFFFFFFF)
end

function M.disable()
    if on then stop() end
end

function M.menuGroup()
    local ui = A.ui
    ui.keyButton('Klawisz', function() return C.key end, function(vk) C.key = vk; save() end,
        'Wejdz w gre w karty i nacisnij ten klawisz. Bot sam wybiera karte i klika Graj, az skoncza sie zetony.')
    ui.sliderInt('Odslanianie', function() return C.reveal end, function(v) C.reveal = v; save() end, 800, 2500, '%d ms',
        'Ile ms od klikniecia karty bot czeka z kliknieciem Graj (karta sie odslania). 1500 ms daje ok. 0,3 s szybsza runde niz wczesniej. Jesli bot zacznie gubic Graj, podnies.')
    ui.check('HUD##karta', function() return C.hud end, function(v) C.hud = v; save() end,
        'Maly licznik rund na ekranie. Przeciagniesz go, gdy menu jest otwarte.')
end

return M
end)(A))

-- ============================================================================
-- MODUL: GORNIK - automatyczna sekwencja klawiszy przy wydobywaniu rudy
-- Gra pokazuje "Aby kopac, nacisnij <KLAWISZ>" i zmienia klawisz po kazdym trafieniu.
-- Z logow diagnostyki:
--  * klawisz wcisniety za szybko (ok. 350 ms) = "Nacisnales niewlasciwy klawisz", od 500 ms
--    od pojawienia sie komunikatu dziala. Bot czeka "ludzki" czas: typowy czas + losowy rozrzut,
--    rytm, ktory powoli plywa, czasem dluzsze zawahanie - ale nigdy ponizej minimum.
--  * prawdziwy komunikat to textdraw na srodku (1093 @320,151). Serwer uzywa tez textdrawow
--    1087/1088 (@282,161) do innych napisow i zostawia w nich stary komunikat o klawiszu.
--    Bot wybiera textdraw, ktory naprawde zmienia sie po wcisnieciach (uczy sie tego sam
--    i zapamietuje), na start ten najblizej srodka; textdrawy z innymi napisami sa pomijane.
-- Hotkey (domyslnie F8) wlacza/wylacza. Makro (spam Y) robi przerwe na czas sekwencji.
-- Diagnostyka: moonloader.log, wpisy [gornik].
-- ============================================================================
A.register((function(A)
local ffi = A.ffi
local floor = math.floor

local M = { id = 'gornik', title = 'Gornik', hidden = true }
local FILE = A.DIR .. '\\gornik.json'
local C = {
    key = 0x77, hud = true, autoOff = true, learn = false, diag = false,      -- F8
    minMs = 500,         -- nigdy szybciej (od pojawienia sie klawisza)
    avgMs = 580,         -- typowy czas
    spreadMs = 45,       -- rozrzut
    useLearned = false,  -- losuj z Twoich zmierzonych czasow
    auto = true,         -- pelny automat: biegnie do rud, kopie wszystkie po kolei
    autoSell = true,     -- na koniec biegnie do punktu sprzedazy i sprzedaje wszystkie mineraly
    sprint = true,       -- pelny automat biegnie sprintem
}

local TD_MAX = 2304
local HOLD_FRAMES = 2                      -- klawisz wcisniety min. 2 klatki i 85-145 ms (krotsze stuniecie serwer gubi)

local on, toggleReq = false, false
local S = nil
local held = nil
local font
local ping, pingAt = 100, 0
local prof = { react = {} }                -- Twoja reakcja z recznego kopania (s)
local trust = {}                           -- "x:y" textdrawa -> ile razy potwierdzil sie jako prawdziwy komunikat
local adapt = 0                            -- dodatkowy zapas po bledach (s), maleje po udanych rudach
local recent = {}                          -- ostatnie czasy (ms) od komunikatu do wcisniecia
local lat = 0.11                           -- srednio: wcisniecie -> nowy komunikat (s)
local lastPress = { id = nil, t = -1e9 }
local cfgDirty = false
local oreTd = { id = nil }
local oreTextInfo                          -- zdefiniowane ponizej
local nextDisc = 0

local function save()
    A.saveJson(FILE, { key = C.key, hud = C.hud, autoOff = C.autoOff, learn = C.learn, diag = C.diag,
        minMs = C.minMs, avgMs = C.avgMs, spreadMs = C.spreadMs, useLearned = C.useLearned,
        auto = C.auto, autoSell = C.autoSell, sprint = C.sprint,
        tempo = { react = prof.react }, trust = trust })
    cfgDirty = false
end
local function log(msg) A.log('gornik', msg) end

-- ------------------------------------------------------------ klawisze
local NAMED = {
    LALT = { 0xA4 }, ALT = { 0xA4 }, LMENU = { 0xA4 }, RALT = { 0xA5, true }, RMENU = { 0xA5, true },
    LSHIFT = { 0xA0 }, SHIFT = { 0xA0 }, RSHIFT = { 0xA1 },
    LCTRL = { 0xA2 }, LCONTROL = { 0xA2 }, CTRL = { 0xA2 }, CONTROL = { 0xA2 }, RCTRL = { 0xA3, true }, RCONTROL = { 0xA3, true },
    RETURN = { 0x0D }, ENTER = { 0x0D }, SPACE = { 0x20 }, TAB = { 0x09 }, BACKSPACE = { 0x08 }, BACK = { 0x08 },
    ESC = { 0x1B }, ESCAPE = { 0x1B }, CAPSLOCK = { 0x14 },
    UP = { 0x26, true }, DOWN = { 0x28, true }, LEFT = { 0x25, true }, RIGHT = { 0x27, true },
    UPARROW = { 0x26, true }, DOWNARROW = { 0x28, true }, LEFTARROW = { 0x25, true }, RIGHTARROW = { 0x27, true },
    ARROWUP = { 0x26, true }, ARROWDOWN = { 0x28, true }, ARROWLEFT = { 0x25, true }, ARROWRIGHT = { 0x27, true },
    INSERT = { 0x2D, true }, INS = { 0x2D, true }, DELETE = { 0x2E, true }, DEL = { 0x2E, true },
    HOME = { 0x24, true }, END = { 0x23, true },
    PGUP = { 0x21, true }, PAGEUP = { 0x21, true }, PGDN = { 0x22, true }, PAGEDOWN = { 0x22, true },
}

-- nazwa z komunikatu ("LALT", "Y", "F5", "NUMPAD3", "MS WHEEL UP"...) -> vk, czy klawisz rozszerzony;
-- dla myszy: vk = 'wheelup' / 'wheeldown' / 'lmb' / 'rmb' / 'mmb'
local function toVk(name)
    local n = tostring(name or ''):upper():gsub('[^%w]', '')
    if n == '' then return nil end
    if n:find('WHEEL', 1, true) or n:find('SCROLL', 1, true) then
        if n:find('UP', 1, true) then return 'wheelup' end
        if n:find('DOWN', 1, true) then return 'wheeldown' end
    end
    if n == 'LMB' or n == 'MOUSE1' or n == 'MOUSELEFT' or n == 'MSLEFT' or n == 'LEFTMOUSE' or n == 'LEFTCLICK' then return 'lmb' end
    if n == 'RMB' or n == 'MOUSE2' or n == 'MOUSERIGHT' or n == 'MSRIGHT' or n == 'RIGHTMOUSE' or n == 'RIGHTCLICK' then return 'rmb' end
    if n == 'MMB' or n == 'MOUSE3' or n == 'MOUSEMIDDLE' or n == 'MSMIDDLE' or n == 'MIDDLEMOUSE' then return 'mmb' end
    local e = NAMED[n]
    if e then return e[1], e[2] end
    local f = tonumber(n:match('^F(%d+)$'))
    if f and f >= 1 and f <= 12 then return 0x6F + f end
    local d = tonumber(n:match('^NUM[PAD]*(%d)$'))
    if d then return 0x60 + d end
    if #n == 1 then return n:byte() end
    return nil
end

-- lewy/prawy Alt, Shift, Ctrl przychodza w WM_KEYDOWN jako zwykly Alt/Shift/Ctrl
local function normVk(v)
    if v == 0xA4 or v == 0xA5 then return 0x12 end
    if v == 0xA0 or v == 0xA1 then return 0x10 end
    if v == 0xA2 or v == 0xA3 then return 0x11 end
    return v
end

local MOUSE = {
    lmb = { down = 0x0002, up = 0x0004 }, rmb = { down = 0x0008, up = 0x0010 }, mmb = { down = 0x0020, up = 0x0040 },
}

-- klawisz wcisniety przez bota: rdzen nie traktuje go jak skrotu (np. strzalki = Makro, F-klawisze)
local function markSynth(vk)
    A.synth = { vk = (vk == 'wheelup' or vk == 'wheeldown') and 'wheel' or normVk(vk), untilT = A.now() + 0.08 }
end

local function keyEvent(vk, ext, up)
    if not up then markSynth(vk) end
    if type(vk) == 'string' then
        pcall(function()
            if vk == 'wheelup' or vk == 'wheeldown' then
                if not up then ffi.C.mouse_event(0x0800, 0, 0, vk == 'wheelup' and 120 or 0xFFFFFF88, 0) end   -- WHEEL
                return
            end
            local m = MOUSE[vk]
            if m then ffi.C.mouse_event(up and m.up or m.down, 0, 0, 0, 0) end
        end)
        return
    end
    pcall(function()
        local scan = tonumber(ffi.C.MapVirtualKeyA(vk, 0)) or 0
        local flags = (up and 2 or 0) + (ext and 1 or 0)
        if scan ~= 0 then
            ffi.C.keybd_event(0, scan, flags + 8, 0)           -- KEYEVENTF_SCANCODE
        else
            ffi.C.keybd_event(vk, 0, flags, 0)
        end
    end)
end

local function release()
    if held then
        keyEvent(held.vk, held.ext, true)
        held = nil
    end
end

-- ------------------------------------------------------------ ludzki czas reakcji
local function gauss()                     -- ~N(0, 1) z sumy 4 rownomiernych
    return (math.random() + math.random() + math.random() + math.random() - 2) * 1.732
end

local drift = 0                            -- rytm, ktory powoli plywa (raz seria szybsza, raz wolniejsza)

-- czas od pojawienia sie klawisza do wcisniecia (s); first = pierwszy klawisz na skale, same = ten sam co poprzednio
local function humanDelay(first, same)
    local minS = C.minMs / 1000 + adapt
    local sd = C.spreadMs / 1000
    local d
    if C.useLearned and #prof.react >= 8 then
        d = prof.react[math.random(#prof.react)] + gauss() * 0.012 + adapt
    else
        drift = A.clamp(drift * 0.85 + gauss() * sd * 0.35, -sd * 1.5, sd * 1.5)
        d = math.max(C.avgMs, C.minMs) / 1000 + adapt + drift + gauss() * sd * 0.8
        if math.random() < 0.06 then d = d + 0.12 + math.random() * 0.25 end    -- zawahanie
    end
    if first then d = d + 0.10 + math.random() * 0.30 end
    if same then d = d - 0.03 * math.random() end
    -- ponizej minimum: odbicie w gore (zeby nie bylo co chwile rowno minimum)
    if d < minS then d = minS + math.min((minS - d) * 0.6, math.max(sd, 0.01)) + math.random() * 0.012 end
    return math.min(d, minS + 1.2)
end

local function pushRecent(ms)
    recent[#recent + 1] = ms
    if #recent > 20 then table.remove(recent, 1) end
end

-- ------------------------------------------------------------ komunikat
local function fold(s)
    s = tostring(s or ''):lower()
    s = s:gsub('~%a~', ' '):gsub('{%x%x%x%x%x%x}', ''):gsub('%s+', ' ')
    return (s:gsub('^ ', ''):gsub(' $', ''))
end

-- "aby kopac, nacisnij lalt aby przerwac, wcisnij return" -> "lalt"
local function promptKey(text)
    local t = fold(text)
    if not t:find('kop', 1, true) then return nil end
    local rest = t:match('naci%S-nij%s+(.+)')
    if not rest then return nil end
    rest = rest:match('^(.-)%s+aby%s') or rest              -- druga linia: "Aby przerwac, wcisnij RETURN"
    rest = rest:gsub('[%.,;:!]+$', '')
    if rest == '' or #rest > 24 then return nil end
    return rest
end

-- Wszystkie textdrawy, w ktorych pojawil sie komunikat o klawiszu, sa sledzone CALY CZAS (takze gdy bot
-- jest wylaczony), wiec wiadomo, kiedy naprawde zmienil sie tekst i czy textdraw nie sluzy tez do innych napisow.
local PR = {}                                   -- id -> { id, x, y, pk, key, text, changedAt, live, otherAt }

local function prCount()
    local n = 0
    for _ in pairs(PR) do n = n + 1 end
    return n
end

local function readPos(e)
    local okp, x, y = pcall(sampTextdrawGetPos, e.id)
    if okp and type(x) == 'number' then
        e.x, e.y = x, y
        e.pk = string.format('%d:%d', floor(x + 0.5), floor(y + 0.5))
    end
end

local function addPrompt(id, now)
    if PR[id] or prCount() >= 10 then return end
    local e = { id = id, live = false, changedAt = now }
    readPos(e)
    PR[id] = e
end

-- jeden pelny przeglad textdrawow (co 0.7 s): komunikaty o klawiszu i napis przy skale
local function discover(now)
    if now < nextDisc then return end
    nextDisc = now + 0.7
    for id = 0, TD_MAX - 1 do
        if sampTextdrawIsExists(id) then
            local ok, text = pcall(sampTextdrawGetString, id)
            if ok and type(text) == 'string' then
                if promptKey(text) then
                    addPrompt(id, now)
                elseif oreTextInfo and oreTextInfo(text) then
                    oreTd.id = id
                end
            end
        end
    end
end

-- okno wokol znanych id (co klatke): nowy komunikat w sasiednim textdrawie widac od razu
local function scanNeighbours(now)
    local lo, hi = 1e9, -1
    for id in pairs(PR) do
        if id < lo then lo = id end
        if id > hi then hi = id end
    end
    if hi < 0 then return end
    lo, hi = math.max(0, lo - 24), math.min(TD_MAX - 1, hi + 24)
    if hi - lo > 160 then return end
    for id = lo, hi do
        if not PR[id] and sampTextdrawIsExists(id) then
            local ok, t = pcall(sampTextdrawGetString, id)
            if ok and type(t) == 'string' and promptKey(t) then addPrompt(id, now) end
        end
    end
end

-- co klatke: stan kazdego sledzonego textdrawa
local function track(now)
    if type(sampTextdrawIsExists) ~= 'function' then return end
    discover(now)
    scanNeighbours(now)
    for id, e in pairs(PR) do
        local text
        if sampTextdrawIsExists(id) then
            local ok, t = pcall(sampTextdrawGetString, id)
            if ok and type(t) == 'string' then text = t end
        end
        local k = text and promptKey(text)
        if k then
            if not e.live or e.text ~= text then
                -- tekst zmienil sie zaraz po wcisnieciu w ten textdraw = to jest prawdziwy komunikat
                if e.live and lastPress.id == id and now - lastPress.t < 0.9 then
                    if e.pk then trust[e.pk] = math.min(30, (trust[e.pk] or 0) + 1) end
                    lat = A.clamp(lat * 0.8 + (now - lastPress.t) * 0.2, 0.03, 0.6)
                    lastPress.id, cfgDirty = nil, true
                end
                e.changedAt = now
                readPos(e)
            end
            e.key, e.text, e.live = k, text, true
        else
            if text and #text > 1 then e.otherAt = now end          -- textdraw sluzy tez do innych napisow
            e.key, e.text, e.live = nil, nil, false
        end
    end
end

local function prior(e)                         -- prawdziwy komunikat jest na srodku ekranu (320,151)
    if not e.x then return -0.5 end
    return -math.abs(e.x - 320) / 200 - math.abs(e.y - 150) / 400
end

local function score(e, now)
    local s = (trust[e.pk or ''] or 0) + prior(e)
    if e.otherAt and now - e.otherAt < 15 then s = s - 3 end
    return s
end

-- aktualny komunikat: najbardziej zaufany z widocznych; po przerwaniu/zakonczeniu tylko ten, ktory sie potem zmienil
local function pick(now)
    if S and S.cutAt and now - S.cutAt > 4 then S.cutAt = nil end     -- na wypadek tego samego tekstu: blokada wygasa
    local best, bs
    for _, e in pairs(PR) do
        if e.live then
            local sc = score(e, now)
            if sc > -1 and (not best or sc > bs or (sc == bs and e.changedAt > best.changedAt)) then best, bs = e, sc end
        end
    end
    if not best then return nil end
    if S and S.cutAt and best.changedAt <= S.cutAt then return nil, 'nieaktualny' end
    return best
end

local function prState(now)
    local t = {}
    for id, e in pairs(PR) do
        t[#t + 1] = string.format('%d@%s=%s(%s, %.2fs, pkt %.1f)', id, e.pk or '?', e.key and e.key:upper() or '-',
            e.live and 'widoczny' or 'ukryty', e.live and (now - e.changedAt) or -1, score(e, now))
    end
    table.sort(t)
    return table.concat(t, ' ')
end

local function getPing(now)
    if now - pingAt > 2 then
        pingAt = now
        pcall(function()
            local ok, id = sampGetPlayerIdByCharHandle(PLAYER_PED)
            if ok then ping = tonumber(sampGetPlayerPing(id)) or ping end
        end)
    end
    return ping
end

-- ------------------------------------------------------------ rudy NA ZYWO
-- Nic nie jest zapamietywane: co 0.4 s lista skal budowana jest od nowa z tego, co serwer TERAZ
-- wyslal (etykiety 3D "Ruda ... / Zuzycie: N%"). Wykopana albo przeniesiona przy respawnie skala
-- znika od razu, nowa pojawia sie, gdy tylko serwer ja wysle (zasieg streamingu).
-- Opcjonalnie: obiekty skal (model uczony z etykiet) - zwykle widac je z dalszej odleglosci.
local ORES = {
    { key = 'weg',    rgb = 0x9A9A9A, cheap = true },
    { key = 'zlot',   rgb = 0xFFD24A },
    { key = 'jadeit', rgb = 0x33FF99 },
    { key = 'srebr',  rgb = 0xD0D0FF },
    { key = 'mied',   rgb = 0xFF9A3C },
    { key = 'zelaz',  rgb = 0xC0643C },
    { key = 'diament', rgb = 0x4AE8FF },
}

local function oreInfo(name)
    local n = fold(name)
    for _, o in ipairs(ORES) do
        local pat = o.key == 'weg' and 'w.giel' or o.key        -- "wegiel" w CP1250 ma 'e' z ogonkiem
        if n:find(pat) then return o end
    end
    return { rgb = 0xFFFFFF }
end

local function curInterior()
    local ok, i = pcall(getActiveInterior)
    return ok and i or 0
end

local ore = {
    C = { markers = true, radar = true, objects = false },
    spots = {},            -- wszystko, co widac TERAZ (etykiety + obiekty)
    labels = {},           -- skaly z etykiet 3D (dokladne)
    objs = {},             -- skaly z obiektow bez etykiety w poblizu
    models = {}, bad = {}, taught = {}, seen = {},
    dirty = false, nextScan = 0, nextObj = 0, nextSave = 0,
    trail = {},            -- slad chodzenia po kopalni { x, y, z, int } - do szukania drogi
    sellPos = nil,         -- punkt sprzedazy mineralow (staly)
    points = {},           -- wszystkie miejsca, gdzie kiedykolwiek byla ruda { x, y, z, int, checked, bad }
    checkAt = 0,
}

-- Miejsca rud zapamietywane na stale: etykiety widac tylko z bliska, wiec przed sprzedaza bot obchodzi
-- kazde znane miejsce, ktorego nie widzial z bliska od 2 min - sprzedaje dopiero, gdy nigdzie nie ma rudy.
local CHECK_R, CHECK_TTL = 15, 120

local function orePoints(list)
    for _, s in ipairs(list) do
        local found = false
        for _, p in ipairs(ore.points) do
            if (p.x - s.x) ^ 2 + (p.y - s.y) ^ 2 < 6.25 and math.abs(p.z - s.z) < 3 then found = true; break end
        end
        if not found and #ore.points < 400 then
            ore.points[#ore.points + 1] = { x = s.x, y = s.y, z = s.z, int = s.int or 0 }
            ore.dirty = true
        end
    end
end

local function markChecked(px, py, now)
    if now < ore.checkAt then return end
    ore.checkAt = now + 0.5
    local int = curInterior()
    for _, p in ipairs(ore.points) do
        if (p.int or 0) == int and (p.x - px) ^ 2 + (p.y - py) ^ 2 < CHECK_R * CHECK_R then p.checked = now end
    end
end

-- najblizsze znane miejsce rudy, ktorego dawno nie widzielismy z bliska
local function orePointToCheck(px, py, now)
    local int, best, bd = curInterior(), nil, nil
    for _, p in ipairs(ore.points) do
        if (p.int or 0) == int and not (p.checked and now - p.checked < CHECK_TTL) and not (p.bad and p.bad > now) then
            local d = (p.x - px) ^ 2 + (p.y - py) ^ 2
            if not bd or d < bd then best, bd = p, d end
        end
    end
    return best
end
local OFILE = A.DIR .. '\\rudy.json'
local LEARN_R2, MERGE_R2 = 2.5 * 2.5, 4 * 4

local function oreSave()
    local ms = {}
    for m, e in pairs(ore.models) do
        local names, pos = {}, {}
        for n in pairs(e.names) do names[#names + 1] = n end
        for p in pairs(e.pos) do if #pos < 40 then pos[#pos + 1] = p end end
        ms[tostring(m)] = { votes = e.votes, names = names, pos = pos }
    end
    local sp = ore.sellPos
    local tr = {}
    for i, n in ipairs(ore.trail) do
        tr[i] = { floor(n[1] * 10 + 0.5) / 10, floor(n[2] * 10 + 0.5) / 10, floor(n[3] * 10 + 0.5) / 10, n[4] }
    end
    local pts = {}
    for i, p in ipairs(ore.points) do
        pts[i] = { floor(p.x * 10 + 0.5) / 10, floor(p.y * 10 + 0.5) / 10, floor(p.z * 10 + 0.5) / 10, p.int or 0 }
    end
    A.saveJson(OFILE, { markers = ore.C.markers, radar = ore.C.radar, objects = ore.C.objects, models = ms,
        sell = sp and { sp.x, sp.y, sp.z } or nil, trail = tr, points = pts })
    ore.dirty = false
end

local function oreLoad()
    local t = A.loadJson(OFILE)
    if not t then return end
    for _, k in ipairs({ 'markers', 'radar', 'objects' }) do
        if type(t[k]) == 'boolean' then ore.C[k] = t[k] end
    end
    if type(t.models) == 'table' then
        for k, e in pairs(t.models) do
            local m = tonumber(k)
            if m and type(e) == 'table' and tonumber(e.votes) then
                local names, pos, n = {}, {}, 0
                for _, v in ipairs(type(e.names) == 'table' and e.names or {}) do names[tostring(v)] = true end
                for _, p in ipairs(type(e.pos) == 'table' and e.pos or {}) do
                    if not pos[p] then pos[p], n = true, n + 1 end
                end
                ore.models[m] = { votes = tonumber(e.votes), names = names, pos = pos, distinct = n }
            end
        end
    end
    if type(t.trail) == 'table' then
        for _, n in ipairs(t.trail) do
            if type(n) == 'table' and tonumber(n[1]) and tonumber(n[2]) and tonumber(n[3]) then
                ore.trail[#ore.trail + 1] = { tonumber(n[1]), tonumber(n[2]), tonumber(n[3]), tonumber(n[4]) or 0 }
            end
        end
    end
    if type(t.sell) == 'table' and tonumber(t.sell[1]) and tonumber(t.sell[2]) then
        ore.sellPos = { x = tonumber(t.sell[1]), y = tonumber(t.sell[2]), z = tonumber(t.sell[3]) or 0 }
    end
    if type(t.points) == 'table' then
        for _, p in ipairs(t.points) do
            if type(p) == 'table' and tonumber(p[1]) and tonumber(p[2]) and tonumber(p[3]) and #ore.points < 400 then
                ore.points[#ore.points + 1] = { x = tonumber(p[1]), y = tonumber(p[2]), z = tonumber(p[3]), int = tonumber(p[4]) or 0 }
            end
        end
    end
    -- stare zapamietane pozycje skal ('spots') celowo pomijamy: rudy respawnuja sie w innych miejscach
    if type(t.spots) == 'table' then ore.dirty = true end
end

local function spotKey(s)
    return string.format('%d:%d:%d', floor(s.x + 0.5), floor(s.y + 0.5), floor(s.z + 0.5))
end

-- wykopane skaly: serwer zostawia etykiete, wiec chowamy je sami (az etykieta zniknie / respawn / 20 min)
local mined = {}                         -- { x, y, z, at, seenAt }

local function minedIdx(x, y, z)
    for i, m in ipairs(mined) do
        if (m.x - x) ^ 2 + (m.y - y) ^ 2 + (m.z - z) ^ 2 < 4 then return i end
    end
end

local function rebuildSpots()
    local all, sig = {}, {}
    for _, s in ipairs(ore.labels) do
        if (s.wear or 0) < 100 and not s.done and not minedIdx(s.x, s.y, s.z) then all[#all + 1] = s end
    end
    if ore.C.objects then
        for _, s in ipairs(ore.objs) do
            if not minedIdx(s.x, s.y, s.z) then all[#all + 1] = s end
        end
    end
    for i, s in ipairs(all) do sig[i] = spotKey(s) end
    sig = table.concat(sig, ',')
    if sig ~= ore.spotSig then ore.spotSig, ore.blipsDirty = sig, true end     -- radar od razu, bez czekania na 1 s
    ore.spots = all
end

local lastMined = nil                    -- { s, at }: ostatnio oznaczona jako wykopana (do cofniecia po porazce)

local function markMined(s, now)
    if not s or minedIdx(s.x, s.y, s.z) then return end
    lastMined = { s = s, at = now }
    mined[#mined + 1] = { x = s.x, y = s.y, z = s.z, at = now, seenAt = now }
    log(string.format('skala %s (%.0f %.0f) wykopana - chowam znacznik i punkt na radarze', tostring(s.name or '?'), s.x, s.y))
    rebuildSpots()
end

-- "Nie udalo sie wydobyc mineralu": skala nie jest wykopana, wraca na liste i radar
local function unmarkMined(s)
    local i = minedIdx(s.x, s.y, s.z)
    while i do
        table.remove(mined, i)
        i = minedIdx(s.x, s.y, s.z)
    end
    rebuildSpots()
end

local function nearestLabel(px, py, r)
    local best, bd
    for _, s in ipairs(ore.labels) do
        local d = (s.x - px) ^ 2 + (s.y - py) ^ 2
        if d < r * r and (not bd or d < bd) then best, bd = s, d end
    end
    return best
end

local function labelName(text)
    local raw = A.stripColors(text):gsub('~n~', '\n'):gsub('~%a~', '')
    for line in raw:gmatch('[^\r\n]+') do
        local t = A.trim(line)
        t = A.trim(t:match('^(.-)%s*[Zz]u%S-ycie') or t)
        if t ~= '' then return t:sub(1, 40) end
    end
    return 'Ruda'
end

local function scanLabels(now)
    if now < ore.nextScan then return end
    ore.nextScan = now + 0.4
    if type(sampIs3dTextDefined) ~= 'function' or type(sampGet3dTextInfoById) ~= 'function' then return end
    local list, int = {}, curInterior()
    for i = 0, 2047 do
        if sampIs3dTextDefined(i) then
            local ok, text, _, x, y, z = pcall(sampGet3dTextInfoById, i)
            if ok and type(text) == 'string' and x and not (x == 0 and y == 0 and z == 0) then
                local ft = fold(text)
                local wear = tonumber(ft:match('zu%S-ycie:%s*(%d+)'))
                if not wear and ft:find('punkt sprzeda', 1, true) and ft:find('minera', 1, true) then
                    local sp = ore.sellPos                   -- punkt sprzedazy stoi zawsze w tym samym miejscu
                    if not sp or (sp.x - x) ^ 2 + (sp.y - y) ^ 2 > 1 then
                        ore.sellPos, ore.dirty = { x = x, y = y, z = z }, true
                        log(string.format('punkt sprzedazy mineralow: %.1f %.1f %.1f', x, y, z))
                    end
                end
                if wear then
                    local s = { x = x, y = y, z = z, name = labelName(text), wear = wear, int = int, live = true, src = 'label',
                        startKey = ft:match('naci%S-nij%s+([%w]+)'),
                        done = (ft:find('ju%S*%s+wydoby') or ft:find('wydoby%S*%s+ju')) ~= nil }   -- "Juz wydobyles te rude!"
                    list[#list + 1] = s
                    if C.diag then
                        local k = spotKey(s)
                        if not ore.seen[k] then
                            ore.seen[k] = true
                            log(string.format('[diag] skala na zywo: etykieta #%d "%s" %.1f %.1f %.1f zuzycie %d%%', i, s.name, x, y, z, wear))
                        end
                    end
                end
            end
        end
    end
    if C.diag and #list == 0 and next(ore.seen) then ore.seen = {} end
    -- wykopane: etykieta zniknela (gracz blisko) albo minelo 20 min = skala moze byc znowu dostepna
    local okp, px, py = pcall(getCharCoordinates, PLAYER_PED)
    for i = #mined, 1, -1 do
        local m, here = mined[i], false
        for _, s in ipairs(list) do
            if (s.x - m.x) ^ 2 + (s.y - m.y) ^ 2 + (s.z - m.z) ^ 2 < 4 then here = true; break end
        end
        local respawn = false
        for _, s in ipairs(list) do
            if (s.x - m.x) ^ 2 + (s.y - m.y) ^ 2 + (s.z - m.z) ^ 2 < 4 then
                -- zuzycie zapamietane 3 s po wydobyciu; inna wartosc pozniej = skala sie odrodzila
                if m.wear == nil then
                    if now - m.at > 3 then m.wear = s.wear end
                elseif s.wear ~= m.wear then
                    respawn = true
                end
                break
            end
        end
        if here then m.seenAt = now end
        local near = okp and px and (m.x - px) ^ 2 + (m.y - py) ^ 2 < 60 * 60
        if respawn or now - m.at > 1200 or (not here and near and now - m.seenAt > 10) then table.remove(mined, i) end
    end
    ore.labels = list
    orePoints(list)
    rebuildSpots()
end

-- model skaly jest wiarygodny, gdy byl najblizszym obiektem przy etykiecie w >= 3 ROZNYCH miejscach
-- (jedna bryla kopalni / sciana nie przejdzie) i nie jest masowa dekoracja
local function modelActive(m)
    local e = ore.models[m]
    return e ~= nil and not ore.bad[m] and e.votes >= 3 and (e.distinct or 0) >= 3
end

local function scanObjects(now)
    if not ore.C.objects then
        if #ore.objs > 0 then ore.objs = {}; rebuildSpots() end
        return
    end
    if now < ore.nextObj then return end
    ore.nextObj = now + 1.0
    local okAll, objs = pcall(getAllObjects)
    if not okAll or type(objs) ~= 'table' then return end
    local labels = ore.labels
    local best, perModel, found = {}, {}, {}
    for _, obj in ipairs(objs) do
        if doesObjectExist(obj) then
            local m = getObjectModel(obj)
            local okc, _, x, y, z = pcall(getObjectCoordinates, obj)
            if okc and x then
                perModel[m] = (perModel[m] or 0) + 1
                for li, L in ipairs(labels) do
                    local d2 = (L.x - x) ^ 2 + (L.y - y) ^ 2 + (L.z - z) ^ 2
                    if d2 < LEARN_R2 and (not best[li] or d2 < best[li].d2) then best[li] = { m = m, d2 = d2, x = x, y = y } end
                end
                if ore.models[m] then found[#found + 1] = { m = m, x = x, y = y, z = z } end
            end
        end
    end

    -- nauka: kazda etykieta (pozycja) uczy raz
    for li, L in ipairs(labels) do
        local k = spotKey(L)
        local b = best[li]
        if b and not ore.taught[k] then
            ore.taught[k] = true
            local e = ore.models[b.m]
            if not e then e = { votes = 0, names = {}, pos = {}, distinct = 0 }; ore.models[b.m] = e end
            e.votes = e.votes + 1
            e.names[L.name] = true
            local pk = string.format('%d:%d', floor(b.x), floor(b.y))
            if not e.pos[pk] then e.pos[pk], e.distinct = true, e.distinct + 1 end
            ore.dirty = true
            log(string.format('skala "%s": obiekt model %d (%.1f m), glosow %d, miejsc %d', L.name, b.m, math.sqrt(b.d2), e.votes, e.distinct))
        end
    end
    for m, n in pairs(perModel) do
        if n > 80 and ore.models[m] and not ore.bad[m] then
            ore.bad[m] = true
            log('model ' .. m .. ' odrzucony jako dekoracja (' .. n .. ' obiektow)')
        end
    end

    local list, int = {}, curInterior()
    for _, f in ipairs(found) do
        if modelActive(f.m) then
            local dup = false
            for _, L in ipairs(labels) do
                if (L.x - f.x) ^ 2 + (L.y - f.y) ^ 2 + (L.z - f.z) ^ 2 < MERGE_R2 then dup = true; break end
            end
            if not dup then
                local only, cnt = nil, 0
                for nm in pairs(ore.models[f.m].names) do only, cnt = nm, cnt + 1 end
                list[#list + 1] = { x = f.x, y = f.y, z = f.z, name = (cnt == 1) and only or 'Ruda', int = int, live = true, src = 'obj' }
            end
        end
    end
    ore.objs = list
    rebuildSpots()
end

local function oreHidden(s)
    return s.int ~= nil and s.int ~= curInterior()
end

-- ------------------------------------------------------------ komunikaty serwera
-- "Nacisnales niewlasciwy klawisz! Wydobycie zostalo przerwane." (w CP1250 'niewlasciwy' ma bajty 179/156)
local function wrongText(f)
    if f:find('niew%S-ciwy%s+klawisz') or f:find('wydobycie zosta%S*%s+przerwane', 1) then return true end
    return (f:find('nieprawid', 1, true) or f:find('niepopraw', 1, true) or f:find('bledn', 1, true) or f:find('pomyl', 1, true))
        and (f:find('klawisz', 1, true) or f:find('przycisk', 1, true))
end

-- jeden przeglad textdrawow: komunikat "Wydobycie zakonczone" i blad klawisza
local function scanMessages()
    local done, wrong = false, nil
    for id = 0, TD_MAX - 1 do
        if sampTextdrawIsExists(id) then
            local ok, text = pcall(sampTextdrawGetString, id)
            if ok and type(text) == 'string' then
                local f = fold(text)
                if f:find('wydobycie zako', 1, true) then done = true end
                if wrongText(f) then wrong = f:sub(1, 60) end
            end
        end
    end
    return done, wrong
end

local function noteWrong(now, what)
    if not S or now - S.wrongAt < 1.5 then return end
    S.wrongAt = now
    S.wrong = (S.wrong or 0) + 1
    local e = S.pressId and PR[S.pressId]
    local pk = e and e.pk
    local why
    if pk and (trust[pk] or 0) >= 5 then
        -- pewny textdraw: to byl czas (za szybko) - dokladamy zapas
        adapt = math.min(0.15, adapt + 0.04)
        why = string.format('za szybko? zapas +%d ms', floor(adapt * 1000 + 0.5))
    else
        if pk then trust[pk] = math.max(-10, (trust[pk] or 0) - 2) end
        adapt = math.min(0.15, adapt + 0.02)
        why = string.format('textdraw %s niepewny (pkt %.0f), zapas +%d ms', tostring(pk), pk and trust[pk] or 0, floor(adapt * 1000 + 0.5))
    end
    cfgDirty = true
    log(string.format('serwer: niewlasciwy klawisz (%s) - %s. Wcisniecia: %s | komunikaty: %s', tostring(what), why,
        table.concat(S.hist or {}, ' '), prState(now)))
    -- wydobycie przerwane: stare komunikaty sa nieaktualne, dopoki sie nie zmienia
    S.active, S.presses, S.lastKey, S.plan, S.cutAt = false, 0, nil, nil, now
end

-- ------------------------------------------------------------ nauka tempa od gracza
-- Gdy bot jest wylaczony, a Ty kopiesz recznie, skrypt zapisuje Twoj czas reakcji
-- (od zmiany komunikatu do wcisniecia). Potem bot moze losowac z tych czasow.
local learn = { lastAt = nil, n = 0 }

local function learnPress(pressed)                          -- pressed: vk (liczba) albo 'wheelup'/'wheeldown'
    if on then return end
    local t = A.now()
    local e = pick(t)
    if not e then return end
    local want = toVk(e.key)
    if not want or normVk(want) ~= normVk(pressed) then return end
    lastPress.id, lastPress.t = e.id, t                     -- Twoje trafienia tez ucza, ktory textdraw jest prawdziwy
    if learn.lastAt and e.changedAt <= learn.lastAt then    -- ten sam komunikat co poprzednio: nie wiadomo, od kiedy liczyc
        learn.lastAt = t
        return
    end
    learn.lastAt = t
    local dt = t - e.changedAt
    if dt > 0.12 and dt < 1.5 then
        prof.react[#prof.react + 1] = dt
        if #prof.react > 60 then table.remove(prof.react, 1) end
        cfgDirty = true
        learn.n = learn.n + 1
        if learn.n <= 8 then log(string.format('nauka: %s po %d ms', tostring(e.key), floor(dt * 1000 + 0.5))) end
    end
end

local function median(list)
    if #list == 0 then return nil end
    local t = {}
    for i, v in ipairs(list) do t[i] = v end
    table.sort(t)
    return t[math.ceil(#t / 2)]
end

-- ------------------------------------------------------------ diagnostyka (Boty -> Gornik Bot -> Diagnostyka)
local diagTd = { known = nil, nextAt = 0 }

local function nearestSpot(px, py)
    local best, bd
    for _, s in ipairs(ore.spots) do
        local d = (s.x - px) ^ 2 + (s.y - py) ^ 2
        if not bd or d < bd then best, bd = s, d end
    end
    return best, bd and math.sqrt(bd)
end

local function diagPrompt(e, d, now)
    pcall(function()
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        local h = getCharHeading(PLAYER_PED)
        local s, dist = nearestSpot(px, py)
        local rel = s and ((math.deg(math.atan2(-(s.x - px), s.y - py)) - h + 180) % 360 - 180) or 0
        log('[diag] komunikaty: ' .. prState(now))
        log(string.format('[diag] klawisz %s | td %d @%s | plan %d ms | gracz %.1f %.1f %.1f h%.0f int %d | skala %s %.1f m, kat %+.0f',
            tostring(e.key):upper(), e.id, e.pk or '?', floor(d * 1000 + 0.5), px, py, pz, h, curInterior(),
            s and s.name or '-', dist or -1, rel))
    end)
end

local function diagNewTextdraws(now)
    if now < diagTd.nextAt then return end
    diagTd.nextAt = now + 0.5
    local cur = {}
    for id = 0, TD_MAX - 1 do
        if sampTextdrawIsExists(id) then
            local ok, text = pcall(sampTextdrawGetString, id)
            cur[id] = ok and tostring(text) or '?'
        end
    end
    if diagTd.known then
        local n = 0
        for id, text in pairs(cur) do
            if diagTd.known[id] ~= text and not (PR[id] and PR[id].live) and n < 8 then
                n = n + 1
                local okp, x, y = pcall(sampTextdrawGetPos, id)
                log(string.format('[diag] textdraw %d: "%s" @%s', id, text:gsub('[\r\n]', ' '):sub(1, 90), okp and string.format('%.0f,%.0f', x or 0, y or 0) or '?'))
            end
        end
    end
    diagTd.known = cur
end

-- ------------------------------------------------------------ logika
local function newState(now)
    return { active = false, presses = 0, lastKey = nil, pressAt = -1e9, pressId = nil, absent = nil, ores = 0,
        cool = 0, why = 'czeka', unknown = {}, nextMsg = 0, doneChat = false, wrongAt = -1e9, hist = {},
        plan = nil, cutAt = nil, startAt = now, paused = false, lastDelay = nil }
end

local AP = nil                                  -- autopilot (pelny automat), nil = wylaczony

local function apHalt()
    if not AP then return end
    if AP.keyUp then keyEvent(AP.keyUp.vk, AP.keyUp.ext, true); AP.keyUp = nil end
    if AP.tasked then pcall(clearCharTasks, PLAYER_PED); AP.tasked = false end
    AP.taskWp = nil
end

local function stop()
    release()
    pcall(apHalt)
    on, S, AP = false, nil, nil
    A.miningBusy, A.minerAuto = false, false
end

local function blocked()
    return A.menuOpen or A.pauseActive() or A.chatInputActive() or A.dialogActive() or not A.gameFocused()
end

-- ------------------------------------------------------------ pelny automat: bieg do rud, kopanie, sprzedaz
-- Trasa: A* po siatce 0.8 m budowanej leniwie z kolizji gry (processLineOfSight / isLineOfSightClear,
-- budynki + obiekty SA-MP). Liczone po kawalku co klatke (budzet czasu), krawedzie w cache (kopalnia jest
-- statyczna, kolejne trasy ida z pamieci). Zablokowany = tymczasowa blokada przed postacia + nowa trasa.
local nmax, nmin, nsqrt, nceil = math.max, math.min, math.sqrt, math.ceil

local NV = A.newNav({
    tag = 'gornik',
    CELL = 0.8,                -- komorka siatki [m]
    CLEAR = 0.32,              -- polowa szerokosci postaci (promienie boczne)
    H_LOW = 0.6, H_MID = 0.95, H_HIGH = 1.4,   -- wysokosci promieni nad ziemia
    STEP_UP = 0.7, STEP_DOWN = 1.2,            -- max roznica wysokosci miedzy sasiednimi komorkami
    GOAL_R = 3.2,              -- cel: komorka w tej odleglosci od srodka skaly, z ktorej widac skale
    DIRECT_MAX = 45,           -- do tej odleglosci najpierw test prostej drogi
    MARGIN = 30, MAX_EXP = 8000, WEIGHT = 1.3, BUDGET = 0.004, CACHE_TTL = 300,
})
local NAV = NV.p
local navRay, navGround, navFeet, navCorridor, entityPos = NV.ray, NV.ground, NV.feet, NV.corridor, NV.entityPos
local navStart, navRun = NV.start, NV.run

-- podglad trasy (tylko z Diagnostyka)
local function drawNav()
    if not (AP and AP.path) then return end
    local prev
    for i = AP.wi, #AP.path do
        local w = AP.path[i]
        local sx, sy
        if isPointOnScreen(w.x, w.y, w.z, 0.5) then sx, sy = convert3DCoordsToScreen(w.x, w.y, w.z) end
        if sx then
            if prev then renderDrawLine(prev[1], prev[2], sx, sy, 2, w.final and 0xFFFF6666 or 0xFF66FFCC) end
            renderDrawBox(sx - 2, sy - 2, 4, 4, w.final and 0xFFFF6666 or 0xFF66FFCC)
            prev = { sx, sy }
        else
            prev = nil
        end
    end
end

local function headingTo(px, py, x, y) return math.deg(math.atan2(-(x - px), y - py)) % 360 end

local function camHeading()
    local okc, cx, cy = pcall(getActiveCameraCoordinates)
    local oka, ax, ay = pcall(getActiveCameraPointAt)
    if not (okc and oka and cx and ax) then return nil end
    local dx, dy = ax - cx, ay - cy
    if dx * dx + dy * dy < 1e-4 then return nil end
    return math.deg(math.atan2(-dx, dy)) % 360
end

-- spacja trzymana przez caly sprint (puszcza ja apHalt)
local function sprintKey(on)
    if on and not AP.keyUp then
        keyEvent(0x20, false, false)
        AP.keyUp = { vk = 0x20 }
    elseif not on and AP.keyUp then
        keyEvent(AP.keyUp.vk, AP.keyUp.ext, true)
        AP.keyUp = nil
    end
end

-- ruch: wirtualna galka (setGameKeyState 0/1) wzgledem kamery + sprint (spacja i CROSS pada), co klatke.
-- Zapas, gdy pad nie rusza postaci: taskGoStraightToCoord (task gry nie sprintuje lokalnej postaci).
local function apGo(wp, now, px, py)
    local fin = AP.path[#AP.path]
    local df = nsqrt((fin.x - px) ^ 2 + (fin.y - py) ^ 2)
    if AP.useTask then
        if AP.taskWp ~= wp or now >= (AP.taskAt or 0) then
            AP.taskAt, AP.taskWp = now + 1.0, wp
            if pcall(taskGoStraightToCoord, PLAYER_PED, wp.x, wp.y, wp.z, C.sprint and 7 or 6, 3000) then AP.tasked = true end
        end
        return
    end
    local ch = camHeading()
    if not ch then return end
    local rel = math.rad((headingTo(px, py, wp.x, wp.y) - ch + 540) % 360 - 180)
    local mag = df < 1.5 and 70 or 128                 -- ostatnie 1.5 m spokojnie, zeby nie przestrzelic
    pcall(setGameKeyState, 0, floor(-math.sin(rel) * mag + 0.5))
    pcall(setGameKeyState, 1, floor(-math.cos(rel) * mag + 0.5))
    local sprint = C.sprint and df > 3.5
    if sprint then pcall(setGameKeyState, 16, 255) end
    sprintKey(sprint)
end

-- zablokowany? (w ciagu 1.2 s mniej niz 0.8 m)
local function apStuck(now, px, py)
    if not AP.lp then AP.lp, AP.lpAt = { px, py }, now; return false end
    if now - AP.lpAt < 1.2 then return false end
    local moved = (px - AP.lp[1]) ^ 2 + (py - AP.lp[2]) ^ 2
    AP.lp, AP.lpAt = { px, py }, now
    if moved > 0.64 then AP.moved, AP.everMoved = true, true; return false end
    return true
end

local function apReplan(now, px, py, pz)
    local d = AP.dest
    apHalt()
    AP.lp, AP.path, AP.wi = nil, nil, 1
    AP.nav = navStart(px, py, pz, d.x, d.y, d.z, d.goalR, d.rock, now)
end

local function apUnstick(now, px, py, pz, wp)
    AP.stucks = AP.stucks + 1
    if not AP.useTask and not AP.everMoved and AP.stucks >= 2 then
        AP.useTask = true
        apHalt()
        log('auto: galka pada nie rusza postaci - przechodze na taskGoStraightToCoord (bez sprintu)')
        return
    end
    local dx, dy = wp.x - px, wp.y - py
    local l = nsqrt(dx * dx + dy * dy)
    if l > 0.1 then
        NAV.blocks[#NAV.blocks + 1] = { x = px + dx / l * 0.9, y = py + dy / l * 0.9, r = 0.7, untilT = now + 45 }
    end
    keyEvent(0xA0, false, false)                    -- skok (LShift)
    held = { vk = 0xA0, frames = 2, untilT = now + 0.1 }
    log(string.format('auto: zablokowany (%d) - skok, blokada przed postacia, nowa trasa', AP.stucks))
    if AP.dest then apReplan(now, px, py, pz) end
end

-- jawna sciezka bez planowania (podejscie do skaly, ponowka przy punkcie sprzedazy); AP.dest zostaje
local function apTarget(path, state, now)
    path[#path].final = true
    AP.path, AP.wi, AP.state, AP.nav = path, 1, state, nil
    AP.stucks, AP.lp, AP.moved, AP.at = 0, nil, false, now
end

-- reach: odleglosc od celu, przy ktorej uznajemy, ze doszlismy
local function apGoto(state, x, y, z, goalR, rock, reach, now, px, py, pz)
    apHalt()
    AP.dest = { x = x, y = y, z = z, goalR = goalR, rock = rock, reach = reach }
    AP.state, AP.at, AP.stucks, AP.lp, AP.moved = state, now, 0, nil, false
    AP.path, AP.wi = nil, 1
    AP.nav = navStart(px, py, pz, x, y, z, goalR, rock, now)
end

local function apFinish(msg)
    A.say('Gornik', msg, '33FF66')
    log('auto: ' .. msg)
    stop()
end

-- Miejsca do kopania wokol skaly: 12 kierunkow, promien z zewnatrz na wysokosci postaci trafia w skale,
-- stajemy 0.55 m przed jej powierzchnia. Kolejnosc: najblizej srodka skaly (od boku dlugiej skaly serwer
-- nie lapie zasiegu), potem najblizej postaci. nil = kolizja skaly jeszcze niewczytana.
local SLOT_N, SLOT_OUT, SLOT_GAP, SLOT_MAX = 12, 5.0, 0.55, 3.4

local function rockSlots(t, px, py)
    local out, hits = {}, 0
    for i = 0, SLOT_N - 1 do
        local a = i * 2 * math.pi / SLOT_N
        local ux, uy = math.cos(a), math.sin(a)
        local ox, oy = t.x + ux * SLOT_OUT, t.y + uy * SLOT_OUT
        local cg = navRay(ox, oy, t.z + 2.0, ox, oy, t.z - 5.0)
        if cg and cg.normal[3] >= 0.55 then
            local g = cg.pos[3]
            local z = g + NAV.H_MID
            local hit = navRay(ox, oy, z, t.x, t.y, z)
            if hit then
                hits = hits + 1
                local hx, hy = hit.pos[1], hit.pos[2]
                local hd = nsqrt((hx - t.x) ^ 2 + (hy - t.y) ^ 2)
                local isRock = hd < 1.5
                if not isRock and hit.entity and hit.entity ~= 0 then
                    local okE, ex, ey = pcall(entityPos, hit.entity)
                    isRock = okE and ex ~= nil and (ex - t.x) ^ 2 + (ey - t.y) ^ 2 < 4
                end
                local sd = hd + SLOT_GAP
                if isRock and sd <= SLOT_MAX then
                    local sx, sy = t.x + ux * sd, t.y + uy * sd
                    local gs = navGround(sx, sy, g)
                    if gs then
                        out[#out + 1] = { x = sx, y = sy, z = gs + 1.0, d = sd,
                            score = sd * 3 + nsqrt((sx - px) ^ 2 + (sy - py) ^ 2) * 0.15 }
                    end
                end
            end
        end
    end
    if hits == 0 then return nil end
    table.sort(out, function(p, q) return p.score < q.score end)
    return out
end

-- idz na nastepne niesprawdzone miejsce przy skale; false = brak (niewczytana kolizja albo wszystkie sprawdzone)
local function apApproach(now, px, py, pz)
    local t = AP.target
    if not AP.slots then
        AP.slots = rockSlots(t, px, py)
        if not AP.slots then return false end
        log(string.format('auto: %s - %d miejsc do kopania wokol skaly', t.name, #AP.slots))
    end
    for _, s in ipairs(AP.slots) do
        local used = false
        for _, u in ipairs(AP.slotTried) do
            if (u.x - s.x) ^ 2 + (u.y - s.y) ^ 2 < 1.0 then used = true; break end
        end
        if not used then
            AP.slotTried[#AP.slotTried + 1] = s
            apGoto('walk', s.x, s.y, s.z, 0.7, false, 0.55, now, px, py, pz)
            AP.dest.slot = s
            log(string.format('auto: podchodze do %s, miejsce %d/%d (%.1f m od srodka)', t.name, #AP.slotTried, #AP.slots, s.d))
            return true
        end
    end
    return false
end

-- bez miejsc wokol skaly: po staremu, prosto do srodka skaly
local function apRock(now, px, py, pz)
    local t = AP.target
    apGoto('walk', t.x, t.y, t.z, NAV.GOAL_R, true, AP.close, now, px, py, pz)
end

local function apSkip(why)
    AP.skip[spotKey(AP.target)] = true
    log('auto: ' .. AP.target.name .. ' - ' .. why .. ' - pomijam')
    AP.state = 'pick'
end

local function apPick(now, px, py, pz)
    apHalt()
    local best, bd
    for _, s in ipairs(ore.spots) do
        if s.src == 'label' and not oreHidden(s) and not AP.skip[spotKey(s)] then
            local d = (s.x - px) ^ 2 + (s.y - py) ^ 2 + ((s.z - pz) * 3) ^ 2
            if not bd or d < bd then best, bd = s, d end
        end
    end
    if best then
        AP.target, AP.tries, AP.close, AP.emptySince = best, 0, 1.6, nil
        AP.slots, AP.slotTried = nil, {}
        log(string.format('auto: ide do %s (%.0f m)', best.name, nsqrt(bd)))
        local far = (best.x - px) ^ 2 + (best.y - py) ^ 2 > 40 * 40
        if far or not apApproach(now, px, py, pz) then apRock(now, px, py, pz) end
        return
    end
    AP.emptySince = AP.emptySince or now
    if now - AP.emptySince < 3 then return end           -- etykiety moga jeszcze dochodzic
    -- przed sprzedaza: kazde znane miejsce rudy poza zasiegiem etykiet, ktorego dawno nie widzielismy
    local p = orePointToCheck(px, py, now)
    if p then
        AP.explore = p
        apGoto('explore', p.x, p.y, p.z, 4, false, 8, now, px, py, pz)
        log(string.format('auto: sprawdzam miejsce rudy %.0f m dalej', nsqrt((p.x - px) ^ 2 + (p.y - py) ^ 2)))
        return
    end
    if next(AP.skip) and not AP.retried then              -- pominiete skaly: jeszcze jedno podejscie
        AP.skip, AP.retried, AP.emptySince = {}, true, nil
        log('auto: wracam do pominietych skal')
        return
    end
    if C.autoSell and ore.sellPos then
        local sp = ore.sellPos
        AP.sellTries = 0
        apGoto('tosell', sp.x, sp.y, sp.z, 1.2, false, 0.8, now, px, py, pz)
        log('auto: brak rud - ide sprzedac mineraly')
        return
    end
    return apFinish(C.autoSell and 'Brak rud. Punkt sprzedazy nieznany - podejdz do niego raz, zeby go zapamietac.'
        or 'Wszystkie dostepne rudy wykopane.')
end

local function apWalk(now, px, py, pz)
    local selling = AP.state == 'tosell'
    local exploring = AP.state == 'explore'
    if exploring then                                     -- po drodze pojawila sie ruda: od razu po nia
        for _, s in ipairs(ore.spots) do
            if s.src == 'label' and not oreHidden(s) and not AP.skip[spotKey(s)] then
                apHalt()
                AP.nav, AP.state = nil, 'pick'
                return
            end
        end
    elseif not selling then
        local alive, k = false, spotKey(AP.target)
        for _, s in ipairs(ore.spots) do if spotKey(s) == k then alive = true; break end end
        if not alive then apHalt(); AP.nav, AP.state = nil, 'pick'; return end   -- wykopana / "juz wydobyles" / zniknela
    end
    local dest = AP.dest
    if not dest then AP.state = 'pick'; return end

    if AP.nav then                                    -- planowanie trwa: stoimy
        apHalt()
        S.why = 'trasa'
        local res = navRun(AP.nav, now)
        if res == 'run' then return end
        local nav = AP.nav
        AP.nav = nil
        if res == 'fail' and exploring then
            AP.explore.bad, AP.state = now + 300, 'pick'
            log('auto: brak drogi do miejsca rudy - pomijam na 5 min')
            return
        end
        if res == 'fail' then
            log(string.format('auto: brak drogi do %s (%d wezlow)', selling and 'punktu sprzedazy' or AP.target.name, nav.exp))
            if selling then return apFinish('Nie znalazlem drogi do punktu sprzedazy - sprzedaj recznie.') end
            if dest.slot and apApproach(now, px, py, pz) then return end      -- to miejsce nieosiagalne, nastepne
            return apSkip('brak drogi')
        end
        res[#res + 1] = { x = dest.x, y = dest.y, z = dest.z, final = true }
        AP.path, AP.wi, AP.lookAt, AP.lp = res, 1, 0, nil
        log(string.format('auto: trasa %d pkt%s, %d wezlow, %.0f ms', #res, nav.direct and ' (prosto)' or '',
            nav.exp, (A.now() - nav.t0) * 1000))
    end
    if not AP.path then AP.state = 'pick'; return end
    if AP.wi > #AP.path then AP.wi = #AP.path end

    local dt2 = (dest.x - px) ^ 2 + (dest.y - py) ^ 2
    -- szlismy prosto do skaly (kolizja byla daleko niewczytana): z bliska wybierz miejsce wokol niej
    if dest.rock and AP.slots == nil and dt2 < 64 and apApproach(now, px, py, pz) then return end
    if dt2 < dest.reach * dest.reach and (not selling or AP.path[AP.wi].final) then
        apHalt()
        if exploring then AP.state = 'pick'; return end
        AP.state, AP.at = selling and 'atsell' or 'face', now
        return
    end
    -- skroty: najdalszy z kolejnych 6 punktow (bez celu), do ktorego jest czysta prosta
    if now >= (AP.lookAt or 0) and AP.wi < #AP.path - 1 then
        AP.lookAt = now + 0.25
        local gz = navFeet(px, py, pz)
        for k = nmin(#AP.path - 1, AP.wi + 6), AP.wi + 1, -1 do
            local w = AP.path[k]
            if navCorridor(px, py, gz, w.x, w.y, now) then AP.wi = k; break end
        end
    end
    local wp = AP.path[AP.wi]
    if not wp.final and (wp.x - px) ^ 2 + (wp.y - py) ^ 2 < 1.0 then AP.wi = AP.wi + 1; return end
    apGo(wp, now, px, py)
    if not apStuck(now, px, py) then return end
    if not selling and not exploring and ((dest.slot and dt2 < 1.44) or (dest.rock and dt2 < 9)) then
        apHalt()
        AP.state, AP.at = 'face', now
        return
    end
    if AP.stucks >= 6 then
        apHalt()
        if exploring then AP.explore.bad, AP.state = now + 300, 'pick'; return end
        if selling then return apFinish('Nie moge dojsc do punktu sprzedazy - sprzedaj recznie.') end
        if dest.slot and apApproach(now, px, py, pz) then return end
        return apSkip('nie moge dojsc')
    end
    apUnstick(now, px, py, pz, wp)
end

local function apStep(now)
    if not isPlayerPlaying(PLAYER_HANDLE) then return end
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    S.why = 'auto'
    markChecked(px, py, now)
    local st = AP.state
    if st == 'pick' then return apPick(now, px, py, pz) end
    if st == 'walk' or st == 'tosell' or st == 'explore' then return apWalk(now, px, py, pz) end
    if st == 'face' then
        local t = AP.target
        pcall(setCharHeading, PLAYER_PED, headingTo(px, py, t.x, t.y))
        if now - AP.at < 0.3 + math.random() * 0.2 then return end
        local vk, ext = toVk(t.startKey or 'Y')
        if type(vk) ~= 'number' then vk, ext = 0x59, false end
        keyEvent(vk, ext, false)
        held = { vk = vk, ext = ext, frames = HOLD_FRAMES, untilT = now + 0.09 + math.random() * 0.05 }
        AP.state, AP.at, AP.tries = 'wait', now, AP.tries + 1
        S.startAt = now
        return
    end
    if st == 'wait' then
        if now - AP.at < 2.5 then return end                  -- czekamy na komunikat "Aby kopac, nacisnij ..."
        if AP.tries >= 4 then return apSkip('nie startuje (4 proby)') end
        -- z tego miejsca nie zaczyna (np. od boku): nastepne miejsce wokol skaly
        if apApproach(now, px, py, pz) then return end
        if AP.slots and #AP.slotTried > 0 then return apSkip('nie startuje z zadnej strony') end
        local t = AP.target                                    -- bez miejsc wokol skaly: blizej srodka
        AP.close = AP.close * 0.6
        AP.dest = { x = t.x, y = t.y, z = t.z, goalR = NAV.GOAL_R, rock = true, reach = AP.close }
        apTarget({ { x = t.x, y = t.y, z = t.z } }, 'walk', now)
        return
    end
    if st == 'atsell' then
        if now - AP.at > 4 then                               -- okno sie nie pokazalo: wyjdz i wejdz jeszcze raz
            AP.sellTries = (AP.sellTries or 0) + 1
            if AP.sellTries > 3 then return apFinish('Punkt sprzedazy nie otworzyl okna - sprzedaj recznie.') end
            local sp = ore.sellPos
            apTarget({ { x = sp.x + 2.5, y = sp.y, z = sp.z }, { x = sp.x, y = sp.y, z = sp.z } }, 'tosell', now)
        end
        return
    end
    if st == 'selling' and now - AP.at > 1.5 then
        return apFinish('Wszystkie rudy wykopane, mineraly sprzedane.')
    end
end
-- okno "Sprzedaj swoje mineraly": wybiera "Sprzedaj wszystkie mineraly" (pozycja 2), potem potwierdzenia
local function apDialog(now)
    apHalt()
    local okc, cap = pcall(sampGetDialogCaption)
    local fc = okc and fold(tostring(cap)) or ''
    if not (fc:find('minera', 1, true) or fc:find('sprzeda', 1, true)) then return end   -- inny dialog: czekamy
    if now < (AP.dlgAt or 0) then return end
    AP.dlgAt = now + 0.5 + math.random() * 0.3
    AP.dlgN = (AP.dlgN or 0) + 1
    local okS, style = pcall(sampGetCurrentDialogType)
    style = okS and style or 2
    if AP.dlgN == 1 then
        local item, i = 1, 0
        local okt, txt = pcall(sampGetDialogText)
        if okt and type(txt) == 'string' then
            for line in (txt .. '\n'):gmatch('([^\n]*)\n') do
                if fold(line):find('wszystkie', 1, true) then item = i - (style == 5 and 1 or 0); break end
                i = i + 1
            end
        end
        pcall(sampSetCurrentDialogListItem, math.max(0, item))
        pcall(sampCloseCurrentDialogWithButton, 1)
        log('sprzedaz: "Sprzedaj wszystkie mineraly" (pozycja ' .. item .. ')')
    elseif AP.dlgN <= 3 and style ~= 2 and style ~= 4 and style ~= 5 then
        pcall(sampCloseCurrentDialogWithButton, 1)                 -- potwierdzenie / informacja
    else
        pcall(sampCloseCurrentDialogWithButton, 0)                 -- znowu menu: zamknij
    end
    AP.state, AP.at = 'selling', now
end

-- reczne kopanie (bot wylaczony): po wydobyciu tez chowamy skale
local MW = { seen = nil, check = 0 }
local function manualWatch(now)
    if on then MW.seen = nil; return end
    if pick(now) then MW.seen = now; return end
    if MW.seen and now - MW.seen > 0.4 and now >= MW.check then
        MW.check = now + 0.25
        local ok, done = pcall(scanMessages)
        if ok and done then
            local px, py = getCharCoordinates(PLAYER_PED)
            markMined(nearestLabel(px, py, 5), now)
            MW.seen = nil
        elseif now - MW.seen > 3 then
            MW.seen = nil
        end
    end
end

-- "Nie udalo sie wydobyc mineralu! Sprobuj ponownie." - kopiemy jeszcze raz te sama rude.
-- Komunikat przed uznaniem rudy za wykopana: zalatwia to step() (S.failAt).
-- Komunikat po (bot juz ja oznaczyl i ruszyl dalej): cofamy oznaczenie i wracamy do niej.
local FAIL_MAX = 5

local function mineFailed(now)
    if S and S.active then
        S.failAt, S.doneChat = now, true
        return
    end
    local lm = lastMined
    if not (lm and now - lm.at < 6) then return end
    lastMined = nil
    unmarkMined(lm.s)
    if not (on and S) then
        if S then S.ores = math.max(0, S.ores - 1) end
        return
    end
    S.ores = math.max(0, S.ores - 1)
    if not AP then return end
    local k = spotKey(lm.s)
    AP.fails = AP.fails or {}
    AP.fails[k] = (AP.fails[k] or 0) + 1
    if AP.fails[k] > FAIL_MAX then
        log('auto: ' .. tostring(lm.s.name) .. ' - ' .. FAIL_MAX .. ' razy "nie udalo sie" - odpuszczam')
        AP.skip[k] = true
        return
    end
    log(string.format('serwer: nie udalo sie wydobyc %s - wracam do tej rudy (%d/%d)', tostring(lm.s.name), AP.fails[k], FAIL_MAX))
    apHalt()
    AP.nav, AP.target, AP.tries, AP.close = nil, lm.s, 0, 1.6
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    if (lm.s.x - px) ^ 2 + (lm.s.y - py) ^ 2 < 9 then
        AP.state, AP.at = 'face', now + 0.4 + math.random() * 0.5
    else
        AP.slots, AP.slotTried = nil, {}
        if not apApproach(now, px, py, pz) then apRock(now, px, py, pz) end
    end
end

local function step(now)
    if toggleReq then
        toggleReq = false
        if on then return stop() end
        if type(sampTextdrawIsExists) ~= 'function' then return end
        S, on = newState(now), true
        if C.auto then
            AP = { state = 'pick', skip = {}, camOff = -90, stucks = 0, tries = 0, at = now }
            A.minerAuto = true
            log('pelny automat: szukam rud' .. (C.autoSell and ', na koncu sprzedaz' or ''))
        end
        log(string.format('start (minimum %d ms, srednio %d ms, rozrzut %d ms, zapas %d ms)', C.minMs, C.avgMs, C.spreadMs,
            floor(adapt * 1000 + 0.5)))
        return
    end
    if not on then return end

    -- zwolnienie wcisnietego klawisza
    if held then
        held.frames = held.frames - 1
        if held.frames <= 0 and now >= held.untilT then
            release()
            S.cool = 1                                  -- jedna klatka przerwy przed kolejnym wcisnieciem
        end
        return
    end
    if S.cool > 0 then S.cool = S.cool - 1; return end

    -- okno sprzedazy mineralow obsluguje automat (inne dialogi = pauza)
    if AP and A.dialogActive() and not A.menuOpen then
        S.why = 'sprzedaz'
        local okD, errD = pcall(apDialog, now)
        if not okD then log('sprzedaz: ' .. tostring(errD)) end
        return
    end
    if blocked() then
        S.why, S.paused = 'pauza', true
        if AP then pcall(apHalt) end
        return
    end

    local e = pick(now)
    if e and AP and AP.state ~= 'mine' then                -- pojawil sie komunikat o klawiszu: kopiemy
        pcall(apHalt)
        if AP.state ~= 'wait' and AP.state ~= 'face' then
            local px, py = getCharCoordinates(PLAYER_PED)
            AP.target = nearestLabel(px, py, 5) or AP.target
        end
        AP.state = 'mine'
    end
    if not e and AP and not S.active then
        if AP.state == 'mine' then AP.state, AP.at = 'pick', now end   -- przerwane bez wydobycia: od nowa
        local okA, errA = pcall(apStep, now)
        if not okA then log('auto: ' .. tostring(errA)) end
        return
    end
    if not e then
        S.absent = S.absent or now
        if now - S.absent > 0.15 then A.miningBusy = false end
        local gone = now - S.absent
        if S.active and gone > 0.5 then                 -- komunikat zniknal: ruda wydobyta albo przerwa po bledzie
            local finished = S.doneChat
            if not finished and now >= S.nextMsg then
                S.nextMsg = now + 0.25
                local okM, done, wrong = pcall(scanMessages)
                if okM then
                    finished = done
                    if wrong then noteWrong(now, wrong) end
                end
            end
            if S.active and (finished or gone > 2.5) then
                S.active = false
                local failed = S.failAt ~= nil and now - S.failAt < 6
                S.failAt = nil
                local mined = S.presses > 0 and not failed
                if failed then
                    local t = AP and AP.target
                    local k = t and spotKey(t)
                    if k then
                        AP.fails = AP.fails or {}
                        AP.fails[k] = (AP.fails[k] or 0) + 1
                    end
                    if k and AP.fails[k] > FAIL_MAX then
                        log('auto: ' .. t.name .. ' - ' .. FAIL_MAX .. ' razy "nie udalo sie" - odpuszczam')
                        AP.skip[k] = true
                        AP.state, AP.at, AP.target = 'pick', now, nil
                    elseif t then
                        log(string.format('serwer: nie udalo sie wydobyc %s - kopie jeszcze raz (%d/%d)', t.name, AP.fails[k], FAIL_MAX))
                        AP.state, AP.at, AP.tries = 'face', now + 0.4 + math.random() * 0.5, 0
                    else
                        log('serwer: nie udalo sie wydobyc mineralu - nacisnij jeszcze raz przy tej samej rudzie')
                    end
                end
                if mined then
                    S.ores = S.ores + 1
                    adapt = math.max(0, adapt - 0.01)
                    log(string.format('ruda #%d (%d klawiszy, %s)', S.ores, S.presses, finished and 'komunikat' or 'przerwa'))
                    pcall(function()
                        local px, py = getCharCoordinates(PLAYER_PED)
                        markMined((AP and AP.target) or nearestLabel(px, py, 5), now)
                    end)
                end
                S.presses, S.lastKey, S.doneChat, S.plan, S.cutAt = 0, nil, false, nil, now
                if mined and AP then
                    AP.state, AP.at, AP.target = 'pick', now, nil
                elseif mined and C.autoOff then
                    return stop()
                end
            end
        end
        S.why = 'czeka'
        return
    end

    S.absent = nil
    S.active = true
    A.miningBusy = true
    S.why = 'kopie'
    if C.diag then pcall(diagNewTextdraws, now) end

    local name = e.key
    local vk, ext = toVk(name)
    if not vk then
        if not S.unknown[name] then
            S.unknown[name] = true
            log('nieznany klawisz w komunikacie: "' .. tostring(name) .. '"')
        end
        return
    end

    -- Jeden losowy czas na kazdy komunikat. Nowy klawisz: liczony od chwili, gdy komunikat sie zmienil.
    -- Ten sam klawisz pod rzad (tekst sie nie zmienia): od poprzedniego wcisniecia + opoznienie serwera.
    local same = name == S.lastKey and e.id == S.pressId and e.changedAt <= S.pressAt
    local planKey = same and ('s' .. S.pressAt) or (e.id .. ':' .. e.changedAt)
    if not S.plan or S.plan.k ~= planKey then
        local base = same and (S.pressAt + math.max(lat, getPing(now) / 1000)) or e.changedAt
        local d = humanDelay(S.presses == 0, same)
        local at = math.max(base + d, S.pressAt + C.minMs / 1000 + adapt)
        at = math.max(at, S.startAt + 0.25 + math.random() * 0.25)     -- po wlaczeniu bota tez chwila reakcji
        S.plan = { k = planKey, base = base, at = at }
        if C.diag then diagPrompt(e, at - base, now) end
    end
    if S.paused then                                    -- po pauzie (czat, menu...) czlowiek tez potrzebuje chwili
        S.paused = false
        S.plan.at = math.max(S.plan.at, now + 0.18 + math.random() * 0.22)
    end
    if now < S.plan.at then return end

    if S.presses == 0 then                              -- gdzie stoisz wzgledem najblizszej skaly (do szukania bledow "od boku")
        pcall(function()
            local px, py = getCharCoordinates(PLAYER_PED)
            local best, bd = nearestSpot(px, py)
            if best then
                local bearing = math.deg(math.atan2(-(best.x - px), best.y - py)) % 360
                local rel = (bearing - getCharHeading(PLAYER_PED) + 180) % 360 - 180
                log(string.format('start kopania: skala "%s" %.1f m, kat do skaly %+.0f deg od kierunku postaci', best.name, bd, rel))
            end
        end)
    end

    keyEvent(vk, ext, false)
    if vk == 'wheelup' or vk == 'wheeldown' then
        S.cool = 2
    else
        held = { vk = vk, ext = ext, frames = HOLD_FRAMES, untilT = now + 0.085 + math.random() * 0.06 }
    end
    local ms = floor((now - S.plan.base) * 1000 + 0.5)
    pushRecent(ms)
    S.lastDelay = ms
    S.lastKey, S.pressAt, S.pressId = name, now, e.id
    lastPress.id, lastPress.t = e.id, now
    S.hist[#S.hist + 1] = string.format('%s@%.2f(%dms)', tostring(name):upper(), now, ms)
    if #S.hist > 6 then table.remove(S.hist, 1) end
    S.presses = S.presses + 1
    if S.presses <= 12 or C.diag then
        log(string.format('wciskam %s po %d ms (td %d, ping %d)%s', tostring(name):upper(), ms, e.id, ping, same and ', ten sam klawisz' or ''))
    end
end

-- ------------------------------------------------------------ modul
function M.init()
    local t = A.loadJson(FILE)
    if t then
        if type(t.key) == 'number' and t.key > 0 then C.key = t.key end
        for _, k in ipairs({ 'hud', 'autoOff', 'learn', 'diag', 'useLearned', 'auto', 'autoSell', 'sprint' }) do
            if type(t[k]) == 'boolean' then C[k] = t[k] end
        end
        -- migracja: stare 'delayMs' (czas od komunikatu) -> minimum
        if type(t.minMs) == 'number' then C.minMs = A.clamp(floor(t.minMs), 300, 900)
        elseif type(t.delayMs) == 'number' and t.delayMs >= 300 then C.minMs = A.clamp(floor(t.delayMs), 300, 900) end
        if type(t.avgMs) == 'number' then C.avgMs = A.clamp(floor(t.avgMs), 400, 1200) end
        if type(t.spreadMs) == 'number' then C.spreadMs = A.clamp(floor(t.spreadMs), 0, 150) end
        if type(t.tempo) == 'table' and type(t.tempo.react) == 'table' then
            for _, v in ipairs(t.tempo.react) do
                if type(v) == 'number' and v > 0.1 and v < 2 then prof.react[#prof.react + 1] = v end
            end
        end
        if type(t.trust) == 'table' then
            for k, v in pairs(t.trust) do
                if type(k) == 'string' and type(v) == 'number' then trust[k] = A.clamp(v, -10, 30) end
            end
        end
    end
    if C.avgMs < C.minMs then C.avgMs = C.minMs + 60 end
    C.sprint, C.diag, C.learn, C.useLearned = true, false, false, false     -- usuniete z menu: na stale
    save()
    math.randomseed(os.time() + floor(os.clock() * 1000))
    font = renderCreateFont('Arial', 9, 5)
    oreLoad()
    A.onChat('gornik', function(lines)
        for _, l in ipairs(lines) do
            local f = fold(A.stripColors(l.text or ''))
            if f:find('nie uda', 1, true) and f:find('wydoby', 1, true) then
                local okF, errF = pcall(mineFailed, A.now())
                if not okF then log('porazka: ' .. tostring(errF)) end
            end
        end
        if not (on and S) then return end
        for _, l in ipairs(lines) do
            if C.diag and S.active then log('[diag] czat: ' .. A.stripColors(l.text or ''):sub(1, 120)) end
            local f = fold(A.stripColors(l.text or ''))
            if f:find('wydobycie zako', 1, true) then S.doneChat = true end
            if wrongText(f) then noteWrong(A.now(), 'czat') end
        end
    end)
    local lastErr
    local function run(tag, fn, now)
        local ok, err = pcall(fn, now)
        if not ok and err ~= lastErr then
            lastErr = err
            log(tag .. ': ' .. tostring(err))
        end
    end
    A.worker('gornik', function()
        wait(0)
        local now = A.now()
        run('komunikaty', track, now)
        run('rudy', scanLabels, now)
        run('rudy-obiekty', scanObjects, now)
        run('reczne', manualWatch, now)
        run('blad', step, now)
    end, 'gornik')
end

function M.onKey(vk)
    if vk == C.key and not A.chatInputActive() and not A.dialogActive() then toggleReq = true; return end
    if C.learn then learnPress(vk) end
end

function M.onWheel(dir)
    if C.learn then learnPress(dir > 0 and 'wheelup' or 'wheeldown') end
end

-- znaczniki 3D nad znanymi skalami + blipy na radarze
local oreBlips, nextBlips, fontOre = {}, 0, nil     -- klucz pozycji -> blip

local function toInt32(v)
    v = v % 0x100000000
    return v >= 0x80000000 and v - 0x100000000 or v
end

local function clearOreBlips()
    for k, b in pairs(oreBlips) do
        if doesBlipExist(b) then removeBlip(b) end
        oreBlips[k] = nil
    end
end

-- tylko roznice: znikniete skaly traca blip, nowe dostaja; reszta stoi (bez migania)
local function syncOreBlips(px, py)
    if not ore.C.radar or #ore.spots == 0 then return clearOreBlips() end
    local order = {}
    for _, s in ipairs(ore.spots) do order[#order + 1] = { s = s, d = (s.x - px) ^ 2 + (s.y - py) ^ 2 } end
    table.sort(order, function(a, b) return a.d < b.d end)
    local want = {}
    for n = 1, math.min(#order, 50) do want[spotKey(order[n].s)] = order[n].s end
    for k, b in pairs(oreBlips) do
        if not want[k] or not doesBlipExist(b) then
            if doesBlipExist(b) then removeBlip(b) end
            oreBlips[k] = nil
        end
    end
    for k, s in pairs(want) do
        if not oreBlips[k] then
            local ok, h = pcall(addBlipForCoord, s.x, s.y, s.z)
            if not ok or not h or not doesBlipExist(h) then break end
            changeBlipDisplay(h, 2)
            pcall(changeBlipColour, h, toInt32(oreInfo(s.name).rgb * 256 + 0xFF))
            oreBlips[k] = h
        end
    end
end

local radarState = { shown = false }

local function drawOreRadar(px, py)
    if not ore.C.radar then return end
    local inInt = curInterior() ~= 0
    if not inInt and not A.menuOpen then return end          -- poza interiorem dziala zwykly radar gry
    fontOre = fontOre or renderCreateFont('Arial', 8, 5)
    local R, range = 80, 80
    local x, y = A.hudPlace('rudy', 2 * R + 6, 2 * R + 6, 0.80, 0.52)
    local cx, cy = x + R + 3, y + R + 3
    if renderDrawPolygon then
        pcall(renderDrawPolygon, cx, cy, R + 2, 40, 0, 0xB0000000)
        pcall(renderDrawPolygon, cx, cy, R, 40, 0, 0x90101018)
    else
        renderDrawBox(x, y, 2 * R + 6, 2 * R + 6, 0x90101018)
    end
    local okc, ccx, ccy = pcall(getActiveCameraCoordinates)
    local oka, ax, ay = pcall(getActiveCameraPointAt)
    local fx, fy = 0, 1
    if okc and oka and ccx and ax then
        local dx, dy = ax - ccx, ay - ccy
        local l = math.sqrt(dx * dx + dy * dy)
        if l > 0.01 then fx, fy = dx / l, dy / l end
    end
    local rx, ry = fy, -fx                                        -- "prawo" na minimapie, gora = kierunek kamery
    local scale = R / range
    local near = {}
    for _, s in ipairs(ore.spots) do
        if not oreHidden(s) then
            local dx, dy = s.x - px, s.y - py
            local sx, sy = (dx * rx + dy * ry) * scale, -(dx * fx + dy * fy) * scale
            local d = math.sqrt(sx * sx + sy * sy)
            local edge = d > R - 4
            if edge then sx, sy = sx / d * (R - 4), sy / d * (R - 4) end
            local rgb = oreInfo(s.name).rgb
            renderDrawBox(cx + sx - 2, cy + sy - 2, 4, 4, (edge and 0x80000000 or 0xFF000000) + rgb)
            near[#near + 1] = { s = s, sx = sx, sy = sy, d = math.sqrt(dx * dx + dy * dy), rgb = rgb }
        end
    end
    renderDrawBox(cx - 2, cy - 2, 4, 4, 0xFFFFFFFF)               -- Ty
    table.sort(near, function(a, b) return a.d < b.d end)
    for i = 1, math.min(3, #near) do                              -- podpisy 3 najblizszych
        local e = near[i]
        renderFontDrawText(fontOre, string.format('%s %dm', e.s.name, math.floor(e.d + 0.5)), cx + e.sx + 5, cy + e.sy - 6, 0xFF000000 + e.rgb)
    end
end

local function drawOres(px, py, pz)
    if not ore.C.markers then return end
    fontOre = fontOre or renderCreateFont('Arial', 8, 5)
    for _, s in ipairs(ore.spots) do
        local dx, dy, dz = s.x - px, s.y - py, s.z - pz
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        local mz = s.z + (s.src == 'label' and 0.4 or 1.2)     -- etykieta wisi juz nad skala
        if d < 600 and isPointOnScreen(s.x, s.y, mz, 1.0) then
            local sx, sy = convert3DCoordsToScreen(s.x, s.y, mz)
            if sx then
                local rgb = oreInfo(s.name).rgb
                local a = s.src == 'label' and 0xFF000000 or 0xA0000000
                local label = string.format('%s  %dm', s.name, floor(d + 0.5)) .. (s.wear and ('  ' .. s.wear .. '%') or '')
                local w = renderGetFontDrawTextLength(fontOre, label)
                renderDrawBox(sx - 3, sy - 3, 6, 6, a + rgb)
                renderDrawBox(sx - w / 2 - 3, sy + 5, w + 6, 14, 0x80000000)
                renderFontDrawText(fontOre, label, sx - w / 2, sy + 6, a + rgb)
            end
        end
    end
end

local nextCfgSave = 0

function M.frame(now)
    if isPlayerPlaying(PLAYER_HANDLE) then
        local px, py, pz = getCharCoordinates(PLAYER_PED)
        if A.drawOk then
            if C.diag then pcall(drawNav) end
            if #ore.spots > 0 then
                local okD, errD = pcall(drawOres, px, py, pz)
                if not okD and errD ~= radarState.err then radarState.err = errD; log('markery: ' .. tostring(errD)) end
            end
            local okR, errR = pcall(drawOreRadar, px, py)
            if not okR and errR ~= radarState.err2 then radarState.err2 = errR; log('minimapa: ' .. tostring(errR)) end
        end
        if now >= nextBlips or ore.blipsDirty then
            nextBlips, ore.blipsDirty = now + 1, false
            pcall(syncOreBlips, px, py)
        end
    end
    if cfgDirty and now >= nextCfgSave then
        nextCfgSave = now + 10
        save()
    end
    if ore.dirty and now >= ore.nextSave then
        ore.nextSave = now + 30
        oreSave()
    end
    if not C.hud or not A.drawOk or not font or not (on or A.menuOpen) then return end
    local txt = 'Gornik'
    if on and S and S.lastDelay then txt = string.format('Gornik  %d ms', S.lastDelay) end
    local w = renderGetFontDrawTextLength(font, txt)
    local x, y = A.hudPlace('gornik', w + 14, 18, 0.47, 0.10)
    renderDrawBox(x, y, w + 14, 18, 0x90000000)
    renderDrawBox(x, y, 3, 18, not on and 0xFF666666 or (S and S.why == 'kopie' and 0xFF33FF66 or 0xFFFFD24A))
    renderFontDrawText(font, txt, x + 8, y + 2, 0xFFFFFFFF)
end

function M.disable()
    if on then stop() end
    clearOreBlips()
end

function M.terminate(quit)
    release()
    A.miningBusy = false
    if cfgDirty then pcall(save) end
    if ore.dirty then pcall(oreSave) end
    if not quit then clearOreBlips() end
end

function M.menuGroup()
    local ui = A.ui
    ui.keyButton('Klawisz', function() return C.key end, function(vk) C.key = vk; save() end,
        'Stoisz przy skale, naciskasz klawisz - bot sam wciska pokazywane klawisze (takze kolko myszy), az ruda zostanie wydobyta.')
    ui.sliderInt('Minimum', function() return C.minMs end, function(v)
        C.minMs = v
        if C.avgMs < v then C.avgMs = v + 60 end
        save()
    end, 300, 900, '%d ms',
        'Bot nigdy nie wcisnie klawisza szybciej niz tyle od jego pojawienia sie. Ponizej ok. 500 ms serwer przerywa kopanie ("niewlasciwy klawisz").')
    ui.sliderInt('Srednio', function() return C.avgMs end, function(v) C.avgMs = math.max(v, C.minMs); save() end, 400, 1200, '%d ms',
        'Typowy czas reakcji. Bot losuje wokol niego: raz troche szybciej, raz wolniej, czasem dluzsze zawahanie - ale nigdy ponizej minimum.')
    ui.sliderInt('Rozrzut', function() return C.spreadMs end, function(v) C.spreadMs = v; save() end, 0, 150, '%d ms',
        'Jak bardzo czasy sie roznia. 0 = zawsze tak samo (jak bot), 40-60 = naturalnie.')
    if #recent > 0 then
        local mn, mx, sum = 1e9, 0, 0
        for _, v in ipairs(recent) do mn, mx, sum = math.min(mn, v), math.max(mx, v), sum + v end
        ui.kv('Ostatnie (min/sr/max)', string.format('%d / %d / %d ms', mn, floor(sum / #recent + 0.5), mx))
    end
    if adapt > 0.001 then ui.kv('Zapas po bledach', '+' .. floor(adapt * 1000 + 0.5) .. ' ms', 0xFFFFD24A) end
    ui.check('HUD##gornik', function() return C.hud end, function(v) C.hud = v; save() end,
        'Maly znacznik na ekranie, gdy bot dziala (z ostatnim czasem reakcji).')
end

-- druga grupa: znaczniki rud
function M.oresGroup()
    local ui = A.ui
    ui.kv('Widoczne teraz', #ore.spots)
    if ore.C.objects then ui.kv('Etykiety / obiekty', #ore.labels .. ' / ' .. #ore.objs) end
    local function set(k) return function(v) ore.C[k] = v; ore.dirty = true; nextBlips = 0; rebuildSpots() end end
    ui.checks({
        { 'Znaczniki 3D', function() return ore.C.markers end, set('markers'),
          'Pokazuje skaly, ktore serwer TERAZ wysyla (etykieta "Ruda ... / Zuzycie"). Wykopana albo przeniesiona skala znika od razu.' },
        { 'Radar##ore', function() return ore.C.radar end, set('radar'),
          'Widoczne skaly jako kolorowe punkty na radarze (50 najblizszych), odswiezane co sekunde.' },
        { 'Szukaj po obiektach', function() return ore.C.objects end, set('objects'),
          'Dodatkowo szuka skal po modelu obiektu (uczy sie go z etykiet). Widac je z dalszej odleglosci, ale skala bez etykiety moze byc juz wykopana.' },
    }, 1)
    if ore.C.objects then
        local n = 0
        for m in pairs(ore.models) do if modelActive(m) then n = n + 1 end end
        ui.kv('Pewne modele skal', n)
        if ui.button('Zapomnij modele##oreclr', nil, 'Kasuje nauczone modele skal (gdy znaczniki z obiektow sa w zlych miejscach).') then
            ore.models, ore.bad, ore.taught, ore.objs = {}, {}, {}, {}
            rebuildSpots()
            ore.dirty, nextBlips = true, 0
        end
    end
end

return M
end)(A))

-- ============================================================================
-- MODUL: STATUETKI (dawny PickupDump) - statuetki (pickup model 1276) na radarze
-- Pickupy widac tylko w zasiegu streamingu serwera; kazda znaleziona jest zapisywana
-- w moonloader\\pickupy_dump.txt (ten sam format co PickupDump) i od tej chwili stale
-- na radarze (50 najblizszych).
-- ============================================================================
A.register((function(A)
local sqrt, min = math.sqrt, math.min

local M = { id = 'statuetki', title = 'Statuetki', hidden = true }
local MODEL, TOTAL = 1276, 100
local DUMP = A.WD .. '\\pickupy_dump.txt'
local FILE = A.DIR .. '\\statuetki.json'
local MAX_BLIPS = 50
local BLIP_COLOUR = -10354433   -- 0xFF6200FF (RGBA, pomaranczowy)

local C = { radar = true }
local known, keyset = {}, {}
local blips = {}

local function save() A.saveJson(FILE, { radar = C.radar }) end

local function addKnown(x, y, z)
    local key = string.format('%.0f:%.0f:%.0f', x, y, z)
    if keyset[key] then return false end
    keyset[key] = true
    known[#known + 1] = { x, y, z }
    return true
end

local function loadDump()
    local f = io.open(DUMP, 'r')
    if not f then return end
    for line in f:lines() do
        local model, x, y, z = line:match('model:(%-?%d+).-x:([%-%d%.]+) y:([%-%d%.]+) z:([%-%d%.]+)')
        if model and tonumber(model) == MODEL then addKnown(tonumber(x), tonumber(y), tonumber(z)) end
    end
    f:close()
end

local function getPool()
    local api = A.netgameApi
    if type(api) ~= 'table' or type(api.RefNetGame) ~= 'function' then return nil end
    local ok, pool = pcall(function()
        local ng = api.RefNetGame()
        if ng == nil then return nil end
        return ng:GetPickupPool()
    end)
    if ok and pool ~= nil then return pool end
    return nil
end

-- wspolna lista pickupow dla Finders (jeden przebieg puli na ~sekunde); nil = pula nieczytelna
function A.pickupList(now)
    if A._pk and now - A._pkAt < 0.9 then return A._pk end
    local pool = getPool()
    if not pool then return nil end
    local list = {}
    for i = 0, 4095 do
        local ok, handle = pcall(function() return pool.m_handle[i] end)
        if not ok then break end
        if handle ~= 0 then
            local ok2, e = pcall(function()
                local obj = pool.m_object[i]
                local p = obj.m_position
                return { slot = i, model = obj.m_nModel, typ = obj.m_nType, x = p.x + 0.0, y = p.y + 0.0, z = p.z + 0.0 }
            end)
            if ok2 then list[#list + 1] = e end
        end
    end
    A._pk, A._pkAt = list, now
    return list
end

local function scanPool(now)
    local list = A.pickupList(now)
    if not list then return end
    local fresh = {}
    for _, e in ipairs(list) do
        if e.model == MODEL and addKnown(e.x, e.y, e.z) then
            fresh[#fresh + 1] = string.format('slot:%d model:%d typ:%d x:%.3f y:%.3f z:%.3f', e.slot, MODEL, e.typ, e.x, e.y, e.z)
        end
    end
    if #fresh == 0 then return false end
    local f = io.open(DUMP, 'a')
    if f then
        f:write(table.concat(fresh, '\n') .. '\n')
        f:close()
    end
    A.say('Statuetki', ('Nowa statuetka! Masz %d/%d.'):format(#known, TOTAL), 'FFB347')
    return true
end

local function clearBlips()
    for i, b in pairs(blips) do
        if doesBlipExist(b) then removeBlip(b) end
        blips[i] = nil
    end
end

local function syncBlips(px, py)
    if not C.radar or getActiveInterior() ~= 0 then return clearBlips() end
    local order = {}
    for i, k in ipairs(known) do
        local dx, dy = k[1] - px, k[2] - py
        order[#order + 1] = { i = i, d = dx * dx + dy * dy }
    end
    table.sort(order, function(a, b) return a.d < b.d end)
    local want = {}
    for n = 1, min(#order, MAX_BLIPS) do want[order[n].i] = true end
    for i, b in pairs(blips) do
        if not want[i] or not doesBlipExist(b) then
            if doesBlipExist(b) then removeBlip(b) end
            blips[i] = nil
        end
    end
    for i in pairs(want) do
        if not blips[i] then
            local k = known[i]
            local ok, h = pcall(addBlipForCoord, k[1], k[2], k[3])
            if not ok or not h or not doesBlipExist(h) then break end
            changeBlipDisplay(h, 2)
            pcall(changeBlipColour, h, BLIP_COLOUR)
            blips[i] = h
        end
    end
end

local nextScan, nextBlips = 0, 0
local lastBX, lastBY = 1e9, 1e9

function M.init()
    local t = A.loadJson(FILE)
    if t and type(t.radar) == 'boolean' then C.radar = t.radar end
    save()
    loadDump()
    if A.sampapi then pcall(A.sampapi.require, 'CPickupPool') end
end

function M.frame(now)
    if not isPlayerPlaying(PLAYER_HANDLE) then return end
    local px, py = getCharCoordinates(PLAYER_PED)
    if now >= nextScan then
        nextScan = now + 1.0
        local ok, added = pcall(scanPool, now)
        if ok and added then nextBlips = 0 end
    end
    if now >= nextBlips or (px - lastBX) ^ 2 + (py - lastBY) ^ 2 > 200 * 200 then
        nextBlips, lastBX, lastBY = now + 10, px, py
        syncBlips(px, py)
    end
end

function M.disable() clearBlips() end

function M.terminate(quit)
    if not quit then clearBlips() end
end

function M.menuGroup()
    local ui = A.ui
    ui.kv('Znalezione', #known .. ' / ' .. TOTAL, #known >= TOTAL and 0xFF33FF66 or 0xFFFFB347)
    ui.check('Radar##stt', function() return C.radar end, function(v)
        C.radar = v
        save()
        nextBlips = 0
        if not v then clearBlips() end
    end, 'Znalezione statuetki jako punkty na radarze (50 najblizszych). Nowe zapisuja sie, gdy tylko je zobaczysz.')
end

return M
end)(A))

-- ============================================================================
-- MODUL: WALIZKI (Finders) - walizki (obiekt/pickup model 19624, case1) na radarze
-- Widac je tylko w zasiegu streamingu serwera. Kazda walizka zapisuje sie raz
-- (bez dubli, w moonloader\walizki_dump.txt) i stoi na radarze. Walizka jest
-- jednorazowa: gdy stoisz przy zapamietanym miejscu, a walizki juz tam nie ma
-- (podniesiona), znika z listy i z radaru.
-- ============================================================================
A.register((function(A)
local min = math.min

local M = { id = 'walizki', title = 'Walizki', hidden = true }
local MODEL = 19624            -- case1
local DUMP = A.WD .. '\\walizki_dump.txt'
local FILE = A.DIR .. '\\walizki.json'
local MAX_BLIPS = 40
-- W poblizu gracza serwer zawsze streamuje pickupy/obiekty, wiec brak walizki = podniesiona.
-- Blisko (15 m): 2 kolejne skany (~1 s); do 60 m: 4 skany (~2 s), zeby chwilowy brak streamingu jej nie usunal.
local NEAR_R2, FAR_R2 = 15 * 15, 60 * 60
local SAME_R2 = 4                 -- ta sama walizka (2 m)
local BLIP_RGB = 0x33CCFF

local C = { radar = true }
local known, blips = {}, {}
local dirty = false

local function save() A.saveJson(FILE, { radar = C.radar }) end

local function toInt32(v)
    v = v % 0x100000000
    return v >= 0x80000000 and v - 0x100000000 or v
end

local function nearKnown(x, y, z)
    for i, k in ipairs(known) do
        if (k.x - x) ^ 2 + (k.y - y) ^ 2 + (k.z - z) ^ 2 < SAME_R2 then return i end
    end
end

local function writeDump()
    local lines = {}
    for _, k in ipairs(known) do lines[#lines + 1] = string.format('model:%d x:%.3f y:%.3f z:%.3f', MODEL, k.x, k.y, k.z) end
    local f = io.open(DUMP, 'w')
    if f then
        f:write(table.concat(lines, '\n') .. (#lines > 0 and '\n' or ''))
        f:close()
    end
end

local function loadDump()
    local f = io.open(DUMP, 'r')
    if not f then return end
    for line in f:lines() do
        local model, x, y, z = line:match('model:(%-?%d+).-x:([%-%d%.]+) y:([%-%d%.]+) z:([%-%d%.]+)')
        if model and tonumber(model) == MODEL then
            x, y, z = tonumber(x), tonumber(y), tonumber(z)
            if not nearKnown(x, y, z) then known[#known + 1] = { x = x, y = y, z = z, missed = 0 } end
        end
    end
    f:close()
end

-- walizki widoczne teraz: pickupy z puli + (zapasowo) obiekty o tym modelu
local function visibleNow(now)
    local seen, readable = {}, false
    local list = A.pickupList(now)
    if list then
        readable = true
        for _, e in ipairs(list) do
            if e.model == MODEL then seen[#seen + 1] = { x = e.x, y = e.y, z = e.z } end
        end
    end
    if type(getAllObjects) == 'function' then
        local ok, objs = pcall(getAllObjects)
        if ok and type(objs) == 'table' then
            readable = true
            for _, obj in ipairs(objs) do
                if doesObjectExist(obj) and getObjectModel(obj) == MODEL then
                    local okc, _, x, y, z = pcall(getObjectCoordinates, obj)
                    if okc and x then seen[#seen + 1] = { x = x, y = y, z = z } end
                end
            end
        end
    end
    return readable and seen or nil
end

local function clearBlips()
    for i, b in pairs(blips) do
        if doesBlipExist(b) then removeBlip(b) end
        blips[i] = nil
    end
end

local function syncBlips(px, py)
    clearBlips()
    if not C.radar or getActiveInterior() ~= 0 then return end
    local order = {}
    for _, k in ipairs(known) do order[#order + 1] = { k = k, d = (k.x - px) ^ 2 + (k.y - py) ^ 2 } end
    table.sort(order, function(a, b) return a.d < b.d end)
    for n = 1, min(#order, MAX_BLIPS) do
        local k = order[n].k
        local ok, h = pcall(addBlipForCoord, k.x, k.y, k.z)
        if not ok or not h or not doesBlipExist(h) then break end
        changeBlipDisplay(h, 2)
        pcall(changeBlipColour, h, toInt32(BLIP_RGB * 256 + 0xFF))
        blips[n] = h
    end
end

local nextScan, nextBlips = 0, 0

function M.init()
    local t = A.loadJson(FILE)
    if t and type(t.radar) == 'boolean' then C.radar = t.radar end
    save()
    loadDump()
end

function M.frame(now)
    if not isPlayerPlaying(PLAYER_HANDLE) then return end
    local px, py, pz = getCharCoordinates(PLAYER_PED)
    if now >= nextScan then
        nextScan = now + 0.5
        local seen = visibleNow(now)
        if seen then
            for _, w in ipairs(seen) do
                if not nearKnown(w.x, w.y, w.z) then
                    known[#known + 1] = { x = w.x, y = w.y, z = w.z, missed = 0 }
                    dirty = true
                end
            end
            -- jednorazowa: przy zapamietanym miejscu nie ma juz walizki 3 skany z rzedu = podniesiona
            for i = #known, 1, -1 do
                local k = known[i]
                local d2 = (k.x - px) ^ 2 + (k.y - py) ^ 2
                if d2 < FAR_R2 then
                    local here = false
                    for _, w in ipairs(seen) do
                        if (w.x - k.x) ^ 2 + (w.y - k.y) ^ 2 + (w.z - k.z) ^ 2 < SAME_R2 then here = true; break end
                    end
                    k.missed = here and 0 or (k.missed or 0) + 1
                    if k.missed >= (d2 < NEAR_R2 and 2 or 4) then
                        table.remove(known, i)
                        dirty = true
                        A.log('walizki', string.format('walizka %.1f %.1f zniknela (podniesiona) - usuwam z radaru i z pliku', k.x, k.y))
                    end
                end
            end
            if dirty then
                dirty = false
                writeDump()
                nextBlips = 0
            end
        end
    end
    if now >= nextBlips then
        nextBlips = now + 4
        pcall(syncBlips, px, py)
    end
end

function M.disable() clearBlips() end

function M.terminate(quit)
    if not quit then clearBlips() end
end

function M.menuGroup()
    local ui = A.ui
    ui.kv('Znalezione', #known)
    ui.check('Radar##wlz', function() return C.radar end, function(v)
        C.radar = v
        save()
        nextBlips = 0
        if not v then clearBlips() end
    end, 'Walizki w zasiegu jako punkty na radarze. Kazda zapisuje sie raz, a po podniesieniu znika.')
end

return M
end)(A))

-- ============================================================================
-- MENU (mimgui) + UI helpery
-- ============================================================================
do
local floor = math.floor

local VK_NAMES = {
    [0x01] = 'LPM', [0x02] = 'PPM', [0x04] = 'SPM', [0x05] = 'Mysz4', [0x06] = 'Mysz5',
    [0x08] = 'Backspace', [0x09] = 'Tab', [0x0D] = 'Enter', [0x10] = 'Shift', [0x11] = 'Ctrl', [0x12] = 'Alt',
    [0x13] = 'Pause', [0x14] = 'CapsLock', [0x1B] = 'Esc', [0x20] = 'Spacja',
    [0x21] = 'PageUp', [0x22] = 'PageDown', [0x23] = 'End', [0x24] = 'Home',
    [0x25] = 'Lewo', [0x26] = 'Gora', [0x27] = 'Prawo', [0x28] = 'Dol',
    [0x2C] = 'PrintScreen', [0x2D] = 'Insert', [0x2E] = 'Delete', [0x5B] = 'Win', [0x5C] = 'Win', [0x5D] = 'Menu',
    [0x6A] = 'Num*', [0x6B] = 'Num+', [0x6D] = 'Num-', [0x6E] = 'Num.', [0x6F] = 'Num/',
    [0x90] = 'NumLock', [0x91] = 'ScrollLock', [0xA0] = 'LShift', [0xA1] = 'RShift', [0xA2] = 'LCtrl',
    [0xA3] = 'RCtrl', [0xA4] = 'LAlt', [0xA5] = 'RAlt',
    [0xBA] = ';', [0xBB] = '=', [0xBC] = ',', [0xBD] = '-', [0xBE] = '.', [0xBF] = '/', [0xC0] = '~',
    [0xDB] = '[', [0xDC] = '\\', [0xDD] = ']', [0xDE] = "'",
}
for i = 0, 9 do VK_NAMES[0x60 + i] = 'Num' .. i end

function A.keyName(vk)
    if not vk or vk == 0 then return 'brak' end
    if VK_NAMES[vk] then return VK_NAMES[vk] end
    if vk >= 0x70 and vk <= 0x87 then return 'F' .. (vk - 0x6F) end
    if (vk >= 0x30 and vk <= 0x39) or (vk >= 0x41 and vk <= 0x5A) then return string.char(vk) end
    return string.format('0x%02X', vk)
end

function A.comboName(vk, mods)
    if not vk or vk == 0 then return 'brak' end
    mods = mods or 0
    local p = ''
    if mods % 2 >= 1 then p = p .. 'Ctrl+' end
    if mods % 4 >= 2 then p = p .. 'Shift+' end
    if mods % 8 >= 4 then p = p .. 'Alt+' end
    return p .. A.keyName(vk)
end

function A.setMenu(v)
    A.menuOpen = v and A.imgui ~= nil
    if not A.menuOpen then
        A.hud.drag = nil
        A.keyCapture, A.keyCaptureId = nil, nil
        A.saveCore()
    end
end

local im = A.imgui
A.ui = {}
local ui = A.ui

if im then
    local bit = A.bit

    -- ------------------------------------------------------------ paleta
    local P = {
        accent  = { 0.66, 0.52, 1.00, 1 },
        accent2 = { 0.33, 0.58, 1.00, 1 },
        accent3 = { 0.96, 0.44, 0.78, 1 },
        bgTop   = { 0.105, 0.098, 0.140, 1 },
        bgBot   = { 0.052, 0.050, 0.070, 1 },
        side    = { 0.000, 0.000, 0.000, 0.28 },
        tabOn   = { 1.000, 1.000, 1.000, 0.05 },
        groupBg = { 0.120, 0.112, 0.160, 0.55 },
        border  = { 0.200, 0.188, 0.262, 1 },
        edge    = { 0.010, 0.010, 0.015, 1 },
        title   = { 0.900, 0.890, 0.950, 1 },
        tabOff  = { 0.520, 0.510, 0.580, 1 },
        tabHov  = { 0.780, 0.770, 0.850, 1 },
        white   = { 0.960, 0.955, 1.000, 1 },
        dim     = { 0.420, 0.410, 0.480, 1 },
    }

    local u32memo = {}                -- kolory palety sa stale: liczone raz, nie ~30 razy na klatke menu
    local function u32(c, a)
        if a == nil and u32memo[c] then return u32memo[c] end
        local r, g, b = floor(c[1] * 255), floor(c[2] * 255), floor(c[3] * 255)
        local v = floor((a or c[4]) * 255) * 16777216 + b * 65536 + g * 256 + r
        if a == nil then u32memo[c] = v end
        return v
    end

    local function V2(x, y) return im.ImVec2(x, y) end
    local function pct(s) return (tostring(s):gsub('%%', '%%%%')) end
    local function plain(label) return (tostring(label):gsub('##.*$', '')) end

    local vcache = {}
    local function vec4(argb)
        local v = vcache[argb]
        if not v then
            v = im.ImVec4(bit.band(bit.rshift(argb, 16), 0xFF) / 255, bit.band(bit.rshift(argb, 8), 0xFF) / 255,
                bit.band(argb, 0xFF) / 255, bit.band(bit.rshift(argb, 24), 0xFF) / 255)
            vcache[argb] = v
        end
        return v
    end

    local function lookup(name)
        local ok, f = pcall(function() return im[name] end)
        return ok and type(f) ~= 'nil' and f or nil
    end
    local hintFn = lookup('InputTextWithHint')
    local BTN_ON

    local function textW(s)
        local ok, v = pcall(function() return im.CalcTextSize(s).x end)
        return ok and v or #s * 7
    end

    -- ------------------------------------------------------------ podstawowe
    ui.W = 300       -- szerokosc wnetrza biezacej grupy

    function ui.text(s) im.Text(pct(s)) end
    function ui.textDim(s) im.TextDisabled(pct(s)) end
    function ui.textCol(argb, s) im.TextColored(vec4(argb), pct(s)) end
    function ui.sameText(s) im.SameLine(0, 0); im.TextDisabled(pct(s)) end

    function ui.wrap(s, argb)
        im.PushTextWrapPos(im.GetCursorPosX() + ui.W)
        if argb then im.TextColored(vec4(argb), pct(s)) else im.TextWrapped(pct(s)) end
        im.PopTextWrapPos()
    end

    -- etykieta po lewej, wartosc wyrownana do prawej
    function ui.kv(k, v, argb)
        v = tostring(v)
        ui.textDim(k)
        im.SameLine(10 + ui.W - textW(v))
        if argb then ui.textCol(argb, v) else ui.text(v) end
    end

    -- ------------------------------------------------------------ kontrolki
    local bools, ints, floats = {}, {}, {}

    -- podpowiedz po najechaniu na ostatni element: nakladka z tytulem i opisem
    local SV = lookup('StyleVar')
    local pushVec2 = lookup('PushStyleVarVec2') or lookup('PushStyleVar')
    local pushFloat = lookup('PushStyleVarFloat') or lookup('PushStyleVar')
    function ui.tip(title, text)
        if not text or not im.IsItemHovered() then return end
        local vars = 0
        if SV and pushVec2 and pushFloat then
            if pcall(pushVec2, SV.WindowPadding, V2(12, 9)) then vars = vars + 1 end
            if pcall(pushFloat, SV.WindowRounding, 7) then vars = vars + 1 end
            if pcall(pushFloat, SV.WindowBorderSize, 1) then vars = vars + 1 end
        end
        im.PushStyleColor(im.Col.Border, vec4(0xFF5A4690))
        im.PushStyleColor(im.Col.PopupBg, vec4(0xF2101018))
        im.BeginTooltip()
        im.TextColored(vec4(0xFFB48CFF), pct(title))
        im.Separator()
        im.PushTextWrapPos(300)
        im.TextWrapped(pct(text))
        im.PopTextWrapPos()
        im.EndTooltip()
        im.PopStyleColor(2)
        if vars > 0 then im.PopStyleVar(vars) end
    end

    function ui.check(label, get, set, tip)
        local b = bools[label]
        if not b then b = im.new.bool(false); bools[label] = b end
        b[0] = get() and true or false
        local ch = im.Checkbox(label, b)
        ui.tip(plain(label), tip)
        if ch then
            set(b[0])
            return true
        end
        return false
    end

    function ui.checks(list, cols)
        cols = cols or 1
        local colW = ui.W / cols
        for i, c in ipairs(list) do
            local col = (i - 1) % cols
            if col ~= 0 then im.SameLine(10 + col * colW) end
            ui.check(c[1], c[2], c[3], c[4])
        end
    end

    local function sliderRow(label)
        ui.textDim(plain(label))
        im.SameLine(10 + ui.W * 0.42)
        im.PushItemWidth(ui.W * 0.58)
    end

    function ui.sliderInt(label, get, set, lo, hi, fmt, tip)
        local v = ints[label]
        if not v then v = im.new.int(0); ints[label] = v end
        v[0] = math.floor(get() + 0.5)
        sliderRow(label)
        local ch = im.SliderInt('##si' .. label, v, lo, hi, fmt or '%d')
        ui.tip(plain(label), tip)
        im.PopItemWidth()
        if ch then set(v[0]) end
        return ch
    end

    function ui.sliderFloat(label, get, set, lo, hi, fmt, tip)
        local v = floats[label]
        if not v then v = im.new.float(0); floats[label] = v end
        v[0] = get()
        sliderRow(label)
        local ch = im.SliderFloat('##sf' .. label, v, lo, hi, fmt or '%.2f')
        ui.tip(plain(label), tip)
        im.PopItemWidth()
        if ch then set(v[0]) end
        return ch
    end

    function ui.button(label, w, tip)
        local r = im.Button(label, V2(w or ui.W, 0))
        ui.tip(plain(label), tip)
        return r
    end

    -- rzad przyciskow o rownej szerokosci: { {label, fn}, ... }
    function ui.buttons(list)
        local n = #list
        local sp = 6
        local w = (ui.W - sp * (n - 1)) / n
        for i, b in ipairs(list) do
            if i > 1 then im.SameLine(0, sp) end
            if im.Button(b[1], V2(w, 0)) then b[2]() end
            ui.tip(plain(b[1]), b[3])
        end
    end

    -- przelacznik segmentowy: zwraca indeks klikniety albo nil
    function ui.seg(id, labels, cur)
        local n = #labels
        local sp = 2
        local w = (ui.W - sp * (n - 1)) / n
        local hit
        for i, l in ipairs(labels) do
            if i > 1 then im.SameLine(0, sp) end
            local on = i == cur
            if on then im.PushStyleColor(im.Col.Button, BTN_ON) end
            if im.Button(l .. '##seg' .. id .. i, V2(w, 0)) then hit = i end
            if on then im.PopStyleColor() end
        end
        return hit
    end

    -- zgodnosc: maly przycisk-przelacznik
    function ui.radio(label, active)
        if active then im.PushStyleColor(im.Col.Button, BTN_ON) end
        local r = im.SmallButton(label)
        if active then im.PopStyleColor() end
        return r
    end

    function ui.inputHint(id, hint, buf, size, flags)
        if hintFn then return hintFn(id, hint, buf, size, flags or 0) end
        return im.InputText(id, buf, size, flags or 0)
    end

    -- pole na cala szerokosc grupy
    function ui.input(id, hint, buf, size, flags)
        im.PushItemWidth(ui.W)
        local r = ui.inputHint(id, hint, buf, size, flags)
        im.PopItemWidth()
        return r
    end

    -- klawisz: "Etykieta ....... [Insert]"; klik -> nastepny wcisniety klawisz (Esc = anuluj)
    function ui.keyButton(label, get, set, tip)
        local id = label
        local txt = (A.keyCaptureId == id) and '...' or A.keyName(get())
        ui.textDim(plain(label))
        im.SameLine(10 + ui.W * 0.42)
        if im.Button(txt .. '##key' .. id, V2(ui.W * 0.58, 0)) then
            A.keyCaptureId = id
            A.keyCapture = function(vk)
                A.keyCaptureId = nil
                if vk ~= 0x1B then set(vk) end
            end
        end
        ui.tip(plain(label), tip)
    end

    -- kombinacja klawiszy (np. Ctrl+Shift+End); klik -> nacisnij kombinacje, Esc = anuluj
    function ui.combo(label, vk, mods, set, clearable, tip)
        local id = label
        local has = vk and vk ~= 0
        local txt = (A.keyCaptureId == id) and 'nacisnij klawisze...' or A.comboName(vk, mods)
        ui.textDim(plain(label))
        im.SameLine(10 + ui.W * 0.42)
        local w = ui.W * 0.58
        if clearable and has then w = w - 28 end
        if im.Button(txt .. '##combo' .. id, V2(w, 0)) then
            A.keyCaptureId = id
            A.keyCapture = function(k, m)
                A.keyCaptureId = nil
                if k ~= 0x1B then set(k, m or 0) end
            end
        end
        ui.tip(plain(label), tip)
        if clearable and has then
            im.SameLine(0, 4)
            if im.Button('x##clr' .. id, V2(24, 0)) then set(0, 0) end
        end
    end

    function ui.typeInChat(text)
        A.setMenu(false)
        if type(sampSetChatInputEnabled) == 'function' and type(sampSetChatInputText) == 'function' then
            pcall(sampSetChatInputEnabled, true)
            pcall(sampSetChatInputText, text)
        end
    end

    -- ------------------------------------------------------------ uklad: kolumny i grupy
    local heights = {}
    ui.colW = nil

    function ui.cols(left, right)
        local total = im.GetWindowWidth() - 28
        local w = math.floor((total - 12) / 2)
        im.BeginGroup()
        ui.colW = w
        left()
        im.EndGroup()
        im.SameLine(0, 12)
        im.BeginGroup()
        ui.colW = w
        right()
        im.EndGroup()
        ui.colW = nil
    end

    -- ramka z tytulem; tlo rysowane z wysokosci z poprzedniej klatki
    function ui.group(title, fn)
        local W = ui.colW or (im.GetWindowWidth() - 28)
        local key = tostring(A.cfg.tab) .. title
        local p = im.GetCursorScreenPos()
        local dl = im.GetWindowDrawList()
        local h = heights[key]
        if h then pcall(function() dl:AddRectFilled(p, V2(p.x + W, p.y + h), u32(P.groupBg), 4) end) end

        local saveW = ui.W
        im.BeginGroup()
        im.Dummy(V2(W, 24))
        ui.W = W - 20
        im.Indent(10)
        local ok, err = pcall(fn)
        im.Unindent(10)
        im.Dummy(V2(W, 6))
        im.EndGroup()
        ui.W = saveW

        local mn, mx = im.GetItemRectMin(), im.GetItemRectMax()
        heights[key] = mx.y - mn.y
        pcall(function()
            dl:AddRect(mn, V2(mn.x + W, mx.y), u32(P.border), 4)
            dl:AddText(V2(mn.x + 10, mn.y + 4), u32(P.title), title)
            dl:AddLine(V2(mn.x + 10, mn.y + 21), V2(mn.x + 10 + textW(title), mn.y + 21), u32(P.accent), 1)
        end)
        im.Dummy(V2(0, 6))
        if not ok then error(err, 0) end
    end

    -- ------------------------------------------------------------ styl
    im.OnInitialize(function()
        pcall(function() im.GetIO().IniFilename = nil end)
        BTN_ON = im.ImVec4(0.42, 0.31, 0.70, 1.00)
        local s = im.GetStyle()
        s.WindowRounding, s.ChildRounding, s.FrameRounding = 6, 3, 3
        s.GrabRounding, s.ScrollbarRounding, s.PopupRounding = 3, 3, 4
        s.WindowBorderSize, s.FrameBorderSize, s.ChildBorderSize = 0, 1, 1
        s.WindowPadding = im.ImVec2(0, 0)
        s.FramePadding = im.ImVec2(6, 3)
        s.ItemSpacing = im.ImVec2(8, 7)
        s.ItemInnerSpacing = im.ImVec2(6, 4)
        s.ScrollbarSize = 6
        s.GrabMinSize = 8
        local c, C = s.Colors, im.Col
        local function set(k, r, g, b, a) c[C[k]] = im.ImVec4(r, g, b, a) end
        set('Text', 0.88, 0.88, 0.92, 1)
        set('TextDisabled', 0.48, 0.48, 0.54, 1)
        set('WindowBg', P.bgBot[1], P.bgBot[2], P.bgBot[3], 1)
        set('ChildBg', 0.04, 0.038, 0.055, 0.55)
        set('PopupBg', 0.07, 0.07, 0.085, 0.98)
        set('Border', P.border[1], P.border[2], P.border[3], 0.9)
        set('FrameBg', 0.075, 0.072, 0.100, 1)
        set('FrameBgHovered', 0.17, 0.16, 0.22, 1)
        set('FrameBgActive', 0.21, 0.18, 0.30, 1)
        set('CheckMark', P.accent[1], P.accent[2], P.accent[3], 1)
        set('SliderGrab', 0.58, 0.44, 0.92, 1)
        set('SliderGrabActive', 0.72, 0.58, 1.00, 1)
        set('Button', 0.115, 0.108, 0.155, 1)
        set('ButtonHovered', 0.22, 0.19, 0.32, 1)
        set('ButtonActive', 0.32, 0.25, 0.52, 1)
        set('Header', 0.24, 0.19, 0.40, 0.9)
        set('HeaderHovered', 0.19, 0.17, 0.27, 1)
        set('HeaderActive', 0.30, 0.23, 0.48, 1)
        set('Separator', P.border[1], P.border[2], P.border[3], 1)
        set('ScrollbarBg', 0, 0, 0, 0)
        set('ScrollbarGrab', 0.22, 0.20, 0.30, 1)
        set('ScrollbarGrabHovered', 0.30, 0.26, 0.42, 1)
        set('ScrollbarGrabActive', 0.40, 0.32, 0.60, 1)
    end)

    -- ------------------------------------------------------------ okno
    local WIN_W, WIN_H = 760, 500
    local SIDE_W, TAB_H = 128, 34
    local errShown = {}

    local function tab(id, title, active)
        local clicked = im.InvisibleButton('##aktab' .. id, V2(SIDE_W, TAB_H))
        local hov = im.IsItemHovered()
        local mn = im.GetItemRectMin()
        pcall(function()
            local dl = im.GetWindowDrawList()
            if active then
                dl:AddRectFilled(mn, V2(mn.x + SIDE_W, mn.y + TAB_H), u32(P.tabOn))
                dl:AddRectFilled(V2(mn.x, mn.y + 8), V2(mn.x + 3, mn.y + TAB_H - 8), u32(P.accent))
            end
            local col = active and P.white or (hov and P.tabHov or P.tabOff)
            dl:AddText(V2(mn.x + 22, mn.y + (TAB_H - 14) / 2), u32(col), title)
        end)
        return clicked
    end

    im.OnFrame(function() return A.menuOpen end, function(player)
        player.HideCursor = false
        player.LockPlayer = true
        A.hudDragFrame()

        im.SetNextWindowPos(V2(A.sw * 0.5, A.sh * 0.5), im.Cond.FirstUseEver, V2(0.5, 0.5))
        im.SetNextWindowSize(V2(WIN_W, WIN_H), im.Cond.Always)
        im.Begin('antek.cc##main', nil, im.WindowFlags.NoCollapse + im.WindowFlags.NoTitleBar
            + im.WindowFlags.NoResize + im.WindowFlags.NoScrollbar + im.WindowFlags.NoScrollWithMouse)

        local wp = im.GetWindowPos()
        pcall(function()
            local dl = im.GetWindowDrawList()
            local x0, y0, x1, y1 = wp.x, wp.y, wp.x + WIN_W, wp.y + WIN_H
            dl:AddRectFilledMultiColor(V2(x0, y0), V2(x1, y1), u32(P.bgTop), u32(P.bgTop), u32(P.bgBot), u32(P.bgBot))
            dl:AddRectFilled(V2(x0, y0), V2(x0 + SIDE_W, y1), u32(P.side))
            dl:AddLine(V2(x0 + SIDE_W, y0 + 3), V2(x0 + SIDE_W, y1), u32(P.border), 1)
            local mid = x0 + WIN_W / 2
            dl:AddRectFilledMultiColor(V2(x0, y0), V2(mid, y0 + 2), u32(P.accent2), u32(P.accent), u32(P.accent), u32(P.accent2))
            dl:AddRectFilledMultiColor(V2(mid, y0), V2(x1, y0 + 2), u32(P.accent), u32(P.accent3), u32(P.accent3), u32(P.accent))
            dl:AddRect(V2(x0, y0), V2(x1, y1), u32(P.edge), 6, 0, 1)
            -- logo
            dl:AddText(V2(x0 + 22, y0 + 20), u32(P.white), 'antek')
            dl:AddText(V2(x0 + 22 + textW('antek'), y0 + 20), u32(P.accent), '.cc')
            dl:AddText(V2(x0 + 22, y1 - 26), u32(P.dim), 'v' .. A.VERSION)
        end)

        -- zakladki
        local valid = A.mods[A.cfg.tab] and not A.mods[A.cfg.tab].hidden
        im.SetCursorPos(V2(0, 56))
        im.BeginGroup()
        for _, m in ipairs(A.order) do
            if not m.hidden then
                if not valid then A.cfg.tab, valid = m.id, true end
                if tab(m.id, m.title, A.cfg.tab == m.id) then A.cfg.tab = m.id end
            end
        end
        im.EndGroup()

        -- tresc
        im.SetCursorPos(V2(SIDE_W + 1, 3))
        im.PushStyleColor(im.Col.ChildBg, im.ImVec4(0, 0, 0, 0))
        im.BeginChild('##akcontent', V2(WIN_W - SIDE_W - 2, WIN_H - 4), false)
        im.PopStyleColor()
        im.Dummy(V2(0, 12))
        im.Indent(14)
        ui.W = im.GetWindowWidth() - 28
        local m = A.mods[A.cfg.tab]
        if not m then
            ui.textDim('...')
        elseif not m.ready then
            if m.initErr then ui.wrap(m.initErr, 0xFFFF6666) else ui.textDim('...') end
        elseif errShown[m.id] then
            ui.wrap(errShown[m.id], 0xFFFF6666)
            if im.Button('Ponow##akretry') then errShown[m.id] = nil end
        else
            local ok, err = pcall(m.menu)
            if not ok then
                errShown[m.id] = tostring(err)
                A.log(m.id, 'menu: ' .. tostring(err))
            end
        end
        im.Unindent(14)
        im.Dummy(V2(0, 10))
        im.EndChild()

        -- zamkniecie (prawy gorny rog)
        im.SetCursorPos(V2(WIN_W - 30, 8))
        if im.InvisibleButton('##akclose', V2(22, 22)) then A.setMenu(false) end
        local hov = im.IsItemHovered()
        pcall(function()
            local mn = im.GetItemRectMin()
            local c = u32(hov and P.white or P.dim)
            im.GetWindowDrawList():AddLine(V2(mn.x + 6, mn.y + 6), V2(mn.x + 16, mn.y + 16), c, 1.5)
            im.GetWindowDrawList():AddLine(V2(mn.x + 16, mn.y + 6), V2(mn.x + 6, mn.y + 16), c, 1.5)
        end)
        im.End()
    end)
end
end -- menu

-- ============================================================================
-- KLAWISZE (komunikaty okna: tylko gdy gra ma fokus, bez auto-repeat)
-- ============================================================================
local MODIFIER_VK = { [0x10] = true, [0x11] = true, [0x12] = true, [0x5B] = true, [0x5C] = true,
    [0xA0] = true, [0xA1] = true, [0xA2] = true, [0xA3] = true, [0xA4] = true, [0xA5] = true }

addEventHandler('onWindowMessage', function(msg, wparam, lparam)
    -- klawisz wcisniety przez bota (gornik): nie jest skrotem dla zadnego modulu
    local sy = A.synth
    if sy and ((msg == 0x020A and sy.vk == 'wheel') or ((msg == 0x0100 or msg == 0x0104) and wparam == sy.vk))
        and A.now() < sy.untilT then
        return
    end
    if msg == 0x020A then                                          -- WM_MOUSEWHEEL
        local d = A.bit.band(A.bit.rshift(wparam, 16), 0xFFFF)
        if d >= 0x8000 then d = d - 0x10000 end
        if d ~= 0 and not A.menuOpen then
            for _, mod in ipairs(A.order) do
                if mod.onWheel and A.isOn(mod.id) then pcall(mod.onWheel, d) end
            end
        end
        return
    end
    if msg ~= 0x0100 and msg ~= 0x0104 then return end            -- WM_KEYDOWN / WM_SYSKEYDOWN
    if A.bit.band(lparam, 0x40000000) ~= 0 then return end         -- auto-repeat
    if A.keyCapture then
        if MODIFIER_VK[wparam] then return end                      -- czekamy na wlasciwy klawisz kombinacji
        local f = A.keyCapture
        A.keyCapture = nil
        f(wparam, A.modState())
        consumeWindowMessage(true, false)
        return
    end
    -- panic: wylacza caly skrypt, bez zadnych komunikatow
    if A.cfg.panicKey ~= 0 and A.comboHit(A.cfg.panicKey, A.cfg.panicMods, wparam)
        and (A.cfg.panicMods ~= 0 or not A.inputBlocked()) then
        A.panicReq, A.menuOpen = true, false
        return
    end
    if wparam == 0x1B and A.menuOpen then
        A.setMenu(false)
        consumeWindowMessage(true, false)
        return
    end
    if A.comboHit(A.cfg.menuKey, A.cfg.menuMods, wparam) then
        A.keyQueue = true
        return
    end
    if A.menuOpen then return end
    for _, m in ipairs(A.order) do
        if m.onKey and A.isOn(m.id) then
            local ok, err = pcall(m.onKey, wparam)
            if not ok then A.log(m.id, 'klawisz: ' .. tostring(err)) end
        end
    end
end)

addEventHandler('onScriptTerminate', function(scr, quit)
    if scr ~= thisScript() then return end
    for _, m in ipairs(A.order) do
        if m.ready and m.terminate then pcall(m.terminate, quit) end
    end
    pcall(A.saveCore)
    pcall(A.flushSaves)
end)

-- ============================================================================
-- MAIN
-- ============================================================================
-- poprzednia instancja (podmiana pliku w trakcie gry) - wylaczamy ja, zeby nie dzialaly dwie
local function unloadOldInstances()
    if type(script) ~= 'table' or type(script.list) ~= 'function' then return end
    local me = thisScript()
    local ok, list = pcall(script.list)
    if not ok or type(list) ~= 'table' then return end
    for _, s in ipairs(list) do
        local okN, name = pcall(function() return s.name end)
        local okI, same = pcall(function() return s.id == me.id end)
        if okN and okI and name == me.name and not same then pcall(function() s:unload() end) end
    end
end

-- przelacznik modulu: OFF = watek spi, klatka/HUD/blipy nie dzialaja (A.setModule -> M.disable)
local function moduleSwitch(id, label, tip)
    local ui = A.ui
    ui.check(label .. '##mod' .. id, function() return A.cfg.modules[id] ~= false end, function(v) A.setModule(id, v) end, tip)
    return A.cfg.modules[id] ~= false
end

A.register({
    id = 'boty', title = 'Boty', ready = true,
    menu = function()
        local ui = A.ui
        ui.cols(function()
            local k, mk = A.mods.karta, A.mods.autoy
            if k then
                ui.group('Karty Bot', function()
                    if moduleSwitch('karta', 'Karty Bot', 'Wylaczony = nie dziala w tle, nie reaguje na klawisz i nie rysuje HUD.') and k.ready then k.menuGroup() end
                end)
            end
            if mk and mk.ready then ui.group('Makro', mk.menuGroup) end
        end, function()
            local g = A.mods.gornik
            if g then
                ui.group('Gornik Bot', function()
                    if moduleSwitch('gornik', 'Gornik Bot', 'Wylaczony = zadnego skanowania skal ani komunikatow, bez HUD i bez punktow na radarze.') and g.ready then g.menuGroup() end
                end)
                if A.cfg.modules.gornik ~= false and g.ready then ui.group('Rudy', g.oresGroup) end
            end
        end)
    end,
})

A.register({
    id = 'settings', title = 'Ustawienia', ready = true,
    menu = function()
        local ui = A.ui
        ui.group('Klawisze', function()
            ui.combo('Menu', A.cfg.menuKey, A.cfg.menuMods, function(k, m)
                A.cfg.menuKey, A.cfg.menuMods = k, m
                A.saveCore()
            end, false, 'Klawisz otwierajacy to menu. Mozesz ustawic kombinacje, np. Ctrl+Insert.')
            ui.combo('Panic key', A.cfg.panicKey, A.cfg.panicMods, function(k, m)
                A.cfg.panicKey, A.cfg.panicMods = k, m
                A.saveCore()
            end, true, 'Natychmiast wylacza caly skrypt, bez zadnych komunikatow. Ustaw kombinacje, ktorej nie wcisniesz przypadkiem.')
        end)
    end,
})

-- kolejnosc zakladek
local TAB_ORDER = { 'tracker', 'graffiti', 'boty', 'pool', 'gpt', 'settings' }

local function sortTabs()
    local rank = {}
    for i, id in ipairs(TAB_ORDER) do rank[id] = i end
    table.sort(A.order, function(a, b) return (rank[a.id] or 99) < (rank[b.id] or 99) end)
end

function main()
    unloadOldInstances()
    sortTabs()
    if type(isSampLoaded) == 'function' then
        while not isSampLoaded() do wait(100) end
    end
    for _ = 1, 50 do
        if A.loadSF() then break end
        wait(200)
    end
    if not A.sf then A.log('antek.cc', 'SF.lua nie zaladowany: ' .. tostring(A.sfErr)) end
    A.initFFI()
    if A.cfg.jitOff and jit and jit.off then pcall(jit.off) end

    local t0, warned = A.now(), false
    while not A.sampReady() do
        wait(200)
        if not warned and A.now() - t0 > 30 then
            warned = true
            A.log('antek.cc', 'czekam na SA-MP (SF.lua: ' .. tostring(A.sf) .. ', sampapi: ' .. tostring(A.sampapi ~= nil) .. ')')
        end
    end
    wait(500)
    A.ready = true
    A.sw, A.sh = getScreenResolution()

    for _, m in ipairs(A.order) do
        if A.cfg.modules[m.id] ~= false then A.initModule(m) end
    end
    A.startChatFeed()

    A.say('antek.cc', 'v' .. A.VERSION .. ' gotowy. Menu: ' .. A.comboName(A.cfg.menuKey, A.cfg.menuMods) .. '.')
    if not A.imgui then
        A.say('antek.cc', '{FF6666}Brak mimgui - menu niedostepne (moonloader\\lib\\mimgui).')
        A.log('antek.cc', 'mimgui: ' .. tostring(A.imguiErr))
    end
    for _, m in ipairs(A.order) do
        if m.initErr then A.say('antek.cc', '{FF6666}' .. m.title .. ' nie wystartowal: ' .. m.initErr:sub(1, 80)) end
    end

    local nextRes, nextSup = 0, 0
    while true do
        wait(0)
        A.frameNo = A.frameNo + 1
        local now = A.now()
        if now >= nextSup then
            nextSup = now + 0.5
            A.supervise()
            A.flushSaves()
        end
        if now >= nextRes then
            nextRes = now + 1
            A.sw, A.sh = getScreenResolution()
        end
        A.drawOk = not A.pauseActive()
        if A.panicReq then
            A.panicReq, A.menuOpen = false, false
            pcall(function() thisScript():unload() end)
            return
        end

        if A.pendingInit then
            local list = A.pendingInit
            A.pendingInit = nil
            for _, m in ipairs(list) do
                if A.initModule(m) then A.say('antek.cc', m.title .. ' wlaczony.') end
            end
        end

        if A.keyQueue then
            A.keyQueue = false
            if A.menuOpen then
                A.setMenu(false)
            elseif not A.inputBlocked() then
                if A.imgui then A.setMenu(true) else A.say('antek.cc', 'Menu wymaga mimgui (moonloader\\lib\\mimgui).') end
            end
        end

        for _, m in ipairs(A.order) do
            if m.ready and m.frame and A.cfg.modules[m.id] ~= false then
                local ok, err = pcall(m.frame, now)
                if not ok and (err ~= m.lastErr or now - (m.lastErrAt or -1e9) > 5) then
                    m.lastErr, m.lastErrAt = err, now
                    A.log(m.id, 'blad: ' .. tostring(err))
                end
            end
        end
    end
end