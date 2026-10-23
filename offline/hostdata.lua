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

-- a file's plain text to build on: another mod's version loses only its hash correction (the game checks the
-- hash, so a mod's file carries one too), this editor's own goes in its place
local function open_base(cipher)
    local p, n = G.open_sealed(cipher)
    if p then G.clear_correction(p, n) end
    return p, n
end

M.modded = {}   -- name -> true: a file another mod changed (built on, its changes kept)

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
            else
                if G.clear_correction(p, n) then M.modded[name] = true end
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

-- A file of one block has no spare header bytes to vary, so a change with no decimal value in it (an explosion
-- id, a count) leaves the hash correction nothing to work with: borrow the nearest decimal value of the same
-- record (a projectile's Caliber, its Drag...) and the correction moves it by under 0.05 %. `words`: the 4-byte
-- words that changed. No candidate: the table grows instead (see M.build).
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
                    if v and math.abs(v) >= 1e-3 and crowded(p, n, at, blocked, f.resolved) then
                        out[#out + 1] = at
                        if #out >= 6 then return out end
                    end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------- what changed
-- the plain text to install for a file (a new buffer) and the offsets of changed f32-looking words, or nil when
-- nothing changed. Resolved fields keep their stored bytes.
local function changes(f)
    local orig, n = open_base(f.cipher)
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
    -- nothing with decimals changed: borrow the nearest one of the same record, so a whole-number change can
    -- still be installed (see borrowing)
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

-- ---------------------------------------------------------------- passive stacking
-- Every armor with passive T also gets passive S's modifiers and weapon stat modifiers (their values as edited):
-- they are appended to T's block (payload: 56 bytes, the modifiers at +56, 16 bytes each, then the weapon stat
-- modifiers, 12 bytes each), so the file grows; the hash correction works at any length.
-- stacks: target passive id -> { source passive id, ... }; own_off: passive id -> true: its own modifiers left out
-- (only the stacked ones; none: the passive does nothing); policy: passive id -> 'stack' | 'strongest' (one value
-- per effect, the strongest, as the Armory Forge mod does). Adds to / changes `changes` (from M.diff) in place.
local PASSIVE = 0x63CE0FEB
-- a 32-bit word and a float32 read out of a byte string (Lua 5.1 has no string.unpack)
local u32buf = ffi.new('uint32_t[1]')
local f32buf = ffi.cast('float *', u32buf)
local function u32s(b, at)
    local a1, a2, a3, a4 = b:byte(at, at + 3)
    return a1 + a2 * 256 + a3 * 65536 + a4 * 16777216
end
local function f32s(b, at)
    u32buf[0] = u32s(b, at)
    return f32buf[0]
end

-- the rows of a record's arrays: { id, type, value, bytes, hex } (16-byte modifiers: id, type, value, text;
-- 12-byte weapon stat modifiers: id, a float, the value)
local function split_rows(s, width)
    local out = {}
    for at = 1, #s - width + 1, width do
        local b = s:sub(at, at + width - 1)
        local b1, b2, b3, b4 = b:byte(1, 4)
        out[#out + 1] = { id = b:sub(1, 4), type = width == 16 and u32s(b, 5) or 2, value = f32s(b, 9),
                          bytes = b, hex = string.format('%08X', ((b4 * 256 + b3) * 256 + b2) * 256 + b1) }
    end
    return out
end

-- how strong an effect's value is: a factor counts by how far it is from 1, an amount by its size
local function strength(typ, v)
    if typ == 2 then
        if v <= 0 then return math.huge end
        return math.abs(math.log(v))
    end
    return math.abs(v)
end

-- one effect may arrive from several passives, and the game applies an id once (Engineering Kit + Integrated
-- Explosives: +2 grenades, not +4); the armory's preview of a passive holding an id twice crashes the game
-- (issue #66). So one row per id survives: 'stack' keeps the first of differing values (the passive's own rows
-- come first), 'strongest' the strongest of them (as the Armory Forge mod does). The rows left out go to `dropped`.
local function collapse(rows, policy)
    local order, groups = {}, {}
    for _, r in ipairs(rows) do
        local g = groups[r.id]
        if not g then g = {}; groups[r.id] = g; order[#order + 1] = r.id end
        local dup = false
        for _, u in ipairs(g) do if u.value == r.value then dup = true; break end end
        if not dup then g[#g + 1] = r end
    end
    local out, dropped = {}, {}
    for _, id in ipairs(order) do
        local g = groups[id]
        local keep = g[1]
        if policy == 'strongest' then
            for i = 2, #g do
                if strength(g[i].type, g[i].value) > strength(keep.type, keep.value) then keep = g[i] end
            end
        end
        for _, r in ipairs(g) do if r ~= keep then dropped[#dropped + 1] = r.hex end end
        out[#out + 1] = keep
    end
    return out, dropped
end

-- the record's own rows, then the stacked ones: an id already there is written once; a copied modifier's
-- description id points into the other passive's text, so it is cleared (the effect stays)
local function append_unique(existing, rows, width)
    local seen, out = {}, {}
    for at = 1, #existing - width + 1, width do
        local b = existing:sub(at, at + width - 1)
        seen[b:sub(1, 4)] = true
        out[#out + 1] = b
    end
    for _, r in ipairs(rows) do
        local b = width == 16 and r.bytes:sub(1, 12) .. '\0\0\0\0' or r.bytes
        if not seen[b:sub(1, 4)] then seen[b:sub(1, 4)] = true; out[#out + 1] = b end
    end
    return table.concat(out)
end

-- The armory's preview of a passive lists at most 3 described modifiers (no native passive has more; a 4th crashes
-- the game, issue #74): past the 3rd, a modifier keeps its effect but loses its description id (+12). The ids
-- that lose it go to `hidden`.
local MAX_DESCRIBED = 3
local function cap_descriptions(mods, hidden)
    local out, shown = {}, 0
    for o = 1, #mods, 16 do
        local m = mods:sub(o, o + 15)
        if m:sub(13, 16) ~= '\0\0\0\0' then
            shown = shown + 1
            if shown > MAX_DESCRIBED then
                local b1, b2, b3, b4 = m:byte(1, 4)
                hidden[#hidden + 1] = string.format('%08X', ((b4 * 256 + b3) * 256 + b2) * 256 + b1)
                m = m:sub(1, 12) .. '\0\0\0\0'
            end
        end
        out[#out + 1] = m
    end
    return table.concat(out)
end

function M.stack(changes, stacks, log, own_off, policy)
    log, stacks, own_off, policy = log or function() end, stacks or {}, own_off or {}, policy or {}
    local any = next(own_off) ~= nil
    for _, list in pairs(stacks) do if #list > 0 then any = true end end
    if not any then return true end
    local f
    for _, file in pairs(M.files) do
        for _, h in ipairs(G.headers(file.p, file.n)) do if h.type == PASSIVE then f = file; break end end
        if f then break end
    end
    if not f then return nil, 'the armor passive file is not loaded' end
    local c
    for _, x in ipairs(changes) do if x.name == f.name then c = x end end
    if not c then
        local plain, n = open_base(f.cipher)
        if not plain then return nil, f.name .. ': ' .. tostring(n) end
        c = { name = f.name, plain = plain, n = n, bytes = 0, floats = {}, hash = f.hash }
        changes[#changes + 1] = c
        table.sort(changes, function(x, y) return x.name < y.name end)
    end
    local p, n = c.plain, c.n
    local hs = G.headers(p, n)
    -- every passive's modifiers and weapon stat modifiers, as edited (before any grows)
    local blocks = {}
    for _, h in ipairs(hs) do
        if h.type == PASSIVE and h.size >= 56 then
            local P = h.at + 24
            local mc, sc = u32(p, P + 24), u32(p, P + 40)
            local mo = mc > 0 and tonumber(ffi.cast(u64p, p + P + 16)[0]) or 56
            local so = sc > 0 and tonumber(ffi.cast(u64p, p + P + 32)[0]) or 56 + mc * 16
            if mo == 56 and so == 56 + mc * 16 and h.size == so + sc * 12 then
                blocks[u32(p, P)] = { mods = ffi.string(p + P + 56, mc * 16), stats = ffi.string(p + P + so, sc * 12) }
            end
        end
    end
    local out, done = { ffi.string(p, hs[1].at) }, 0
    for k, h in ipairs(hs) do
        local P = h.at + 24
        local id = h.type == PASSIVE and h.size >= 56 and u32(p, P)
        local own, list = id and blocks[id], id and stacks[id]
        local mods, stats, names = '', '', {}
        if own and not own_off[id] then mods, stats = own.mods, own.stats end
        local add_m, add_s = {}, {}
        for _, s in ipairs(own and list or {}) do
            if s ~= id and blocks[s] then
                for _, r in ipairs(split_rows(blocks[s].mods, 16)) do add_m[#add_m + 1] = r end
                for _, r in ipairs(split_rows(blocks[s].stats, 12)) do add_s[#add_s + 1] = r end
                names[#names + 1] = tostring(s)
            elseif s ~= id then
                log('passive ' .. s .. ' (stacked on ' .. id .. ') is not in this game file: left out')
            end
        end
        local pol = policy[id] or 'stack'
        local rows_m, dropped_m = collapse(add_m, pol)
        local rows_s, dropped_s = collapse(add_s, pol)
        mods, stats = append_unique(mods, rows_m, 16), append_unique(stats, rows_s, 12)
        if #dropped_m > 0 then
            log('passive ' .. id .. ': modifier ' .. table.concat(dropped_m, ', ') .. ' left out, it is applied once (' ..
                pol .. ')')
        end
        if #dropped_s > 0 then
            log('passive ' .. id .. ': weapon stat modifier ' .. table.concat(dropped_s, ', ') .. ' left out, it is' ..
                ' applied once (' .. pol .. ')')
        end
        local block_end = k < #hs and hs[k + 1].at or n
        if #names > 0 then
            local hidden = {}
            mods = cap_descriptions(mods, hidden)
            if #hidden > 0 then
                log('passive ' .. id .. ': modifier ' .. table.concat(hidden, ', ') .. ' not described in the armory' ..
                    ' (it lists ' .. MAX_DESCRIBED .. ' at most), still applied')
            end
        end
        if #names > 0 or (own and own_off[id]) then
            local head = ffi.new('uint8_t[80]')
            ffi.copy(head, p + h.at, 80)
            local payload = head + 24
            local mc, sc = #mods / 16, #stats / 12
            ffi.cast('uint32_t *', head + 12)[0] = 56 + #mods + #stats                           -- block size
            ffi.cast(u64p, payload + 16)[0] = mc > 0 and 56 or NONE
            ffi.cast('uint32_t *', payload + 24)[0] = mc
            ffi.cast(u64p, payload + 32)[0] = sc > 0 and 56 + #mods or NONE
            ffi.cast('uint32_t *', payload + 40)[0] = sc
            out[#out + 1] = ffi.string(head, 80) .. mods .. stats
            out[#out + 1] = ffi.string(p + P + h.size, block_end - P - h.size)                   -- any padding after
            log(string.format('passive %d: %s, stacked %s (%d modifiers, %d weapon stat modifiers, %s)', id,
                own_off[id] and 'own effects off' or 'own effects on',
                #names > 0 and table.concat(names, ', ') or 'none', mc, sc, pol))
            done = done + 1
        else
            out[#out + 1] = ffi.string(p + h.at, block_end - h.at)
        end
    end
    if done == 0 then return true end
    local s = table.concat(out)
    local grown = G.alloc(#s)
    ffi.copy(grown, s, #s)
    G.free(c.plain)
    -- the edited floats moved: the other headers' reserved bytes salt the hash correction
    c.plain, c.n, c.bytes, c.floats = grown, #s, c.bytes + #s - n, {}
    return true
end

-- the passive ids this game's file holds: the Armory page's "all armor" profile applies to those without one
function M.passives()
    local f
    for _, file in pairs(M.files) do
        for _, h in ipairs(G.headers(file.p, file.n)) do if h.type == PASSIVE then f = file; break end end
        if f then break end
    end
    local ids = {}
    if not f then return ids end
    for _, h in ipairs(G.headers(f.p, f.n)) do
        if h.type == PASSIVE and h.size >= 56 then ids[#ids + 1] = u32(f.p, h.at + 24) end
    end
    table.sort(ids)
    return ids
end

-- seal one changed file: { name, sealed } or nil, why
function M.build(change, log)
    log = log or function() end
    -- a one-table file whose changes hold no float to vary (whole numbers, zeros): nothing in it may vary for the
    -- hash correction, so its table grows by 16 zero bytes after everything it holds (the game reads only what
    -- its offsets name; grown tables load, as stacked passives do), and those vary instead
    local hs = G.headers(change.plain, change.n)
    if #change.floats == 0 and #hs == 1 and hs[1].at + 24 + hs[1].size == change.n then
        local n = change.n
        local salt = n + (8 - n % 8) % 8                -- a word of its own (the native search needs the words whole)
        local grown = G.alloc(salt + 16)               -- (zeroed)
        ffi.copy(grown, change.plain, n)
        ffi.cast('uint32_t *', grown + hs[1].at + 12)[0] = salt + 16 - hs[1].at - 24
        G.free(change.plain)
        change.plain, change.n, change.floats = grown, salt + 16, { salt }
        log(string.format('no float among the changes: the table grows by %d bytes for the hash correction', salt + 16 - n))
    end
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
