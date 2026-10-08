-- Atrapa mimgui do testow menu: kazda funkcja istnieje, rysowanie nic nie robi.
-- F.clickAll = true: kazdy Button / Checkbox / Selectable / SmallButton / InvisibleButton "klikniety".
local ffi = require 'ffi'
local F = { clickAll = false, frames = {}, inits = {} }

local function vec(x, y) return { x = x or 0, y = y or 0 } end
local num = setmetatable({}, { __index = function(t, k) local v = 1; rawset(t, k, v); return v end })
local drawList = setmetatable({}, { __index = function() return function() end end })

local im = {
    ImVec2 = vec,
    ImVec4 = function(x, y, z, w) return { x = x, y = y, z = z, w = w } end,
    Col = num, StyleVar = num, Cond = num, WindowFlags = num,
    InputTextFlags = setmetatable({ Password = 0x8000, EnterReturnsTrue = 0x20 }, { __index = function() return 0 end }),
    new = {
        bool = function(v) local b = ffi.new('bool[1]'); b[0] = v and true or false; return b end,
        int = function(v) local b = ffi.new('int[1]'); b[0] = v or 0; return b end,
        float = function(v) local b = ffi.new('float[1]'); b[0] = v or 0; return b end,
        char = setmetatable({}, { __index = function(_, n) return function() return ffi.new('char[?]', n) end end }),
    },
    OnInitialize = function(fn) F.inits[#F.inits + 1] = fn end,
    OnFrame = function(cond, fn) F.frames[#F.frames + 1] = { cond = cond, fn = fn } end,
    GetStyle = function() return { Colors = {} } end,
    GetIO = function() return { WantCaptureMouse = false } end,
    GetMousePos = function() return vec() end,
    GetCursorScreenPos = function() return vec() end,
    GetWindowPos = function() return vec() end,
    GetItemRectMin = function() return vec() end,
    GetItemRectMax = function() return vec(10, 10) end,
    CalcTextSize = function(s) return vec(#tostring(s) * 7, 14) end,
    GetWindowWidth = function() return 760 end,
    GetCursorPosX = function() return 0 end,
    GetWindowDrawList = function() return drawList end,
    IsMouseDown = function() return false end,
    IsItemHovered = function() return false end,
    IsItemActive = function() return false end,
    IsItemDeactivatedAfterEdit = function() return F.clickAll end,
    Begin = function() return true end,
    BeginChild = function() return true end,
    Button = function() return F.clickAll end,
    SmallButton = function() return F.clickAll end,
    InvisibleButton = function() return false end,  -- zakladki / zamkniecie okna: przelaczane recznie w tescie
    Selectable = function() return F.clickAll end,
    Checkbox = function(_, b) if F.clickAll then b[0] = not b[0]; return true end return false end,
    SliderInt = function() return F.clickAll end,
    SliderFloat = function() return F.clickAll end,
    InputText = function() return F.clickAll end,
    InputTextWithHint = function() return F.clickAll end,
}
setmetatable(im, { __index = function() return function() return false end end })
F.im = im
return F
