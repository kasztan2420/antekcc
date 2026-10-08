-- Symulator jazdy Strefy Bota: swiat z prostopadloscianow (budynki), raycasty / LOS liczone geometrycznie,
-- motor (model rowerowy) sterowany tym samym setGameKeyState co w grze. Bez gry, deterministycznie.
local S = {}
S.rayCost = 15e-6                 -- [s] emulowany koszt jednego promienia w grze (budzety czasu bota dzialaja jak w grze)
local function burn()
    if S.rayCost <= 0 then return end
    local t = os.clock() + S.rayCost
    while os.clock() < t do end
end

local sqrt, abs, min, max, rad, deg, sin, cos = math.sqrt, math.abs, math.min, math.max, math.rad, math.deg, math.sin, math.cos

-- ---------------------------------------------------------------- swiat
S.boxes = {}                       -- { x1, y1, x2, y2, h }
function S.reset() S.boxes = {} end
function S.box(x1, y1, x2, y2, h) S.boxes[#S.boxes + 1] = { min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2), h or 20 } end

-- odcinek vs prostopadloscian: t wejscia (0..1) i normalna; nil = brak
local function segBox(x1, y1, z1, x2, y2, z2, b)
    local dx, dy = x2 - x1, y2 - y1
    local t0, t1, nx, ny = 0, 1, 0, 0
    for axis = 1, 2 do
        local p, d, lo, hi = axis == 1 and x1 or y1, axis == 1 and dx or dy, b[axis], b[axis + 2]
        if abs(d) < 1e-12 then
            if p < lo or p > hi then return nil end
        else
            local ta, tb = (lo - p) / d, (hi - p) / d
            local na = -1
            if ta > tb then ta, tb, na = tb, ta, 1 end
            if ta > t0 then
                t0 = ta
                if axis == 1 then nx, ny = na, 0 else nx, ny = 0, na end
            end
            if tb < t1 then t1 = tb end
            if t0 > t1 then return nil end
        end
    end
    local z = z1 + (z2 - z1) * t0
    if z < 0 or z > b[5] then return nil end
    return t0, nx, ny
end

local function rayWorld(x1, y1, z1, x2, y2, z2)
    local best, bnx, bny
    for _, b in ipairs(S.boxes) do
        local t, nx, ny = segBox(x1, y1, z1, x2, y2, z2, b)
        if t and (not best or t < best) then best, bnx, bny = t, nx, ny end
    end
    return best, bnx, bny
end

local function colPoint(x, y, z, nx, ny, nz)
    return { pos = { x, y, z }, normal = { nx, ny, nz }, entity = 0 }
end

-- processLineOfSight(x1,y1,z1,x2,y2,z2, solid, car, ped, object, ...)
function S.processLineOfSight(x1, y1, z1, x2, y2, z2, solid)
    S.rays = (S.rays or 0) + 1
    burn()
    if not solid then return false, nil end
    if abs(x2 - x1) < 1e-6 and abs(y2 - y1) < 1e-6 then          -- promien pionowy: ziemia albo dach
        for _, b in ipairs(S.boxes) do
            if x1 >= b[1] and x1 <= b[3] and y1 >= b[2] and y1 <= b[4] and z1 >= b[5] and z2 <= b[5] then
                return true, colPoint(x1, y1, b[5], 0, 0, 1)
            end
        end
        if z1 >= 0 and z2 <= 0 then return true, colPoint(x1, y1, 0, 0, 0, 1) end
        return false, nil
    end
    local t, nx, ny = rayWorld(x1, y1, z1, x2, y2, z2)
    if not t then
        if z2 < 0 and z1 >= 0 then                                  -- skosny w ziemie
            local tg = z1 / (z1 - z2)
            return true, colPoint(x1 + (x2 - x1) * tg, y1 + (y2 - y1) * tg, 0, 0, 0, 1)
        end
        return false, nil
    end
    return true, colPoint(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, z1 + (z2 - z1) * t, nx, ny, 0)
end

function S.isLineOfSightClear(x1, y1, z1, x2, y2, z2)
    S.rays = (S.rays or 0) + 1
    burn()
    return rayWorld(x1, y1, z1, x2, y2, z2) == nil
end

-- ---------------------------------------------------------------- motor
S.car = { x = 0, y = 0, h = 0, v = 0, delta = 0 }
S.keys = {}
local R_CAR = 0.45

local function hits(x, y)
    for _, b in ipairs(S.boxes) do
        local cx, cy = max(b[1], min(x, b[3])), max(b[2], min(y, b[4]))
        if (cx - x) ^ 2 + (cy - y) ^ 2 < R_CAR * R_CAR then return true end
    end
    return false
end

function S.clearance(x, y)
    local best = 1e9
    for _, b in ipairs(S.boxes) do
        local cx, cy = max(b[1], min(x, b[3])), max(b[2], min(y, b[4]))
        best = min(best, sqrt((cx - x) ^ 2 + (cy - y) ^ 2))
    end
    return best
end

-- krok fizyki: pad 0 = kierownica (-128 lewo .. 128 prawo), 16 = gaz, 14 = hamulec/wsteczny
function S.step(dt)
    local c, k = S.car, S.keys
    local steer = max(-1, min(1, (k[0] or 0) / 128))
    local thr, brk = max(0, (k[16] or 0) / 255), max(0, (k[14] or 0) / 255)
    local want = -steer * rad(28) / (1 + abs(c.v) / 25)                -- lewo = +heading (CCW)
    c.delta = c.delta + (want - c.delta) * min(1, dt / 0.12)
    local a = 8.5 * thr - 0.0035 * c.v * abs(c.v) - 0.25 * (c.v > 0 and 1 or (c.v < 0 and -1 or 0))
    if brk > 0 then
        if c.v > 0.3 then a = a - 13 * brk else a = a - 4 * brk end     -- hamulec, na postoju wsteczny
    end
    if thr == 0 and brk == 0 and abs(c.v) < 0.3 then c.v, a = 0, 0 end
    c.v = max(-6, min(48, c.v + a * dt))
    c.h = (c.h + deg(c.v / 1.45 * math.tan(c.delta)) * dt) % 360
    local hr = rad(c.h)
    local nx, ny = c.x - sin(hr) * c.v * dt, c.y + cos(hr) * c.v * dt
    if hits(nx, ny) then
        if not c.inContact then
            S.stats.collisions = S.stats.collisions + 1
            S.stats.hitSpeed = max(S.stats.hitSpeed, abs(c.v))
        end
        c.inContact, c.v = true, -c.v * 0.2
    else
        c.x, c.y, c.inContact = nx, ny, false
    end
    S.keys = {}
end

-- ---------------------------------------------------------------- API gry dla bota
function S.install(env)
    env.processLineOfSight = S.processLineOfSight
    env.isLineOfSightClear = S.isLineOfSightClear
    env.setGameKeyState = function(k, v) S.keys[k] = v end
    env.getCarCoordinates = function() return S.car.x, S.car.y, 0.6 end
    env.getCarSpeed = function() return abs(S.car.v) end
    env.getCarHeading = function() return S.car.h end
    env.isCarUpsidedown = function() return false end
    env.getActiveInterior = function() return 0 end
end

-- ---------------------------------------------------------------- przejazd
-- bot: GBX.test; tgt = { x, y }; o = { h0, timeout, park }
function S.run(bot, tgt, o)
    o = o or {}
    local c = S.car
    S.stats = { collisions = 0, hitSpeed = 0, t = 0, minClear = 1e9, slowT = 0, steerJerk = 0, frameMax = 0, frameSum = 0, frames = 0,
        raysMax = 0, rays = 0 }
    local MV = bot.MV
    MV.dest = { key = o.key or 'sim', x = tgt.x, y = tgt.y, z = 0.6, reach = 1.0, goalR = 1.2, park = o.park or 1.3, keepVeh = true }
    local now, dt = 1000, 1 / 60
    bot.mvDrive(now, 1)
    if o.vmax then MV.drv.vmax = o.vmax end
    local res, lastSteer = 'run', 0
    local timeout = o.timeout or 120
    while S.stats.t < timeout do
        local t0 = os.clock()
        S.rays = 0
        res = bot.driveStep(now, 1)
        local ft = os.clock() - t0
        S.stats.raysMax, S.stats.rays = max(S.stats.raysMax, S.rays), S.stats.rays + S.rays
        S.stats.frameMax, S.stats.frameSum, S.stats.frames = max(S.stats.frameMax, ft), S.stats.frameSum + ft, S.stats.frames + 1
        local st = S.keys[0] or 0
        if abs(c.v) > 3 then S.stats.steerJerk = S.stats.steerJerk + abs(st - lastSteer) end
        lastSteer = st
        if res ~= 'run' then break end
        local col0 = S.stats.collisions
        S.step(dt)
        if S.trace and (S.stats.collisions > col0 or math.floor(S.stats.t * 2) ~= math.floor((S.stats.t - dt) * 2)) then
            local D = MV.drv
            print(('  t=%5.1f pos=%6.1f,%6.1f v=%5.1f h=%5.0f src=%-5s a=%4.0f why=%s%s'):format(S.stats.t, c.x, c.y, c.v, c.h,
                tostring(D.src), D.lastA or 0, tostring(bot.GB.why), S.stats.collisions > col0 and '  <<< KOLIZJA' or ''))
        end
        now, S.stats.t = now + dt, S.stats.t + dt
        S.stats.minClear = min(S.stats.minClear, S.clearance(c.x, c.y))
        if abs(c.v) < 2 then S.stats.slowT = S.stats.slowT + dt end
    end
    S.stats.result = res
    S.stats.dist = sqrt((tgt.x - c.x) ^ 2 + (tgt.y - c.y) ^ 2)
    return S.stats
end

return S
