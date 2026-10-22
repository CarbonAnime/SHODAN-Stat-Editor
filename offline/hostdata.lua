-- SHODAN Stat Editor Offline: the game's data files as the game holds them in memory.
-- Every data file is decrypted into its own allocation (high in the address space, like the game's), so Stat
-- Editor's table scan finds the tables as it does in game. The game turns a table's stored offsets into
-- addresses when it loads it; the host does the same for the fields Stat Editor follows, and links each
-- destruction level to its demolition tier (stored unlinked). Those fields always go back as they were stored.
-- Install: per file, the bytes Stat Editor changed go into the original plain text, the hash is corrected, the
-- file is sealed, read back and checked.
local ffi = require('ffi')
local bit = require('bit')
local G = require('gamedata')

-- (VirtualAlloc, VirtualFree and memcmp are declared by gamedata.lua)
local MEM_COMMIT_RESERVE_TOP, PAGE_READWRITE, MEM_RELEASE = 0x103000, 0x04, 0x8000

local M = { files = {}, log = print }
local u64p = ffi.typeof('uint64_t *')
local NONE = 0xFFFFFFFFFFFFFFFFULL

local function u32(p, o) return ffi.cast('uint32_t *', p + o)[0] end
local function addr(p) return ffi.cast('uint64_t', ffi.cast('uintptr_t', p)) end

-- ---------------------------------------------------------------- the fields the game resolves at load
-- per table type: function(payload pointer, size, rel) calling rel(offset) for each stored offset Stat Editor
-- follows (payload-relative u64; 0 and -1 are none)
local RELOC = {
    [0x683E604F] = function(P, size, rel) for k = 0, 4 do rel(k * 16) end end,                -- attachment deltas
    [0x63CE0FEB] = function(P, size, rel)                                                     -- armor passive
        if u32(P, 24) > 0 then rel(16) end
        if u32(P, 40) > 0 then rel(32) end
    end,
    [0x49795156] = function(P, size, rel) rel(0) end,                                         -- destruction map
    [0xFB45E243] = function(P, size, rel) rel(0) end,                                         -- demolition tiers
    [0xD6A11545] = function(P, size, rel) rel(0) end,                                         -- destruction settings
    [0x1E604234] = function(P, size, rel)                                                     -- attachment items
        rel(0)
        for r = 0, u32(P, 8) - 1 do rel(16 + r * 88); rel(16 + r * 88 + 48) end
    end,
    [0x30EB6399] = function(P, size, rel)                                                     -- stratagems
        rel(0)
        for r = 0, u32(P, 8) - 1 do rel(16 + r * 400 + 16); rel(16 + r * 400 + 152) end
    end,
}

-- ---------------------------------------------------------------- loading
local function read(path)
    local f = io.open(path, 'rb')
    if not f then return nil end
    local s = f:read('*a'); f:close()
    return s
end

-- `cipher`: the original sealed file. The plain text goes into a top-down allocation.
local function place(name, cipher)
    local n = #cipher - G.SEALBYTES
    local p = ffi.cast('uint8_t *', ffi.C.VirtualAlloc(nil, math.max(n, 1), MEM_COMMIT_RESERVE_TOP, PAGE_READWRITE))
    assert(p ~= nil, 'out of memory for ' .. name)
    local tmp, m = G.open_sealed(cipher)
    if not tmp then ffi.C.VirtualFree(p, 0, MEM_RELEASE); return nil, m end
    ffi.copy(p, tmp, n)
    G.free(tmp)
    return p, n
end

-- folder: data/game; originals: name -> sealed original (from the backups, else the game folder)
function M.load(folder, originals)
    local dll = assert(read(folder .. '/game.dll'), 'game.dll not found in ' .. folder)
    local problems = {}
    for name, cipher in pairs(originals) do
        local p, n = place(name, cipher)
        if not p then
            problems[#problems + 1] = name .. ': ' .. tostring(n)
        else
            local hash = G.murmur64(p, n)
            if not G.game_dll_has(dll, hash) then
                problems[#problems + 1] = name .. ': not the version this game expects'
                ffi.C.VirtualFree(p, 0, MEM_RELEASE)
            elseif #G.headers(p, n) > 0 and not G.pristine(p, n) then
                problems[#problems + 1] = name .. ': changed by another tool'
                ffi.C.VirtualFree(p, 0, MEM_RELEASE)
            else
                M.files[name] = { name = name, p = p, n = n, hash = hash, cipher = cipher, fields = {} }
            end
        end
    end
    M.relocate()
    return problems
end

function M.relocate()
    local tiers = {}   -- demolition tier type -> its template's address
    for _, f in pairs(M.files) do
        for _, h in ipairs(G.headers(f.p, f.n)) do
            local P, size = f.p + h.at + 24, h.size
            local fn = RELOC[h.type]
            if fn then
                fn(P, size, function(o)
                    if o + 8 > size then return end
                    local v = ffi.cast(u64p, P + o)[0]
                    if v ~= 0 and v ~= NONE and v < size then
                        ffi.cast(u64p, P + o)[0] = addr(P) + v
                        f.fields[#f.fields + 1] = h.at + 24 + o
                    end
                end)
            end
            if h.type == 0xFB45E243 and u32(P, 8) > 0 then
                for k = 0, u32(P, 8) - 1 do tiers[u32(P, 16 + k * 16)] = addr(P) + 16 + k * 16 end
            end
        end
    end
    for _, f in pairs(M.files) do
        for _, h in ipairs(G.headers(f.p, f.n)) do
            if h.type == 0xD6A11545 and h.size >= 144 then
                local P = f.p + h.at + 24
                for level = 0, 2 do
                    for _, o in ipairs({ 16, 32 }) do
                        local at = level * 48 + o
                        local t = tiers[u32(P, at + 8)]
                        if t and ffi.cast(u64p, P + at)[0] == NONE then
                            ffi.cast(u64p, P + at)[0] = t
                            f.fields[#f.fields + 1] = h.at + 24 + at
                        end
                    end
                end
            end
        end
    end
    for _, f in pairs(M.files) do
        f.resolved = {}
        for _, o in ipairs(f.fields) do for k = 0, 7 do f.resolved[o + k] = true end end
    end
end

-- ---------------------------------------------------------------- what changed
-- a float read off a pointer: a plain read never answers nil, but a scan that reaches a buffer the
-- engine moves under it can, and one nil must not stop the whole install: no value is no candidate
local function float_at(p, o)
    local v = ffi.cast('float *', p + o)[0]
    if v == nil then return nil end
    v = tonumber(v)
    if v == nil or v ~= v then return nil end
    return v
end
-- a value with decimals, between 1e-4 and 1e7: what a hash correction can move by a few units in the
-- last place
local function decimal(p, o)
    local v = float_at(p, o)
    return v ~= nil and math.abs(v) >= 1e-4 and math.abs(v) < 1e7 and u32(p, o) >= 0x38D1B717
end

-- a record of whole numbers may hold a word that only looks like a float: the fields around it tell - a value
-- this editor may move sits with other values with decimals (velocity, mass, drag), an id or a count does not
local function crowded(p, n, at, blocked, resolved)
    local around = 0
    for k = -32, 32, 4 do
        local o = at + k
        if k ~= 0 and o >= 0 and o + 4 <= n and not blocked[o] and not (resolved and resolved[o]) then
            local v = decimal(p, o) and float_at(p, o)
            if v and math.abs(v) >= 1e-3 then around = around + 1 end
        end
    end
    return around >= 2
end

-- A file of one block has no spare header bytes to vary, so a change with no decimal value in it leaves the hash
-- correction nothing to work with: borrow the nearest decimal value of the same record (a projectile's Caliber,
-- its Drag...) and the correction moves it by under 0.05 %. `words`: the 4-byte words that changed.
local function borrowing(f, p, n, words)
    if type(p) ~= 'cdata' then return {} end
    local blocked = {}
    for _, h in ipairs(G.headers(p, n)) do for o = h.at, h.at + 23 do blocked[o] = true end end
    local starts = {}
    for o in pairs(words) do
        blocked[o] = true
        starts[#starts + 1] = o
    end
    table.sort(starts)
    local out, seen = {}, {}
    for step = 4, 1024, 4 do
        for _, base in ipairs(starts) do
            for _, at in ipairs({ base + step, base - step }) do
                at = at - at % 4
                if at >= 0 and at + 4 <= n and not seen[at] then
                    seen[at] = true
                    local free = true
                    for k = at, at + 3 do
                        if blocked[k] or (f.resolved and f.resolved[k]) then free = false; break end
                    end
                    local v = free and decimal(p, at) and float_at(p, at)
                    if v and math.abs(v) >= 1e-3
                       and crowded(p, n, at, blocked, f.resolved) then
                        out[#out + 1] = at
                        if #out >= 6 then return out end
                    end
                end
            end
        end
    end
    return out
end

-- the plain text to install for a file (a new buffer) and the offsets of changed f32-looking words, or nil when
-- nothing changed. Resolved fields keep their stored bytes. `borrowed`: the decimal values lent to the hash
-- correction when nothing with decimals changed (see borrowing): the install says so.
local function changes(f)
    local orig, n = G.open_sealed(f.cipher)
    local changed, words = 0, {}
    local a, b = ffi.cast('uint64_t *', f.p), ffi.cast('uint64_t *', orig)
    for w = 0, math.floor(n / 8) - 1 do
        if a[w] ~= b[w] then
            for k = w * 8, w * 8 + 7 do
                if f.p[k] ~= orig[k] and not f.resolved[k] then
                    orig[k] = f.p[k]
                    changed = changed + 1
                    words[k - k % 4] = true
                end
            end
        end
    end
    for k = n - n % 8, n - 1 do
        if f.p[k] ~= orig[k] and not f.resolved[k] then orig[k] = f.p[k]; changed = changed + 1; words[k - k % 4] = true end
    end
    if changed == 0 then G.free(orig); return nil end
    -- floats among the changed words (a salt for one-table files): a value with decimals between 1e-4 and 1e7
    local floats = {}
    for o in pairs(words) do
        local v = float_at(orig, o)
        local i = u32(orig, o)
        if v and math.abs(v) >= 1e-4 and math.abs(v) < 1e7 and i >= 0x38D1B717 then floats[#floats + 1] = o end
    end
    table.sort(floats)
    local borrowed
    if #floats == 0 then
        local ok, list = pcall(borrowing, f, orig, n, words)
        floats = ok and list or {}
        borrowed = #floats > 0 and floats or nil
    end
    return orig, n, changed, floats, borrowed
end

-- every file whose plain text differs from its original: { name, plain, n, bytes, floats, borrowed, hash }
-- and the files that could not be read at all ({ name, why }): one unreadable file must not stop the rest
function M.diff()
    local out, problems = {}, {}
    for name, f in pairs(M.files) do
        local read, plain, n, count, floats, borrowed = pcall(changes, f)
        if not read then
            problems[#problems + 1] = { name = name, why = tostring(plain) }
        elseif plain then
            out[#out + 1] = { name = name, plain = plain, n = n, bytes = count, floats = floats,
                              borrowed = borrowed, hash = f.hash }
        end
    end
    table.sort(out, function(x, y) return x.name < y.name end)
    table.sort(problems, function(x, y) return x.name < y.name end)
    return out, problems
end

-- seal one changed file: { name, sealed } or nil, why
function M.build(change, log)
    local called, ok, why = pcall(G.correct, change.plain, change.n, change.hash, change.floats, log)
    if not called then G.free(change.plain); return nil, tostring(ok) end
    if not ok then G.free(change.plain); return nil, why end
    local sealed_at, sealed = pcall(G.seal, change.plain, change.n)
    if not sealed_at then G.free(change.plain); return nil, tostring(sealed) end
    local back, m = G.open_sealed(sealed)
    local good = back and m == change.n and ffi.C.memcmp(back, change.plain, m) == 0 and G.murmur64(back, m) == change.hash
    if back then G.free(back) end
    G.free(change.plain)
    if not good then return nil, 'read-back check failed' end
    return sealed
end

return M
