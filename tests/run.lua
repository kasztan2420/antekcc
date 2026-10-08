-- luajit tests/run.lua  (z katalogu repo)
package.path = './tests/?.lua;' .. package.path
local H = require('harness')
local FI = H.withFakeImgui()
local A = H.load()

local pass, fail = 0, 0
local function t(name, fn)
    local ok, err = pcall(fn)
    if ok then pass = pass + 1 else fail = fail + 1; print('FAIL  ' .. name .. ': ' .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or '') .. ' oczekiwano ' .. tostring(b) .. ', jest ' .. tostring(a), 2) end
end

-- ------------------------------------------------------------ ladowanie
t('skrypt sie laduje i rejestruje moduly', function()
    assert(type(A) == 'table', 'brak A')
    for _, id in ipairs({ 'tracker', 'graffiti', 'strefy', 'pool', 'gpt', 'autoy', 'karta', 'gornik', 'statuetki', 'walizki', 'tools',
        'boty', 'settings' }) do
        assert(A.mods[id], 'brak modulu ' .. id)
    end
end)

t('wersja spojna', function()
    assert(type(A.VERSION) == 'string' and A.VERSION:match('^%d+%.%d+%.%d+$'), 'VERSION ' .. tostring(A.VERSION))
end)

-- ------------------------------------------------------------ JSON
t('json roundtrip', function()
    local src = { a = 1, b = 'x"y\\z\n', c = { 1, 2, 3 }, d = true, e = { f = -1.5 } }
    local back = A.json.decode(A.json.encode(src))
    eq(back.a, 1); eq(back.b, src.b); eq(#back.c, 3); eq(back.d, true); eq(back.e.f, -1.5)
end)

t('json unicode + surogaty', function()
    eq(A.json.decode('"\\u0105\\ud83d\\ude00"'), '\196\133\240\159\152\128')
end)

t('json bledy', function()
    assert(not pcall(A.json.decode, '{"a":1,}'), 'przecinek na koncu')
    assert(not pcall(A.json.decode, '[1 2]'), 'brak przecinka')
    assert(not pcall(A.json.decode, '{"a":1} x'), 'smieci')
end)

t('json NaN/inf -> null', function()
    eq(A.json.encode({ 0 / 0 }), '[null]')
    eq(A.json.encode({ math.huge }), '[null]')
end)

-- ------------------------------------------------------------ kodowanie
t('cp1250 <-> utf8', function()
    local cp = '\185\230\234\179\241\243\156\159\191'   -- acelnoszz z ogonkami (male)
    local u = A.u8(cp)
    eq(A.cp(u), cp)
    eq(A.u8('abc'), 'abc')
end)

t('stripColors', function() eq(A.stripColors('{FF0000}a{00ff00}b'), 'ab') end)
t('trim', function() eq(A.trim('  x y \t'), 'x y') end)
t('clamp', function() eq(A.clamp(5, 0, 3), 3); eq(A.clamp(-1, 0, 3), 0); eq(A.clamp(2, 5, 1), 5) end)
t('overlay typy', function()
    local b = { a = 1, s = 'x', t = { q = true } }
    A.overlay(b, { a = 'zle', s = 'y', t = { q = false }, nowy = 1 })
    eq(b.a, 1); eq(b.s, 'y'); eq(b.t.q, false); eq(b.nowy, nil)
end)

t('keyName / comboName', function()
    eq(A.keyName(0x2D), 'Insert'); eq(A.keyName(0x70), 'F1'); eq(A.keyName(0x41), 'A')
    eq(A.comboName(0x2D, 1 + 4), 'Ctrl+Alt+Insert'); eq(A.comboName(0, 0), 'brak')
end)

-- ------------------------------------------------------------ Strefy (parsery czatu i /strefy)
t('strefy: zoneChat start/win', function()
    local T = A.mods.strefy.test
    T.chat('Twoj gang atakuje strefe Idlewood (8) nalezaca do gangu FullServer FS!')
    local zs = A.mods.strefy.zone(8)
    assert(zs and zs.mine == false, 'strefa 8 nie nasza')
    eq(zs.owner, 'FullServer FS')
    T.chat('Twoj gang podbil strefe Idlewood (8) nalezaca dotychczas do gangu FullServer FS! Kontrolujecie juz 29 stref!')
    assert(A.mods.strefy.zone(8).mine == true, 'strefa 8 nasza po podbiciu')
end)

t('strefy: parse /strefy', function()
    local T = A.mods.strefy.test
    local n = T.parse('ID\tNazwa\tWlasciciel\tAtak\n5\tIdlewood\t{FF0000}gang XYZ\tza 20 minut\n6\tIdlewood\tbrak\tTak\n')
    eq(n, 2)
    local z5, z6 = A.mods.strefy.zone(5), A.mods.strefy.zone(6)
    assert(z5.cd > os.time() + 1000, 'cooldown strefy 5')
    eq(z6.cd, 0); eq(z6.mine, false)
    eq(A.mods.strefy.zoneReady(6), true)
end)

t('strefy: atak na nas -> HUD wroga', function()
    local T = A.mods.strefy.test
    T.event('atak', 'gang ABC', 'Glen Park (9)')
    eq(#T.enemy(), 1)
    T.event('odparty', 'gang ABC', 'Glen Park (9)')
    eq(#T.enemy(), 0)
end)

if A.mods.strefy.test.webhookOk then
    t('strefy: walidacja webhooka', function()
        local ok = A.mods.strefy.test.webhookOk
        assert(ok('https://discord.com/api/webhooks/123/abc_DEF-9'), 'poprawny')
        assert(ok('https://ptb.discord.com/api/webhooks/1/x'), 'ptb')
        assert(not ok('https://discord.com/api/webhooks/1/x" & calc'), 'wstrzykniecie')
        assert(not ok("https://discord.com/api/webhooks/1/x'; rm"), 'apostrof')
        assert(not ok('http://discord.com/api/webhooks/1/x'), 'http')
        assert(not ok(''), 'pusty')
    end)
end

t('cp1250 <-> utf8: wszystkie polskie litery', function()
    local cp = '\165\185\198\230\202\234\163\179\209\241\211\243\140\156\143\159\175\191'
    eq(A.cp(A.u8(cp)), cp)
    eq(A.cp('za\197\188\195\179\197\130\196\135 g\196\153\197\155l\196\133 ja\197\186\197\132'),
        'za\191\243\179\230 g\234\156l\185 ja\159\241')
    eq(A.cp('\226\130\172'), '?')          -- znak spoza CP1250 (euro) -> ?
end)

t('toInt32', function()
    eq(A.toInt32(0xFFFFFFFF), -1); eq(A.toInt32(0x7FFFFFFF), 0x7FFFFFFF); eq(A.toInt32(0x33CCFFFF), 0x33CCFFFF)
end)

t('config: przelaczniki wszystkich modulow przetrwaja restart', function()
    for _, row in ipairs({ 'tracker', 'graffiti', 'strefy', 'pool', 'gpt', 'autoy', 'karta', 'gornik', 'statuetki', 'walizki' }) do
        assert(A.cfg.modules[row] ~= nil, 'brak domyslnego stanu modulu ' .. row)
    end
    A.cfg.modules.gornik, A.cfg.modules.walizki = false, false
    assert(A.saveCore())
    A.cfg.modules.gornik, A.cfg.modules.walizki = true, true
    A.loadCore()
    eq(A.cfg.modules.gornik, false, 'gornik'); eq(A.cfg.modules.walizki, false, 'walizki')
    A.cfg.modules.gornik, A.cfg.modules.walizki = true, true
end)

t('config: uszkodzony JSON -> kopia .bak, bez wyjatku', function()
    local f = io.open(A.CORE_FILE, 'wb'); f:write('{zle'); f:close()
    eq(A.loadCore(), false)
    assert(io.open(A.CORE_FILE .. '.bak', 'rb'), 'brak .bak')
end)

t('kazdy modul ma id, tytul i menu albo jest ukryty', function()
    for _, m in ipairs(A.order) do
        assert(type(m.id) == 'string' and type(m.title) == 'string', 'modul bez id/tytulu')
        assert(m.hidden or type(m.menu) == 'function', 'zakladka bez menu: ' .. m.id)
    end
end)

-- init() kazdego modulu na atrapach API: blad inny niz brak API gry = bug w kodzie
t('init modulow (atrapy API)', function()
    local apiErr = { 'SAMP%-API', 'attempt to call', 'attempt to index', 'attempt to perform arithmetic on a nil' }
    for _, m in ipairs(A.order) do
        if m.init and not m.ready then
            A.initModule(m)
            if m.initErr then
                local known = false
                for _, p in ipairs(apiErr) do if m.initErr:find(p) then known = true end end
                assert(known, m.id .. ': ' .. m.initErr)
            end
        end
    end
end)

-- klatki wszystkich modulow (atrapy: gracz w swiecie gry), takze z otwartym menu (HUD-y w trybie przeciagania)
t('frame modulow (atrapy API)', function()
    H.gameStubs()
    A.ready, A.sw, A.sh = true, 1920, 1080
    local errs = {}
    for pass_ = 1, 3 do
        A.menuOpen = pass_ == 3
        local now = A.now() + pass_
        for _, m in ipairs(A.order) do
            if m.ready and m.frame then
                local ok, err = pcall(m.frame, now)
                if not ok then errs[#errs + 1] = m.id .. ': ' .. tostring(err) end
            end
        end
    end
    A.menuOpen = false
    assert(#errs == 0, table.concat(errs, ' | '))
end)

t('status() i setupHint() modulow', function()
    for _, m in ipairs(A.order) do
        if m.ready and m.status then
            local ok, r = pcall(m.status)
            assert(ok and type(r) == 'string', m.id .. ': ' .. tostring(r))
        end
        if m.ready and m.setupHint then
            local ok, r = pcall(m.setupHint)
            assert(ok and (r == nil or type(r) == 'string'), m.id .. ' setupHint: ' .. tostring(r))
        end
    end
end)

-- menu: kazda zakladka renderowana (atrapa mimgui), potem drugi przebieg z "kliknieciem" wszystkiego
t('menu: render i klikniecia wszystkich zakladek', function()
    assert(A.imgui == FI.im, 'menu nie dostalo atrapy mimgui')
    for _, fn in ipairs(FI.inits) do fn() end
    local logged = {}
    local rawLog = A.log
    A.log = function(tag, msg) logged[#logged + 1] = tostring(tag) .. ': ' .. tostring(msg) end
    local origSetMenu = A.setMenu
    A.setMenu = function() end                     -- przyciski zamykajace menu nie przerywaja testu
    local errs = {}
    for pass_ = 1, 2 do
        FI.clickAll = pass_ == 2
        for _, m in ipairs(A.order) do
            if not m.hidden then
                A.cfg.tab, A.menuOpen = m.id, true
                for _, fr in ipairs(FI.frames) do
                    local ok, err = pcall(fr.fn, { })
                    if not ok then errs[#errs + 1] = m.id .. ' (klatka): ' .. tostring(err) end
                end
            end
        end
    end
    FI.clickAll, A.menuOpen, A.setMenu, A.log = false, false, origSetMenu, rawLog
    for _, l in ipairs(logged) do
        if l:find('menu:', 1, true) then errs[#errs + 1] = l end
    end
    assert(#errs == 0, '\n  ' .. table.concat(errs, '\n  '))
end)

-- Narzedzia: TNT, ukrywanie obiektow, celownik, RC (swiat z atrap)
t('narzedzia: TNT, ukrywanie, celownik, RC', function()
    local T = A.mods.tools.test
    local E = H.env
    local world = {                    -- uchwyt -> { model, x, y, z }
        [1] = { 1271, 110, 200, 10 }, [2] = { 1271, 150, 200, 10 }, [3] = { 3000, 101, 200, 10 },
    }
    local shown = {}                   -- uchwyt -> false po ukryciu
    E.getAllObjects = function() local l = {} for h in pairs(world) do l[#l + 1] = h end return l end
    E.doesObjectExist = function(h) return world[h] ~= nil end
    E.getObjectModel = function(h) return world[h][1] end
    E.getObjectCoordinates = function(h) local o = world[h]; return true, o[2], o[3], o[4] end
    E.getObjectPointer = function(h) return 1000 + h end
    E.setObjectVisible = function(h, v) shown[h] = v end
    E.setObjectCollision = function() end

    T.setTnt(1271, true)
    T.scan(100, 200, 10)
    eq(#T.tnts(), 2, 'TNT w zasiegu')
    eq(T.tnts()[1].x, 110, 'najblizsze pierwsze')
    eq(T.objs()[1].m, 3000, 'lista obiektow od najblizszego')

    -- celownik: promien z kamery trafia w obiekt o wskazniku 1003
    E.processLineOfSight = function() return true, { pos = { 101, 200, 10 }, normal = { -1, 0, 0 }, entity = 1003 } end
    T.aimUpdate()
    assert(T.aim() and T.aim().h == 3, 'celownik nie znalazl obiektu')

    T.hideOne(T.aim())
    eq(shown[3], false, 'obiekt nie ukryty')
    eq(#T.C.hidden, 1)
    -- serwer wczytuje obiekt ponownie (nowy uchwyt, ta sama pozycja): ukrywa sie sam
    world[3], world[7] = nil, { 3000, 101, 200, 10 }
    T.scan(100, 200, 10)
    eq(shown[7], false, 'po streamie obiekt nie ukryl sie znowu')
    T.restoreAll()
    eq(shown[7], true, 'przywracanie')
    eq(#T.C.hidden, 0)

    -- RC: wolny RC Goblin 3 m obok -> wsiada; zwykle auto blizej -> nie
    local cars = { [10] = { 501, 103, 200, 10 }, [11] = { 400, 110, 200, 10 } }
    local warped
    E.isCharInAnyCar = function() return false end
    E.getAllVehicles = function() local l = {} for h in pairs(cars) do l[#l + 1] = h end return l end
    E.doesVehicleExist = function(v) return cars[v] ~= nil end
    E.getCarCoordinates = function(v) local c = cars[v]; return c[2], c[3], c[4] end
    E.getCarModel = function(v) return cars[v][1] end
    E.getDriverOfCar = function() return -1 end
    E.warpCharIntoCar = function(_, v) warped = v end
    T.rcEnter()
    eq(warped, 10, 'nie wsiadl do RC')
    warped = nil
    cars[11] = { 400, 101.5, 200, 10 }
    T.rcEnter()
    eq(warped, nil, 'wsiadl do RC mimo blizszego zwyklego auta')
    T.setTnt(1271, false)
end)

print(('%d ok, %d fail'):format(pass, fail))
H.cleanup()
os.exit(fail == 0 and 0 or 1)
