-- luajit tests/sim_drive.lua [nazwa_scenariusza]
-- Strefy Bot w symulatorze: kazdy scenariusz = start, cel, budynki (+ opcjonalnie siec drog).
-- Wynik: czy dojechal, czas, kolizje, min. odstep od scian, czas ponizej 2 m/s, najdluzsza klatka bota.
package.path = './tests/?.lua;' .. package.path
local H = require('harness')
local A = H.load()
local S = require('sim')
H.gameStubs()
S.install(H.env)
A.ready, A.sw, A.sh = true, 1920, 1080
A.initModule(A.mods.graffiti)
local bot = A.mods.graffiti.botTest
assert(bot, 'brak haka botTest')
local RN = bot.RN

-- siec drog z odcinkow { {x1,y1,x2,y2}, ... } (wezly co 8 m, polaczenia w obie strony, wspolne wezly na skrzyzowaniach)
local function roads(segs)
    local px, py, pz, adj, grid, ids = {}, {}, {}, {}, {}, {}
    local function node(x, y)
        local k = math.floor(x * 10 + 0.5) .. ':' .. math.floor(y * 10 + 0.5)
        if ids[k] then return ids[k] end
        local id = #px + 1
        px[id], py[id], pz[id], adj[id] = x, y, 0, {}
        ids[k] = id
        local gk = math.floor((x + 3000) / 50) * 256 + math.floor((y + 3000) / 50)
        grid[gk] = grid[gk] or {}
        table.insert(grid[gk], id)
        return id
    end
    for _, sg in ipairs(segs) do
        local x1, y1, x2, y2 = sg[1], sg[2], sg[3], sg[4]
        local n = math.max(1, math.floor(math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2) / 8 + 0.5))
        local prev
        for i = 0, n do
            local id = node(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n)
            if prev and prev ~= id then table.insert(adj[prev], id); table.insert(adj[id], prev) end
            prev = id
        end
    end
    RN.fake, RN.off = true, 0
    RN.px, RN.py, RN.pz, RN.adj, RN.grid, RN.pen, RN.nodes = px, py, pz, adj, grid, {}, #px
end

local function noRoads()
    RN.fake, RN.off = true, 0
    RN.px, RN.py, RN.pz, RN.adj, RN.grid, RN.pen, RN.nodes = {}, {}, {}, {}, {}, {}, 0
end

