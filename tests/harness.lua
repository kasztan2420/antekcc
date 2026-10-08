-- Harness testowy: laduje antek.lua pod czystym LuaJIT (bez gry) ze stubami API MoonLoadera / SF.lua.
-- Kazda nieznana funkcja globalna jest atrapa zwracajaca nil, wiec skrypt laduje sie w calosci
-- (rejestracja modulow, stale, parsery), a testy dostaja dostep do wewnetrznej tabeli A.
--   luajit tests/run.lua
local H = {}

local root = (arg and arg[0] or ''):match('^(.*)[/\\]tests[/\\]') or '.'
H.root = root
H.tmp = os.getenv('TMPDIR') or '/tmp'
H.workdir = H.tmp .. '/antek_test_' .. tostring(os.time()) .. '_' .. tostring(math.random(1e6))
os.execute('mkdir -p "' .. H.workdir .. '/config"')

local STUB = setmetatable({}, { __call = function() return nil end })

local env
env = {
    getWorkingDirectory = function() return H.workdir end,
    addEventHandler = function(name, fn) H.events = H.events or {}; H.events[name] = H.events[name] or {}; table.insert(H.events[name], fn) end,
    lua_thread = { create = function(fn) return { status = function() return 'suspended' end, run = function() end, fn = fn } end },
    wait = function() end,
    thisScript = function() return { id = 1, name = 'antek.cc' } end,
    localClock = os.clock,
    createDirectory = function(p) os.execute('mkdir -p "' .. p:gsub('\\', '/') .. '"'); return true end,
    doesFileExist = function(p) local f = io.open(p:gsub('\\', '/'), 'rb'); if f then f:close(); return true end; return false end,
}

H.env = env

-- sciezki Windows (\\) -> POSIX, zeby zapis/odczyt plikow dzialal w testach
local rawOpen, rawRemove, rawRename = io.open, os.remove, os.rename
io.open = function(p, m) return rawOpen((tostring(p):gsub('\\', '/')), m) end
os.remove = function(p) return rawRemove((tostring(p):gsub('\\', '/'))) end
os.rename = function(a, b) return rawRename((tostring(a):gsub('\\', '/')), (tostring(b):gsub('\\', '/'))) end

setmetatable(_G, { __index = function(_, k)
    local v = env[k]
    if v ~= nil then return v end
    if type(k) == 'string' and k:match('^script_') then return STUB end
    return STUB
end })

-- atrapy "gracz stoi w swiecie gry": bez dialogow, czatu, textdrawow i etykiet 3D
function H.gameStubs()
    local function ret(...) local v = { ... }; return function() return unpack(v) end end
    local g = {
        isPlayerPlaying = ret(true), getCharCoordinates = ret(100.0, 200.0, 10.0), getCharHeading = ret(0.0),
        getActiveInterior = ret(0), getScreenResolution = ret(1920, 1080), isPauseMenuActive = ret(false),
        sampIsDialogActive = ret(false), sampIsChatInputActive = ret(false), sampIsCursorActive = ret(false),
        sampIs3dTextDefined = ret(false), sampTextdrawIsExists = ret(false), getAllObjects = ret({}),
        getAllVehicles = ret({}), doesBlipExist = ret(false), isCharInAnyCar = ret(false), isCharDead = ret(false),
        getActiveCameraCoordinates = ret(100.0, 190.0, 12.0), getActiveCameraPointAt = ret(100.0, 200.0, 10.0),
        renderCreateFont = ret({}), renderGetFontDrawTextLength = ret(100), renderGetFontDrawHeight = ret(14),
        isKeyDown = ret(false), isKeyJustPressed = ret(false), sampGetChatString = ret('', '', 0),
        isSampAvailable = ret(true), sampGetDialogCaption = ret(''), sampGetDialogText = ret(''),
        convert3DCoordsToScreen = ret(500, 500), isPointOnScreen = ret(false), placeWaypoint = ret(),
        getTargetBlipCoordinates = ret(false),
    }
    for k, v in pairs(g) do env[k] = v end
end

-- przed H.load(): mimgui = atrapa z tests/fake_mimgui.lua (menu da sie wyrenderowac bez gry)
function H.withFakeImgui()
    H.fakeImgui = require('fake_mimgui')
    package.preload['mimgui'] = function() return H.fakeImgui.im end
    return H.fakeImgui
end

function H.load()
    local f = assert(rawOpen(root .. '/antek.lua', 'rb'))
    local src = f:read('*a')
    f:close()
    src = src .. '\n_G.__ANTEK = A\n'
    local chunk = assert(loadstring(src, '@antek.lua'))
    chunk()
    return rawget(_G, '__ANTEK')
end

function H.cleanup()
    os.execute('rm -rf "' .. H.workdir .. '"')
end

return H
