-- SHODAN Stat Editor Offline: the game's data files (data/game/generated_*.dl_bin).
-- A file is a NaCl sealed box (X25519 + XSalsa20-Poly1305) of a run of LDLD blocks: the settings tables the game
-- loads into memory at start. game.dll holds the seeded murmur64 of every file's plain text, so an edited file
-- must keep its hash: reserved block-header bytes (+17..+23, zero in the game's own files) are solved for it.
local ffi = require('ffi')
local bit = require('bit')

ffi.cdef [[
int sodium_init(void);
int crypto_box_seal(unsigned char *c, const unsigned char *m, unsigned long long mlen, const unsigned char *pk);
int crypto_box_seal_open(unsigned char *m, const unsigned char *c, unsigned long long clen,
                         const unsigned char *pk, const unsigned char *sk);
void *VirtualAlloc(void *address, size_t size, uint32_t type, uint32_t protect);
int VirtualFree(void *address, size_t size, uint32_t type);
void *memcpy(void *dst, const void *src, size_t n);
int memcmp(const void *a, const void *b, size_t n);
]]

local M = {}
local here = (debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or '')
local sodium
for _, at in ipairs({ here .. 'runtime/libsodium.dll', here .. 'libsodium.dll', here .. '../libsodium.dll', 'libsodium.dll' }) do
    local ok, lib = pcall(ffi.load, at)
    if ok then sodium = lib; break end
end
assert(sodium, 'libsodium.dll not found')
assert(sodium.sodium_init() >= 0, 'libsodium did not start')

local function unhex(h) return (h:gsub('%x%x', function(c) return string.char(tonumber(c, 16)) end)) end
local PK = unhex('2dc9aa7c30e6eed5f7fd0e0e95c7287299b126f79520cc41de750982ee7ff50c')
local SK = unhex('a0296b81310b58f013d8a9b343a1c292008003dfd9ab15fcf351543048b49b64')
local SEALBYTES = 48
M.SEALBYTES = SEALBYTES

local MUL = 0xC6A4A7935BD1E995ULL
local INV = 0x5F7A0EA7E59B19BDULL   -- MUL^-1 mod 2^64
local SEED = 16045690983977655786ULL
assert(MUL * INV == 1ULL, 'inverse')
local u64p = ffi.typeof('uint64_t *')
local u8p = ffi.typeof('uint8_t *')

-- ---------------------------------------------------------------- buffers (VirtualAlloc: page aligned, private)
local MEM_COMMIT_RESERVE, MEM_RELEASE, PAGE_READWRITE = 0x3000, 0x8000, 0x04
function M.alloc(size)
    local p = ffi.C.VirtualAlloc(nil, math.max(size, 1), MEM_COMMIT_RESERVE, PAGE_READWRITE)
    assert(p ~= nil, 'out of memory (' .. size .. ' bytes)')
    return ffi.cast(u8p, p)
end
function M.free(p) if p ~= nil then ffi.C.VirtualFree(p, 0, MEM_RELEASE) end end

function M.read_file(path)
    local f = io.open(path, 'rb')
    if not f then return nil, 'cannot open ' .. path end
    local s = f:read('*a'); f:close()
    return s
end

-- ---------------------------------------------------------------- crypto
-- the plain text of a sealed file, in a new buffer (never a Lua string: a string copy of the tables in memory
-- would be found by Stat Editor's table scan as a second copy)
function M.open_sealed(cipher)
    local n = #cipher - SEALBYTES
    if n < 0 then return nil, 'too short' end
    local p = M.alloc(n)
    if sodium.crypto_box_seal_open(p, cipher, #cipher, PK, SK) ~= 0 then M.free(p); return nil, 'not a game data file' end
    return p, n
end
function M.seal(p, n)
    local c = ffi.new('uint8_t[?]', n + SEALBYTES)
    assert(sodium.crypto_box_seal(c, p, n, PK) == 0, 'seal failed')
    return ffi.string(c, n + SEALBYTES)
end

-- ---------------------------------------------------------------- murmur64 (seeded, 64-bit words)
local function mix(v) v = v * MUL; v = bit.bxor(v, bit.rshift(v, 47)); return v * MUL end
local function unmix(v) v = v * INV; v = bit.bxor(v, bit.rshift(v, 47)); return v * INV end
M.mix, M.unmix = mix, unmix

-- the state after hashing the words at [a, b) (a, b multiples of 8)
local function forward(h, p, a, b)
    local w = ffi.cast(u64p, p)
    for i = a / 8, b / 8 - 1 do
        local v = w[i] * MUL; v = bit.bxor(v, bit.rshift(v, 47)); v = v * MUL
        h = bit.bxor(h, v) * MUL
    end
    return h
end
-- the state before the words at [a, b), given the state after them
local function backward(h, p, a, b)
    local w = ffi.cast(u64p, p)
    for i = b / 8 - 1, a / 8, -1 do h = bit.bxor(h * INV, mix(w[i])) end
    return h
end
local function tail_word(p, n)
    local t, whole = 0ULL, n - n % 8
    for i = n - 1, whole, -1 do t = bit.bor(bit.lshift(t, 8), p[i] + 0ULL) end
    return t, whole
end
function M.murmur64(p, n)
    local h = bit.bxor(SEED, (n + 0ULL) * MUL)
    local t, whole = tail_word(p, n)
    h = forward(h, p, 0, whole)
    if whole < n then h = bit.bxor(h, t) * MUL end
    h = bit.bxor(h, bit.rshift(h, 47)); h = h * MUL; h = bit.bxor(h, bit.rshift(h, 47))
    return h
end
-- the state right after the last whole word, for a final hash `target`
local function before_final(target, p, n)
    local h = target
    h = bit.bxor(h, bit.rshift(h, 47)); h = h * INV; h = bit.bxor(h, bit.rshift(h, 47))
    local t, whole = tail_word(p, n)
    if whole < n then h = bit.bxor(h * INV, t) end
    return h, whole
end
function M.hex64(v) return (string.format('%016x', v):gsub('ULL', '')) end
local function le64(v)
    local s = {}
    for i = 0, 7 do s[i + 1] = string.char(tonumber(bit.band(bit.rshift(v, i * 8), 0xFF))) end
    return table.concat(s)
end
M.le64 = le64

-- ---------------------------------------------------------------- blocks
local NEEDLE = 'LDLD\1\0\0\0'
local function u32(p, o) return ffi.cast('uint32_t *', p + o)[0] end
M.u32 = u32
-- every block: { at = header offset, type, size }; the payload is at at + 24
function M.headers(p, n)
    local out, at = {}, nil
    for i = 0, math.min(n, 64) - 8 do
        if ffi.string(p + i, 8) == NEEDLE then at = i; break end
    end
    while at and at + 24 <= n do
        local typ, size = u32(p, at + 8), u32(p, at + 12)
        out[#out + 1] = { at = at, type = typ, size = size }
        local nxt = at + 24 + size
        at = nil
        for i = nxt, math.min(n, nxt + 64) - 8 do   -- blocks follow back to back (or after a little padding)
            if ffi.string(p + i, 8) == NEEDLE then at = i; break end
        end
    end
    return out
end
-- a game original: every header's reserved bytes zero (edited files carry a hash correction there)
function M.pristine(p, n)
    for _, h in ipairs(M.headers(p, n)) do
        if p[h.at + 16] ~= 1 then return false end
        for k = 17, 23 do if p[h.at + k] ~= 0 then return false end end
    end
    return true
end

-- ---------------------------------------------------------------- hash correction
-- Solve: header X (X % 8 == 0): word X+16 = flag 0x01 + 7 free bytes -> one unmix per salt, 1 in 256 fit.
--        header X (X % 8 == 4): word X+12 = size, flag, 3 free bytes; word X+20 = 4 free bytes, 4 payload bytes
--        -> 2^24 tries per salt, 1 in 256 salts fit.
-- Salt: the reserved bytes +17, +18 of another header; for a file with one header, the lowest 12 mantissa bits of
-- an edited float (a change of at most 4095 units in the last place, under 0.05 %).
local function solve_aligned(p, X, h_before, after)
    local m = bit.bxor(after * INV, h_before)
    local w = unmix(m)
    if bit.band(w, 0xFF) == 1ULL then
        ffi.cast(u64p, p + X + 16)[0] = w
        return true
    end
end
local function solve_unaligned(p, X, h_before, after)
    local w12p, w20p = ffi.cast(u64p, p + X + 12), ffi.cast(u64p, p + X + 20)
    local fixed12 = bit.band(w12p[0], 0xFFFFFFFFFFULL)
    local hi20 = bit.rshift(w20p[0], 32)
    local need = after * INV
    for t = 0, 0xFFFFFF do
        local w12 = bit.bor(fixed12, bit.lshift(t + 0ULL, 40))
        local v = w12 * MUL; v = bit.bxor(v, bit.rshift(v, 47)); v = v * MUL
        local m20 = bit.bxor(bit.bxor(h_before, v) * MUL, need)
        local u = m20 * INV; u = bit.bxor(u, bit.rshift(u, 47)); u = u * INV
        if bit.rshift(u, 32) == hi20 then
            w12p[0] = w12; w20p[0] = u
            return true
        end
    end
end

-- salt slots: offsets of single bytes that may take any value 1..255
local function salt_slots(p, n, hs, X, edited_floats)
    local slots = {}
    for _, h in ipairs(hs) do
        if h.at ~= X then slots[#slots + 1] = { h.at + 17, h.at + 18 } end
    end
    for _, o in ipairs(edited_floats or {}) do slots[#slots + 1] = { o, float = true } end
    -- nearest to the solved words first: every try re-hashes the bytes between the salt and them
    table.sort(slots, function(a, b) return math.abs(a[1] - X) < math.abs(b[1] - X) end)
    return slots
end

-- the native search (shodan_hash.dll, every core) for a header at an offset % 8 == 4; without it the Lua loop
local native = nil
pcall(ffi.cdef, [[int shodan_solve_unaligned(const uint64_t *before, const uint64_t *need, int salts,
                                             uint64_t fixed12, uint64_t high20, uint64_t *w12, uint64_t *w20);]])
for _, at in ipairs({ here .. 'launcher/shodan_hash.dll', here .. 'shodan_hash.dll', here .. '../shodan_hash.dll' }) do
    local ok, lib = pcall(ffi.load, at)
    if ok then native = lib; break end
end
M.native = native ~= nil
local BATCH = 256   -- salts per native search (about one answer expected among them)

-- corrects p[0, n) in place to hash `target`; `edited_floats`: offsets of f32 values the caller changed
function M.correct(p, n, target, edited_floats, log)
    log = log or function() end
    local hs = M.headers(p, n)
    if #hs == 0 then return nil, 'no blocks' end
    for _, h in ipairs(hs) do
        if p[h.at + 16] ~= 1 then return nil, 'header flag is not 1' end
        for k = 17, 23 do if p[h.at + k] ~= 0 then return nil, 'reserved header bytes are not zero' end end
    end
    if M.murmur64(p, n) == target then return true end
    local final, whole = before_final(target, p, n)
    -- correction header: the last aligned one if any (one unmix per salt), else the last header
    local X, aligned = nil, false
    for i = #hs, 1, -1 do if hs[i].at % 8 == 0 and hs[i].at > 0 then X, aligned = hs[i].at, true; break end end
    if not X then X = hs[#hs].at end
    local words_end = aligned and X + 24 or X + 28   -- the words the solver writes end here
    local slots = salt_slots(p, n, hs, X, edited_floats)
    if #slots == 0 then return nil, 'nothing to vary for the hash: this file has one block, so a decimal' ..
                                       ' value in it must change too (a projectile\'s Caliber, for one)' end
    local solve = aligned and solve_aligned or solve_unaligned
    local first = aligned and X + 16 or X + 12      -- the first solved word
    local start = bit.bxor(SEED, (n + 0ULL) * MUL)
    local batch = not aligned and native and { before = ffi.new('uint64_t[?]', BATCH), need = ffi.new('uint64_t[?]', BATCH),
                                               w12 = ffi.new('uint64_t[1]'), w20 = ffi.new('uint64_t[1]') }
    for _, slot in ipairs(slots) do
        local lo = slot[1] - slot[1] % 8
        local hi = slot.float and lo + 8 or (slot[#slot] - slot[#slot] % 8) + 8
        local fp = slot.float and ffi.cast('uint32_t *', p + slot[1])
        local orig = {}
        if fp then orig[1] = fp[0] else for i, o in ipairs(slot) do orig[i] = p[o] end end
        local before_slot, after_slot
        if hi <= first then
            before_slot = forward(start, p, 0, lo)                      -- salt before the solved words
            after_slot = backward(final, p, words_end, whole)
        else
            before_slot = forward(start, p, 0, first)                   -- salt after them (edited float)
            after_slot = backward(final, p, hi, whole)
        end
        local function put(salt)
            if fp then fp[0] = bit.bxor(orig[1], salt)
            else p[slot[1]] = bit.band(salt, 255); p[slot[2]] = bit.rshift(salt, 8) end
        end
        local function restore() if fp then fp[0] = orig[1] else for i, o in ipairs(slot) do p[o] = orig[i] end end end
        -- the hash states around the solved words with a salt in place
        local function states()
            if hi <= first then return forward(before_slot, p, lo, first), after_slot end
            return before_slot, backward(after_slot, p, words_end, hi)
        end
        local function found(salt)
            if M.murmur64(p, n) ~= target then error('hash correction did not verify') end
            log(string.format('hash corrected (salt %d at %#x, header %#x)', salt, slot[1], X))
            if fp then log(string.format('the float at %#x differs from the value asked for by %d units in the last place', slot[1], salt)) end
            return true
        end
        -- a float: its lowest 12 mantissa bits (at most 4095 units in the last place, under 0.05 %)
        local tries = fp and 4095 or 65535
        if batch then
            local w12p, w20p = ffi.cast(u64p, p + X + 12), ffi.cast(u64p, p + X + 20)
            local fixed12, high20 = bit.band(w12p[0], 0xFFFFFFFFFFULL), bit.rshift(w20p[0], 32)
            local salt = 1
            while salt <= tries do
                local count = math.min(BATCH, tries - salt + 1)
                for k = 0, count - 1 do
                    put(salt + k)
                    local h_before, after = states()
                    batch.before[k], batch.need[k] = h_before, after * INV
                end
                local k = native.shodan_solve_unaligned(batch.before, batch.need, count, fixed12, high20, batch.w12, batch.w20)
                if k >= 0 then
                    put(salt + k)
                    w12p[0], w20p[0] = batch.w12[0], batch.w20[0]
                    return found(salt + k)
                end
                salt = salt + count
                log(string.format('hash correction: %d tries', salt - 1))
            end
        else
            for salt = 1, tries do
                put(salt)
                if solve(p, X, states()) then return found(salt) end
                if salt % 32 == 0 then log(string.format('hash correction: %d tries', salt)) end
            end
        end
        restore()
    end
    return nil, 'no hash correction found'
end

-- ---------------------------------------------------------------- game files
function M.game_dll_has(dll, hash) return dll:find(le64(hash), 1, true) ~= nil end

return M