local SC = {}
SC[#SC + 1] = { name = 'prosta 250 m', start = { 0, 0, 0 }, tgt = { 0, 250 }, build = function() noRoads() end }
SC[#SC + 1] = { name = 'sciana na wprost', start = { 0, 0, 0 }, tgt = { 0, 90 }, build = function()
    noRoads(); S.box(-15, 40, 15, 43) end }
SC[#SC + 1] = { name = 'brama 5 m', start = { 0, 0, 0 }, tgt = { 0, 100 }, build = function()
    noRoads(); S.box(-80, 50, -2.5, 53); S.box(2.5, 50, 80, 53) end }
SC[#SC + 1] = { name = 'L bez drog', start = { 0, 0, 0 }, tgt = { 110, 120 }, build = function()
    noRoads()
    S.box(-30, -20, -6, 150)      -- lewa sciana korytarza
    S.box(6, -20, 150, 114)       -- blok wewnetrzny
    S.box(-30, 126, 150, 150)     -- gorna sciana
    S.box(130, 110, 150, 130)     -- koniec
end }
SC[#SC + 1] = { name = 'L z drogami', start = { 0, 0, 0 }, tgt = { 110, 120 }, build = function()
    roads({ { 0, -10, 0, 120 }, { 0, 120, 125, 120 } })
    S.box(-30, -20, -6, 150); S.box(6, -20, 150, 114); S.box(-30, 126, 150, 150); S.box(130, 110, 150, 130)
end }
local function city(withRoads)
    local B, W = 40, 12          -- blok 40 m, ulica 12 m; osie ulic: x,y = k*(B+W)
    local P = B + W
    for i = 0, 4 do
        for j = 0, 4 do
            local x0, y0 = i * P + W / 2, j * P + W / 2
            S.box(x0, y0, x0 + B, y0 + B, 25)
        end
    end
    if withRoads then
        local segs = {}                         -- odcinki miedzy sasiednimi skrzyzowaniami: wspolne wezly na skrzyzowaniach
        for k = 0, 5 do
            for j = 0, 4 do
                segs[#segs + 1] = { k * P, j * P, k * P, (j + 1) * P }
                segs[#segs + 1] = { j * P, k * P, (j + 1) * P, k * P }
            end
        end
        roads(segs)
    else
        noRoads()
    end
end
SC[#SC + 1] = { name = 'miasto z drogami', start = { 0, 2, 0 }, tgt = { 3 * 52, 3 * 52 + 20 }, build = function() city(true) end }
SC[#SC + 1] = { name = 'miasto bez drog', start = { 0, 2, 0 }, tgt = { 2 * 52, 2 * 52 + 20 }, build = function() city(false) end }
SC[#SC + 1] = { name = 'zaulek', start = { 0, 0, 0 }, tgt = { 60, 108 }, build = function()
    roads({ { 0, -10, 0, 160 } })
    S.box(-40, -20, -7, 180)                    -- sciana po lewej ulicy
    S.box(7, -20, 80, 105)                      -- budynek przed zaulkiem
    S.box(7, 111, 80, 180)                      -- budynek za zaulkiem (zaulek: y 105..111, 6 m)
    S.box(70, 100, 90, 115)                     -- koniec zaulka
end }

SC[#SC + 1] = { name = 'auto na jezdni', start = { 0, 0, 0 }, tgt = { 0, 200 }, build = function()
    roads({ { 0, -10, 0, 220 } })
    S.box(-30, -20, -7, 230); S.box(7, -20, 30, 230)          -- ulica 14 m
    S.box(-0.5, 80, 2.5, 86, 2)                                -- auto stoi na prawym pasie (pas bota: x ~ +1)
end }
SC[#SC + 1] = { name = 'szczelina 3.2 m', start = { 0, 0, 0 }, tgt = { 0, 70 }, build = function()
    noRoads(); S.box(-60, 35, -1.6, 37); S.box(1.6, 35, 60, 37) end }
SC[#SC + 1] = { name = 'zawracanie', start = { 0, 0, 0 }, tgt = { 0, -80 }, build = function() noRoads() end }
SC[#SC + 1] = { name = 'las slupow', start = { 0, 0, 0 }, tgt = { 5, 140 }, build = function()
    noRoads()
    local seed = 7
    local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648 end
    for _ = 1, 45 do
        local x, y = -25 + rnd() * 50, 20 + rnd() * 100
        S.box(x - 0.3, y - 0.3, x + 0.3, y + 0.3, 6)
    end
end }
SC[#SC + 1] = { name = 'cel przy scianie', start = { 0, 0, 0 }, tgt = { 20, 60 }, build = function()
    noRoads(); S.box(21.5, 30, 40, 90) end }
SC[#SC + 1] = { name = 'miasto, trasa z gory', start = { 0, 2, 0 }, tgt = { 3 * 52, 3 * 52 + 20 }, prefetch = true,
    build = function() city(true) end }
SC[#SC + 1] = { name = 'miasto 30 m/s', start = { 0, 2, 0 }, tgt = { 3 * 52, 3 * 52 + 20 }, vmax = 30, build = function() city(true) end }

local only = arg[1]
S.trace = arg[2] == 'trace'
print(('%-20s %-8s %7s %5s %6s %7s %8s %6s %6s %7s %6s'):format('scenariusz', 'wynik', 'czas', 'kol.', 'odstep', 'wolno', 'klatka',
    'pr/kl', 'pr/s', 'cel', 'szarp'))
local failures = 0
for _, sc in ipairs(SC) do
    if not only or sc.name:find(only, 1, true) then
        local worst, tsum, runs = nil, 0, tonumber(os.getenv('RUNS') or '3')
        for _ = 1, runs do
            S.reset()
            sc.build()
            S.car.x, S.car.y, S.car.h, S.car.v, S.car.delta, S.car.inContact = sc.start[1], sc.start[2], sc.start[3], 0, 0, false
            for k in pairs(bot.MV) do if k ~= 'noBike' and k ~= 'nrgNext' and k ~= 'nrgFails' then bot.MV[k] = nil end end
            for _, nav in ipairs({ bot.NB, bot.NF }) do                   -- inny swiat = inna kolizja: bez cache z poprzedniego
                local q = nav.p
                q.edges, q.nEdges, q.cacheAt, q.blocks, q.pens = {}, 0, -1e9, {}, {}
            end
            RN.pen = {}
            local key
            if sc.prefetch then                     -- jak po przejeciu strefy: trasa po drogach policzona juz wczesniej
                local job = bot.rnPlan(sc.start[1], sc.start[2], 0.6, sc.tgt[1], sc.tgt[2], 0.6)
                local rr
                repeat rr = bot.rnRun(job) until rr ~= 'run'
                assert(type(rr) == 'table', 'brak trasy do prefetchu')
                bot.ZB.pre, key = { from = 0, id = 5, route = rr, sx = sc.start[1], sy = sc.start[2] }, 'z5'
            end
            local r = S.run(bot, { x = sc.tgt[1], y = sc.tgt[2] }, { timeout = sc.timeout or 90, vmax = sc.vmax, key = key })
            if sc.prefetch then assert(bot.ZB.pre == nil, 'trasa z gory nie zostala uzyta') end
            tsum = tsum + r.t
            if not worst or (r.result ~= 'arrived' and worst.result == 'arrived') or r.collisions > worst.collisions
                or (r.collisions == worst.collisions and r.t > worst.t) then worst = r end
        end
        local st = worst
        print(('%-20s %-8s %6.1fs %5d %5.1fm %6.1fs %6.1fms %6d %6d %6.1fm %6.0f   (sr. %.1fs)'):format(sc.name, st.result, st.t,
            st.collisions, math.min(st.minClear, 99), st.slowT, st.frameMax * 1000, st.raysMax,
            math.floor(st.rays / math.max(st.t, 0.01)), st.dist, st.steerJerk / math.max(st.t, 0.01), tsum / runs))
        if st.result ~= 'arrived' or st.collisions > 0 then failures = failures + 1 end
        sc.stats = st
    end
end
H.cleanup()
os.exit(failures == 0 and 0 or 1)
