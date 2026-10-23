#!/usr/bin/env python3
r"""SHODAN Stat Editor - MCP server: the game's own data tables, read and edited by an AI.

The editor's panel (src/stat_editor.lua) is a GUI for the tables in the game's data\game\generated_*.dl_bin
files. This server exposes the same files to an AI client over the Model Context Protocol (stdio): it finds the
game, opens the sealed tables, names their records (weapons, projectiles, explosions, ...), and writes values
back the way the panel does - keeping the murmur64 hash game.dll expects for each file.

Nothing here is new data: every offset is the one the panel uses, and a change is written to the same table
record the panel would write. Standard library only; libsodium.dll and (for one kind of hash correction)
shodan_hash.dll are the two native pieces, both shipped with the editor.

    python stat_editor_mcp.py                      MCP server on stdin/stdout
    python stat_editor_mcp.py status --json        the same information from a shell
    python stat_editor_mcp.py weapon "AC-8 Autocannon"
    python stat_editor_mcp.py set "GL-21 Grenade Launcher" impact_explosion 0 --save
    python stat_editor_mcp.py selftest             checks against the game's own files (no writes)

The files are only written by "save" (the save tool), which is a dry run unless dry_run is false, and keeps
the game's originals in %LOCALAPPDATA%\SHODAN\StatEditor\originals the way the launcher does.
"""
import ctypes
import hashlib
import json
import os
import re
import struct
import sys
import time

# ------------------------------------------------------------------ game data format

PK = bytes.fromhex('2dc9aa7c30e6eed5f7fd0e0e95c7287299b126f79520cc41de750982ee7ff50c')
SK = bytes.fromhex('a0296b81310b58f013d8a9b343a1c292008003dfd9ab15fcf351543048b49b64')
SEALBYTES = 48

MUL = 0xC6A4A7935BD1E995
INV = 0x5F7A0EA7E59B19BD          # MUL^-1 mod 2^64
SEED = 16045690983977655786
MASK = (1 << 64) - 1


def _mix(v):
    v = (v * MUL) & MASK
    v ^= v >> 47
    return (v * MUL) & MASK


def _unmix(v):
    v = (v * INV) & MASK
    v ^= v >> 47
    return (v * INV) & MASK


def murmur64(buf, start=0, end=None):
    """The hash game.dll keeps for a file's plain text (offline/gamedata.lua's M.murmur64)."""
    end = len(buf) if end is None else end
    n = end - start
    h = (SEED ^ ((n * MUL) & MASK)) & MASK
    whole = start + n - n % 8
    for o in range(start, whole, 8):
        h = ((h ^ _mix(struct.unpack_from('<Q', buf, o)[0])) * MUL) & MASK
    if whole < end:
        t = 0
        for i in range(end - 1, whole - 1, -1):
            t = ((t << 8) | buf[i]) & MASK
        h = ((h ^ t) * MUL) & MASK
    h ^= h >> 47
    h = (h * MUL) & MASK
    return h ^ (h >> 47)


def _forward(h, buf, a, b):
    for o in range(a, b, 8):
        h = ((h ^ _mix(struct.unpack_from('<Q', buf, o)[0])) * MUL) & MASK
    return h


def _backward(h, buf, a, b):
    for o in range(b - 8, a - 8, -8):
        h = (h * INV & MASK) ^ _mix(struct.unpack_from('<Q', buf, o)[0])
    return h


def _tail_word(buf, n):
    whole = n - n % 8
    t = 0
    for i in range(n - 1, whole - 1, -1):
        t = ((t << 8) | buf[i]) & MASK
    return t, whole


NEEDLE = b'LDLD\x01\x00\x00\x00'


def block_headers(buf):
    """[(header offset, type hash, payload size)] - payload at header + 24."""
    out = []
    at = buf.find(NEEDLE, 0, min(len(buf), 64))
    while at >= 0 and at + 24 <= len(buf):
        typ, size = struct.unpack_from('<II', buf, at + 8)
        out.append((at, typ, size))
        nxt = at + 24 + size
        at = buf.find(NEEDLE, nxt, min(len(buf), nxt + 64))
    return out


def pristine(buf):
    for at, _typ, _size in block_headers(buf):
        if buf[at + 16] != 1 or any(buf[at + 17:at + 24]):
            return False
    return True


# ------------------------------------------------------------------ libsodium

class Sodium:
    """crypto_box_seal / crypto_box_seal_open out of the libsodium.dll the editor ships."""

    def __init__(self, search):
        self.lib = None
        self.path = None
        errors = []
        for at in search:
            if not at:
                continue
            try:
                lib = ctypes.CDLL(at)
            except OSError as why:
                errors.append('%s: %s' % (at, why))
                continue
            self.lib, self.path = lib, at
            break
        if not self.lib:
            raise RuntimeError('libsodium.dll not found (looked at: %s)' % '; '.join(errors or search))
        self.lib.sodium_init.restype = ctypes.c_int
        self.lib.crypto_box_seal.restype = ctypes.c_int
        self.lib.crypto_box_seal.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong, ctypes.c_void_p]
        self.lib.crypto_box_seal_open.restype = ctypes.c_int
        self.lib.crypto_box_seal_open.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong,
                                                  ctypes.c_void_p, ctypes.c_void_p]
        if self.lib.sodium_init() < 0:
            raise RuntimeError('libsodium did not start')

    def open_sealed(self, cipher):
        n = len(cipher) - SEALBYTES
        if n < 0:
            raise ValueError('too short for a sealed file')
        out = ctypes.create_string_buffer(n)
        if self.lib.crypto_box_seal_open(out, cipher, len(cipher), PK, SK) != 0:
            raise ValueError('not a game data file')
        return bytearray(out.raw)

    def seal(self, plain):
        out = ctypes.create_string_buffer(len(plain) + SEALBYTES)
        if self.lib.crypto_box_seal(out, bytes(plain), len(plain), PK) != 0:
            raise RuntimeError('seal failed')
        return out.raw


# ------------------------------------------------------------------ where the game is

def exe_dir():
    return os.path.dirname(os.path.abspath(__file__))


def env(name):
    return os.environ.get(name)


def read_text(path):
    try:
        with open(path, 'rb') as handle:
            return handle.read().decode('utf-8', 'replace')
    except OSError:
        return None


def home_dir():
    return os.path.join(env('LOCALAPPDATA') or '.', 'SHODAN', 'StatEditor')


def game_at(root):
    r"""The data\game folder holding game.dll and the generated_* tables, from any nearby folder."""
    folder = root.replace('\\', '/').rstrip('/')
    for candidate in (folder, folder + '/data/game', folder + '/steamapps/common/Helldivers 2/data/game'):
        if (os.path.isfile(candidate + '/game.dll')
                and os.path.isfile(candidate + '/generated_entities.dl_bin')):
            return candidate.replace('/', os.sep)
    return None


def find_game(beside=None):
    """game folder.txt (the panel's), else Steam's libraries - the same order install.lua uses."""
    for path in (os.path.join(home_dir(), 'game folder.txt'),
                 os.path.join(beside, 'game folder.txt') if beside else None,
                 os.path.join(exe_dir(), 'game folder.txt')):
        if not path:
            continue
        text = read_text(path)
        line = text.strip() if text else ''
        if line:
            found = game_at(line)
            if found:
                return found, 'game folder.txt (%s)' % path
    roots = []
    steam = None
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Valve\Steam') as key:
            steam = winreg.QueryValueEx(key, 'SteamPath')[0]
    except OSError:
        steam = None
    if steam:
        roots.append(steam)
        vdf = read_text(os.path.join(steam, 'steamapps', 'libraryfolders.vdf')) or ''
        for path in re.findall(r'"path"\s+"([^"]+)"', vdf):
            roots.append(path.replace('\\\\', '\\'))
    roots.append(r'C:\Program Files (x86)\Steam')
    for root in roots:
        found = game_at(root)
        if found:
            return found, 'steam library (%s)' % root
    return None, 'no game folder found (write it into %s)' % os.path.join(home_dir(), 'game folder.txt')


# ------------------------------------------------------------------ tables

# The type hashes and strides of the tables this server reads; they mirror KINDS in src/stat_editor.lua.
# type hash -> (name, stride, kind, alternate strides); 'keyed' = entity hash -> record, 'rows' = u32 id -> record.
TABLES = {
    0x88E4DBB1: ('weapon', 1232, 'keyed', (1240,)),          # WeaponDataComponent
    0x45171B68: ('fire mode', 616, 'keyed', ()),             # ProjectileWeaponComponent
    0xFB8D88A3: ('magazine', 160, 'keyed', ()),
    0x66081072: ('rounds', 136, 'keyed', ()),
    0x4C981CD9: ('weapon heat', 592, 'keyed', ()),
    0xBD4042C2: ('projectile', 272, 'rows', ()),
    0xE0A72CF0: ('damage', 76, 'rows', ()),
    0x2AEA2592: ('explosion', 152, 'rows', ()),              # strings and arrays after the rows
    0xC5085606: ('beam', 112, 'rows', ()),
    0xF0721C2C: ('beam weapon', 120, 'keyed', ()),
    0x991D454E: ('reload', 80, 'keyed', ()),
    0x84CE7EEE: ('wind-up', 36, 'keyed', ()),
    0x30EB6399: ('stratagem', 400, 'rows', ()),              # id at +4, strings after the rows
    0x1E604234: ('attachment items', 88, 'rows', ()),        # id at +8, groups
    0x7A858691: ('loadout package', 32, 'keyed', ()),
}

ROW_ID_AT = {0x30EB6399: 4, 0x1E604234: 8}
TAIL_TABLES = {0x2AEA2592, 0x30EB6399, 0x1E604234}


def _u32(buf, at):
    return struct.unpack_from('<I', buf, at)[0]


def _u64(buf, at):
    return struct.unpack_from('<Q', buf, at)[0]


def parse_keyed(payload, stride):
    """Keyed table -> (index, entries): 8 raw little-endian hash bytes -> record offset in the payload.

    Bucket array (u64 entity hash, u32 record index, u32 0) of twice as many buckets as entities, then
    fixed-stride records. Which bucket count fits is found the way the panel finds it: the count where every
    key sits where the game looks it up (hash % buckets, then up to the first empty bucket).
    """
    total = len(payload)
    count = live = 0
    top = -1
    offset = 0
    candidates, twice = [], []
    while offset + 16 <= total:
        slot, pad = _u32(payload, offset + 8), _u32(payload, offset + 12)
        if pad != 0 or slot > 100000:
            break
        count += 1
        if _u32(payload, offset) or _u32(payload, offset + 4):
            live += 1
            if slot > top:
                top = slot
        offset += 16
        array = total - count * 16
        if count <= 2 * live and array > 0 and array % stride == 0:
            records = array // stride
            if top < records <= live + 2:
                candidates.append(count)
                if count == 2 * live:
                    twice.append(count)
    if not candidates:
        return None, 0

    def empty(k):
        return _u32(payload, k * 16) == 0 and _u32(payload, k * 16 + 4) == 0

    def placed(buckets):
        wrap = (1 << 32) % buckets
        for k in range(buckets):
            if empty(k):
                continue
            at = ((_u32(payload, k * 16 + 4) % buckets) * wrap + _u32(payload, k * 16)) % buckets
            while at != k:
                if empty(at):
                    return False
                at = (at + 1) % buckets
        return True

    fits = [n for n in candidates if placed(n)]
    if len(fits) != 1:
        fits = twice
    if len(fits) != 1:
        return None, 0
    buckets = fits[0]
    index = {}
    entries = 0
    for k in range(buckets):
        key = bytes(payload[k * 16:k * 16 + 8])
        if key != b'\0' * 8 and key not in index:
            index[key] = buckets * 16 + _u32(payload, k * 16 + 8) * stride
            entries += 1
    return index, entries


def parse_rows(payload, stride, id_at=0, tail=False):
    """Row table -> (index, rows): u32 id -> record offset in the payload."""
    rows = _u32(payload, 8)
    size = 16 + rows * stride
    if _u32(payload, 12) != 0 or not (size == len(payload) or (tail and size <= len(payload))):
        return None, 0
    index = {}
    for row in range(rows):
        at = 16 + row * stride
        index[_u32(payload, at + id_at)] = at
    return index, rows


class Table:
    """One LDLD block: its payload, its stride, and its records by key or id."""

    def __init__(self, name, type_hash, file_name, at, size, payload):
        self.name = name
        self.type_hash = type_hash
        self.file = file_name
        self.at = at
        self.size = size
        self.payload = payload
        self.stride = None
        self.mode = None
        self.index = None
        self.entries = 0
        self.note = ''

    def __repr__(self):
        return '<Table %s %#010x %s stride %s entries %d>' % (
            self.name, self.type_hash, self.mode, self.stride, self.entries)

    def record(self, key_or_id):
        if self.index is None:
            return None
        if self.mode == 'keyed':
            key = key_or_id
            if isinstance(key, int):
                key = struct.pack('<Q', key)
            return self.index.get(key)
        return self.index.get(key_or_id)

    def read(self, offset, kind):
        if offset is None:
            return None
        if kind == 'f32':
            return struct.unpack_from('<f', self.payload, offset)[0]
        if kind == 'i32':
            return struct.unpack_from('<i', self.payload, offset)[0]
        if kind == 'u8':
            return self.payload[offset]
        if kind == 'u64':
            return _u64(self.payload, offset)
        return _u32(self.payload, offset)

    def write(self, offset, kind, value):
        if kind == 'f32':
            struct.pack_into('<f', self.payload, offset, float(value))
        elif kind == 'i32':
            struct.pack_into('<i', self.payload, offset, int(value))
        elif kind == 'u8':
            self.payload[offset] = int(value) & 0xFF
        elif kind == 'u64':
            struct.pack_into('<Q', self.payload, offset, int(value) & MASK)
        else:
            struct.pack_into('<I', self.payload, offset, int(value) & 0xFFFFFFFF)

# ------------------------------------------------------------------ the fields worth naming

# stat -> (offset in the record, kind). Offsets are the ones the panel's field_at() uses.
FIELDS = {
    'weapon': {
        'recoil_h_start': (0, 'f32'), 'recoil_h_end': (4, 'f32'),
        'recoil_v_start': (28, 'f32'), 'recoil_v_end': (32, 'f32'),
        'spread': (84, 'f32'), 'spread_aim': (88, 'f32'),
        'sway': (104, 'f32'), 'aim_block_length': (108, 'f32'),
        'suppressed': (112, 'u8'), 'aim_zoom': (116, 'f32'), 'scope_sway': (128, 'f32'),
        'noise': (132, 'u8'), 'burst': (140, 'u32'), 'fire_mode': (144, 'u32'),
        'ergonomics': (356, 'f32'), 'crosshair': (400, 'u32'),
    },
    'fire mode': {
        'projectile': (0, 'u32'),
        'rpm_x': (4, 'f32'), 'rpm': (8, 'f32'), 'rpm_z': (12, 'f32'),
        'zeroing_slots': (16, 'u32'), 'zeroing_hipfire': (28, 'f32'),
        'projectile_entity': (40, 'u64'), 'spinup': (144, 'f32'),
    },
    'magazine': {
        'capacity': (136, 'u32'), 'magazines': (140, 'u32'), 'refill': (144, 'u32'),
        'max_magazines': (148, 'u32'), 'reload_threshold': (152, 'f32'), 'chambered': (156, 'u8'),
    },
    'reload': {'reload_time': (56, 'f32')},
    'weapon heat': {
        'overheat_temperature': (96, 'f32'), 'warning_temperature': (104, 'f32'),
        'emission_temperature': (108, 'f32'), 'heat_per_shot': (116, 'f32'),
        'cooling': (128, 'f32'), 'cooling_overheated': (132, 'f32'),
        'firing_charge': (148, 'f32'), 'charge_gain': (152, 'f32'), 'charge_loss': (156, 'f32'),
        'reset_charge': (160, 'u8'),
    },
    'projectile': {
        'calibre': (24, 'f32'), 'pellets': (28, 'u32'), 'speed': (32, 'f32'), 'mass': (36, 'f32'),
        'drag': (40, 'f32'), 'gravity': (44, 'f32'), 'lifetime': (56, 'f32'),
        'damage_id': (60, 'u32'), 'pen_slowdown': (64, 'f32'),
        'impact_explosion': (144, 'u32'), 'expiry_explosion': (156, 'u32'),
    },
    'damage': {
        'damage': (4, 'i32'), 'durable': (8, 'i32'),
        'ap_direct': (12, 'u32'), 'ap_slight': (16, 'u32'), 'ap_large': (20, 'u32'),
        'ap_extreme': (24, 'u32'), 'demolition': (28, 'u32'), 'stagger': (32, 'u32'),
        'push': (36, 'u32'), 'element': (40, 'u32'),
    },
    'explosion': {
        'damage_id': (4, 'u32'), 'inner_radius': (16, 'f32'), 'outer_radius': (20, 'f32'),
        'shockwave': (24, 'f32'), 'fragments': (80, 'u32'), 'fragment_projectile': (84, 'u32'),
        'arc': (120, 'u32'),
    },
}

# float fields to nudge (by a few units in the last place) when a file has no spare header byte to salt with
SALT_PREFERENCE = ('drag', 'pen_slowdown', 'gravity', 'mass', 'speed', 'lifetime', 'calibre',
                   'shake', 'spread', 'sway')

# Tables a weapon is resolved through: the panel reads each of these by the weapon's entity hash.
WEAPON_TABLES = ('weapon', 'fire mode', 'magazine', 'rounds', 'reload', 'wind-up', 'weapon heat',
                 'beam weapon')


# ------------------------------------------------------------------ hash correction

def forward(h, buf, a, b):
    """The hash state after the words in [a, b) (byte offsets, multiples of 8)."""
    return _forward(h, buf, a, b)


def backward(h, buf, a, b):
    """The hash state before the words in [a, b), given the state after them."""
    return _backward(h, buf, a, b)


def before_final(target, buf):
    h = target
    h = (h ^ (h >> 47)) & MASK
    h = h * INV & MASK
    h = (h ^ (h >> 47)) & MASK
    whole = len(buf) - len(buf) % 8
    if whole < len(buf):
        h = ((h * INV) & MASK) ^ _tail_word(buf, len(buf))[0]
    return h & MASK, whole


class HashSolver:
    """The panel's hash correction: keep the file's murmur64 by spending the reserved header bytes.

    Every block header has 1 at +16 and zeroes at +17..+23; the game only checks the file hash, so the
    solver rewrites those free bytes (and, for the two-byte-header case, the last block's size/flag word)
    until the plain text hashes back to what game.dll holds.
    """

    def __init__(self, dll=None):
        self.dll = dll
        self.native = None
        if dll:
            self.native = ctypes.WinDLL(dll)
            self.native.shodan_solve_unaligned.restype = ctypes.c_int
            self.native.shodan_solve_unaligned.argtypes = [
                ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64), ctypes.c_int,
                ctypes.c_uint64, ctypes.c_uint64,
                ctypes.POINTER(ctypes.c_uint64), ctypes.POINTER(ctypes.c_uint64)]

    def solve_aligned(self, buf, x, h_before, after):
        w = _unmix(((after * INV) & MASK) ^ h_before)
        if w & 0xFF == 1:
            struct.pack_into('<Q', buf, x + 16, w)
            return True
        return False

    def solve_unaligned(self, buf, x, h_before, after):
        fixed12 = _u64(buf, x + 12) & 0xFFFFFFFFFF
        high20 = _u64(buf, x + 20) >> 32
        need = (after * INV) & MASK
        for t in range(0x1000000):
            w12 = fixed12 | (t << 40)
            v = _mix(w12)
            m20 = (((h_before ^ v) * MUL & MASK) ^ need)
            u = _unmix(m20)
            if u >> 32 == high20:
                struct.pack_into('<Q', buf, x + 12, w12)
                struct.pack_into('<Q', buf, x + 20, u)
                return True
        return False

    def solve_batch(self, before, need, fixed12, high20):
        count = len(before)
        arr_b = (ctypes.c_uint64 * count)(*before)
        arr_n = (ctypes.c_uint64 * count)(*need)
        w12 = ctypes.c_uint64(0)
        w20 = ctypes.c_uint64(0)
        found = self.native.shodan_solve_unaligned(arr_b, arr_n, count, fixed12, high20,
                                                  ctypes.byref(w12), ctypes.byref(w20))
        if found < 0:
            return None
        return found, w12.value, w20.value

    def correct(self, buf, target, edited_floats=(), log=None):
        """Make murmur64(buf) == target in place. Returns (ok, message)."""
        headers = block_headers(buf)
        if not headers:
            return False, 'no blocks'
        for header in headers:
            if buf[header[0] + 16] != 1:
                return False, 'header flag at %#x is not 1' % header[0]
            for k in range(17, 24):
                if buf[header[0] + k]:
                    return False, 'reserved header bytes at %#x are not zero' % header[0]
        if murmur64(buf) == target:
            return True, 'the hash already matches'
        final, whole = before_final(target, buf)
        x, aligned = None, False
        for header in reversed(headers):
            if header[0] % 8 == 0 and header[0] > 0:
                x, aligned = header[0], True
                break
        if x is None:
            x = headers[-1][0]
        words_end = x + 24 if aligned else x + 28
        # slots: the two reserved bytes of every other header, then the low mantissa bits of edited floats
        slots = []
        for header in headers:
            if header[0] != x:
                slots.append((header[0] + 17, header[0] + 18, False))
        for offset in edited_floats or ():
            slots.append((offset, None, True))
        slots.sort(key=lambda s: abs(s[0] - x))
        if not slots:
            return False, 'nothing to vary for the hash (edit a value with decimals in this file)'
        first = x + 16 if aligned else x + 12
        start = (SEED ^ (len(buf) * MUL)) & MASK
        for lo_byte, hi_byte, is_float in slots:
            lo = lo_byte - lo_byte % 8
            hi = lo + 8 if is_float else (hi_byte - hi_byte % 8) + 8
            if is_float:
                orig = bytes(buf[lo_byte:lo_byte + 4])
            else:
                orig = (buf[lo_byte], buf[hi_byte])
            if hi <= first:
                before_slot = forward(start, buf, 0, lo)
                after_slot = backward(final, buf, words_end, whole)
            else:
                before_slot = forward(start, buf, 0, first)
                after_slot = backward(final, buf, hi, whole)

            def put(salt):
                if is_float:
                    value = struct.unpack('<I', orig)[0] ^ salt
                    struct.pack_into('<I', buf, lo_byte, value)
                else:
                    buf[lo_byte] = salt & 0xFF
                    buf[hi_byte] = (salt >> 8) & 0xFF

            def restore():
                if is_float:
                    buf[lo_byte:lo_byte + 4] = orig
                else:
                    buf[lo_byte], buf[hi_byte] = orig

            def states():
                if hi <= first:
                    return forward(before_slot, buf, lo, first), after_slot
                return before_slot, backward(after_slot, buf, words_end, hi)

            tries = 4095 if is_float else 65535
            batch_size = 256 if (self.native and not aligned) else 0
            salt = 1
            while salt <= tries:
                if batch_size:
                    count = min(batch_size, tries - salt + 1)
                    befores, needs = [], []
                    for k in range(count):
                        put(salt + k)
                        h_before, after = states()
                        befores.append(h_before)
                        needs.append((after * INV) & MASK)
                    fixed12 = _u64(buf, x + 12) & 0xFFFFFFFFFF
                    high20 = _u64(buf, x + 20) >> 32
                    answer = self.solve_batch(befores, needs, fixed12, high20)
                    if answer:
                        which, w12_value, w20_value = answer
                        put(salt + which)
                        struct.pack_into('<Q', buf, x + 12, w12_value)
                        struct.pack_into('<Q', buf, x + 20, w20_value)
                        if murmur64(buf) != target:
                            return False, 'hash correction did not verify'
                        if log:
                            log('hash corrected (salt %d at %#x, header %#x)' % (salt, lo_byte, x))
                        return True, 'corrected with salt %d' % salt
                    salt += count
                else:
                    put(salt)
                    solved = (self.solve_aligned(buf, x, *states()) if aligned
                              else self.solve_unaligned(buf, x, *states()))
                    if solved:
                        if murmur64(buf) != target:
                            return False, 'hash correction did not verify'
                        if log:
                            log('hash corrected (salt %d at %#x, header %#x)' % (salt, lo_byte, x))
                        return True, 'corrected with salt %d' % salt
                    salt += 1
            restore()
        return False, 'no hash correction found'


def find_hash_dll():
    """shodan_hash.dll, from the environment or beside the release / this file."""
    for name in ('SHODAN_HASH_DLL', 'STAT_EDITOR_HASHDLL'):
        path = env(name)
        if path and os.path.isfile(path):
            return path
    for name in ('SHODAN_NATIVE_DIR', 'SHODAN_EDITOR_DIR'):
        path = env(name)
        if path and os.path.isfile(os.path.join(path, 'shodan_hash.dll')):
            return os.path.join(path, 'shodan_hash.dll')
    here = exe_dir()
    seen = []
    for base in (here, os.path.dirname(here), os.path.dirname(os.path.dirname(here)),
                 os.path.join(os.path.dirname(os.path.dirname(here)), 'launcher')):
        path = os.path.join(base, 'shodan_hash.dll')
        seen.append(path)
        if os.path.isfile(path):
            return path
    return None

# ------------------------------------------------------------------ the game

def hex64(value):
    return '%016x' % value


def hash_key(value):
    """The 8 key bytes of a weapon's 16 hex digit hash (the panel's hash_key: low u32 first)."""
    if isinstance(value, (bytes, bytearray)):
        return bytes(value)
    if isinstance(value, int):
        return struct.pack('<Q', value)
    text = str(value).strip().lower()
    if text.startswith('0x'):
        text = text[2:]
    text = text.replace(':', '').replace(' ', '')
    if len(text) != 16:
        raise ValueError('%r is not a 16 hex digit entity hash' % value)
    return struct.pack('<Q', int(text, 16))


def zero_reserved(plain):
    """Clear the hash correction the panel (or an earlier save) left in the block headers."""
    for at, _typ, _size in block_headers(plain):
        plain[at + 16] = 1
        plain[at + 17:at + 24] = b'\0' * 7


def game_running():
    """True while helldivers2.exe runs - writing to its open files is refused."""
    try:
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    except OSError:
        return False

    class Entry(ctypes.Structure):
        _fields_ = [('size', ctypes.c_ulong), ('usage', ctypes.c_ulong),
                    ('pid', ctypes.c_ulong), ('heap', ctypes.c_void_p), ('module', ctypes.c_ulong),
                    ('threads', ctypes.c_ulong), ('parent', ctypes.c_ulong), ('priority', ctypes.c_long),
                    ('flags', ctypes.c_ulong), ('exe', ctypes.c_wchar * 260)]

    snapshot = kernel.CreateToolhelp32Snapshot(2, 0)   # TH32CS_SNAPPROCESS
    if snapshot in (None, -1) or snapshot == ctypes.c_void_p(-1).value:
        return False
    entry = Entry()
    entry.size = ctypes.sizeof(entry)
    running = False
    try:
        more = kernel.Process32FirstW(ctypes.c_void_p(snapshot), ctypes.byref(entry))
        while more:
            if entry.exe.lower() == 'helldivers2.exe':
                running = True
                break
            more = kernel.Process32NextW(ctypes.c_void_p(snapshot), ctypes.byref(entry))
    finally:
        kernel.CloseHandle(ctypes.c_void_p(snapshot))
    return running


def load_list():
    """installed.txt: name -> {cipher hash} for the files an install wrote (the launcher's format)."""
    out = {}
    text = read_text(os.path.join(home_dir(), 'installed.txt')) or ''
    for line in re.split(r'[\r\n]+', text):
        match = re.match(r'^(\S+)\s+([0-9a-fA-F]+)$', line)
        if match:
            out.setdefault(match.group(1), set()).add(match.group(2).lower())
    return out


def save_list(listing):
    folder = home_dir()
    os.makedirs(folder, exist_ok=True)
    lines = sorted('%s %s' % (name, h) for name, hashes in listing.items() for h in hashes)
    with open(os.path.join(folder, 'installed.txt'), 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(''.join(line + '\n' for line in lines))


class Loaded:
    r"""One decrypted data\game file: the cipher, the plain text, its hash, its blocks."""

    __slots__ = ('name', 'path', 'cipher', 'plain', 'hash', 'baseline', 'in_game_dll')

    def __init__(self, name, path, cipher, plain):
        self.name = name
        self.path = path
        self.cipher = cipher
        self.plain = plain
        self.hash = murmur64(plain)
        self.baseline = bytes(plain)
        self.in_game_dll = False


class Game:
    r"""The game's tables: opened from data\game, edited in memory, written back on save()."""

    def __init__(self, folder=None, hash_dll=None, log=None):
        self.log = log or (lambda message: None)
        if folder:
            self.folder = game_at(folder) or folder
            self.found_by = 'the folder given'
        else:
            self.folder, self.found_by = find_game(exe_dir())
        if not self.folder or not os.path.isdir(self.folder):
            raise RuntimeError('no game folder (write it into %s or pass --game)' % home_dir())
        self.files = {}
        self.tables = []
        self.index = {}
        self.edits = []
        self.loaded = False
        self.dll_bytes = b''
        self.sodium = Sodium(self._native_search('libsodium.dll'))
        self.solver = HashSolver(hash_dll or find_hash_dll())

    def _native_search(self, name):
        here = exe_dir()
        bases = [env('SHODAN_NATIVE_DIR'), env('SHODAN_EDITOR_DIR'),
                 here, os.path.join(os.path.dirname(here), 'runtime'),
                 os.path.dirname(here), os.path.dirname(os.path.dirname(here)),
                 self.folder]
        return [os.path.join(base, name) for base in bases if base] + [name]

    # -------------------------------------------------------------- reading
    def load(self):
        with open(os.path.join(self.folder, 'game.dll'), 'rb') as handle:
            self.dll_bytes = handle.read()
        names = sorted(name for name in os.listdir(self.folder)
                       if name.startswith('generated_') and name.endswith('.dl_bin'))
        if not names:
            raise RuntimeError('no generated_*.dl_bin in %s' % self.folder)
        for name in names:
            path = os.path.join(self.folder, name)
            with open(path, 'rb') as handle:
                cipher = handle.read()
            plain = self.sodium.open_sealed(cipher)
            # the hash the game checks is the one the installed plain text has - correction bytes included
            entry = Loaded(name, path, cipher, plain)
            entry.in_game_dll = struct.pack('<Q', entry.hash) in self.dll_bytes
            zero_reserved(plain)
            entry.baseline = bytes(plain)
            self.files[name] = entry
            blocks = block_headers(entry.plain)
            for at, typ, size in blocks:
                spec = TABLES.get(typ)
                if not spec:
                    continue
                base = at + 24
                end = min(base + size, len(entry.plain))
                view = memoryview(entry.plain)[base:end]
                self._parse(Table(spec[0], typ, name, at, end - base, view), spec)
        self.loaded = True
        return self

    def _parse(self, table, spec):
        name, stride, mode, alt = spec
        if mode == 'keyed':
            for length in (stride,) + tuple(alt):
                index, entries = parse_keyed(table.payload, length)
                if index:
                    table.stride, table.mode, table.index, table.entries = length, 'keyed', index, entries
                    break
        else:
            index, rows = parse_rows(table.payload, stride, ROW_ID_AT.get(table.type_hash, 0),
                                     table.type_hash in TAIL_TABLES)
            if index:
                table.stride, table.mode, table.index, table.entries = stride, 'rows', index, rows
        if table.index is None:
            table.note = 'layout not recognized'
            return
        self.tables.append(table)
        self.index.setdefault(name, {})
        for key, offset in table.index.items():
            self.index[name].setdefault(key, (table, offset))

    def table(self, name):
        for table in self.tables:
            if table.name == name:
                return table
        return None

    def record(self, name, key):
        """(table, record offset) for a table name and an entity hash (bytes/int) or row id."""
        found = self.index.get(name, {})
        if found:
            entry = found.get(hash_key(key))
            if entry is not None:
                return entry
        return found.get(key)

    # -------------------------------------------------------------- values
    def stat(self, name, key, stat):
        fields = FIELDS.get(name, {})
        if stat not in fields:
            raise KeyError('%s has no field %r (known: %s)' % (name, stat, ', '.join(sorted(fields))))
        entry = self.record(name, key)
        if not entry:
            return None
        table, offset = entry
        return table.read(offset + fields[stat][0], fields[stat][1])

    def set_stat(self, name, key, stat, value):
        fields = FIELDS.get(name, {})
        if stat not in fields:
            raise KeyError('%s has no field %r (known: %s)' % (name, stat, ', '.join(sorted(fields))))
        entry = self.record(name, key)
        if not entry:
            raise KeyError('no %s record for %r' % (name, key))
        table, offset = entry
        field_offset, kind = fields[stat]
        before = table.read(offset + field_offset, kind)
        table.write(offset + field_offset, kind, value)
        after = table.read(offset + field_offset, kind)
        record = {'table': name, 'key': key if not isinstance(key, bytes) else key.hex(),
                  'stat': stat, 'kind': kind, 'before': before, 'after': after,
                  'file': table.file, 'abs': table.at + 24 + offset + field_offset,
                  'record_offset': offset}
        self.edits.append(record)
        return record

    def diff_offsets(self, entry):
        plain, baseline = entry.plain, entry.baseline
        return [i for i in range(len(plain)) if plain[i] != baseline[i]]

    def dirty(self):
        return [(name, entry) for name, entry in sorted(self.files.items())
                if entry.plain != entry.baseline]

    def edits_in(self, file_name):
        return [edit for edit in self.edits if edit['file'] == file_name]

    # -------------------------------------------------------------- writing
    def salt_candidates(self, name):
        """f32 offsets in the records this session edits: a file with one block has no spare header byte,
        so the hash correction takes one of these as its salt (a change of a few units in the last place,
        far below anything the game shows). Unchanged, non-zero, least visible fields come first."""
        out = []
        for edit in self.edits_in(name):
            table = self.table(edit['table'])
            if table is None or 'record_offset' not in edit:
                continue
            fields = FIELDS.get(table.name, {})
            for field, (offset, kind) in fields.items():
                if kind != 'f32' or field == edit['stat']:
                    continue
                at = table.at + 24 + edit['record_offset'] + offset
                value = table.read(edit['record_offset'] + offset, 'f32')
                rank = SALT_PREFERENCE.index(field) if field in SALT_PREFERENCE else len(SALT_PREFERENCE)
                out.append({'field': field, 'abs': at, 'value': value, 'edit': edit['stat'],
                            'rank': (0 if value not in (None, 0.0) else 1, rank, abs(at - table.at))})
        out.sort(key=lambda one: one['rank'])
        return out

    def save(self, dry_run=True, names=None):
        """Correct the hashes of the changed files and, unless dry_run, write them into the game."""
        report = {'folder': self.folder, 'dry_run': bool(dry_run), 'files': [], 'problems': []}
        dirty = [(name, entry) for name, entry in self.dirty() if not names or name in names]
        if not dirty:
            report['problems'].append('nothing changed: every file still matches what was loaded')
            return report
        staging = []
        for name, entry in dirty:
            floats = [edit['abs'] for edit in self.edits_in(name) if edit['kind'] == 'f32']
            candidates = [] if floats else self.salt_candidates(name)
            attempts = [floats] + ([[one['abs'] for one in candidates]] if candidates else [])
            info = {'name': name, 'changed_bytes': len(self.diff_offsets(entry)),
                    'want_hash': hex64(entry.hash), 'in_game_dll': entry.in_game_dll}
            ok, why, work, used = False, 'nothing tried', bytearray(entry.plain), []
            for attempt in attempts:
                work = bytearray(entry.plain)
                ok, why = self.solver.correct(work, entry.hash, attempt, self.log)
                if ok:
                    used = attempt
                    break
            info['correction'] = why
            if ok and not floats and used:
                info['nudged'] = [dict(one, before=one['value'],
                                       after=struct.unpack_from('<f', work, one['abs'])[0])
                                  for one in candidates if one['abs'] in used]
            if not ok:
                info['error'] = why
                report['problems'].append('%s: %s' % (name, why))
                report['files'].append(info)
                continue
            cipher = self.sodium.seal(work)
            info['sha256'] = hashlib.sha256(cipher).hexdigest()
            info['hash_kept'] = murmur64(work) == entry.hash
            info['round_trip'] = bytes(self.sodium.open_sealed(cipher)) == bytes(work)
            info['cipher_bytes'] = len(cipher)
            info['size_kept'] = len(cipher) == len(entry.cipher)
            report['files'].append(info)
            if info['hash_kept'] and info['round_trip'] and info['size_kept']:
                staging.append((name, entry, work, cipher))
            else:
                report['problems'].append('%s: the sealed file did not come back the same' % name)
        if dry_run:
            report['note'] = 'dry run: nothing was written (pass dry_run false to install)'
            return report
        if not staging:
            report['problems'].append('nothing safe to write')
            return report
        if game_running():
            report['problems'].append('Helldivers 2 is running: close it first')
            report['refused'] = True
            return report
        listing = load_list()
        originals = os.path.join(home_dir(), 'originals')
        os.makedirs(originals, exist_ok=True)
        # keep the game's own file before the first write, the way the launcher does
        for name, entry, _work, _cipher in staging:
            kept = os.path.join(originals, name)
            current = entry.cipher
            ours = name in listing and hex64(murmur64(current)) in listing[name]
            if not (ours and os.path.isfile(kept)):
                with open(kept, 'wb') as handle:
                    handle.write(current)
        written, failed = [], []
        for name, entry, work, cipher in staging:
            path = entry.path
            tmp = path + '.shodan-new'
            try:
                with open(tmp, 'wb') as handle:
                    handle.write(cipher)
                os.replace(tmp, path)
                with open(path, 'rb') as handle:
                    back = handle.read()
            except OSError as why:
                failed.append('%s: %s' % (name, why))
                try:
                    os.remove(tmp)
                except OSError:
                    pass
                continue
            if back != cipher:
                failed.append('%s: the file on disk is not what was written' % name)
                continue
            listing[name] = {hex64(murmur64(back))}
            entry.cipher = back
            entry.plain = work
            entry.baseline = bytes(work)
            written.append(name)
        save_list(listing)
        report['written'] = written
        report['problems'].extend(failed)
        report['note'] = ('wrote %d file(s); the originals are in %s' % (len(written), originals)
                          if written else 'nothing written')
        return report

    def restore(self, names=None, dry_run=False):
        """Put the game's own files back (the ones kept in %LOCALAPPDATA%\\SHODAN\\StatEditor\\originals)."""
        listing = load_list()
        originals = os.path.join(home_dir(), 'originals')
        report = {'dry_run': bool(dry_run), 'restored': [], 'problems': [], 'skipped': []}
        for name in sorted(listing):
            if names and name not in names:
                continue
            kept = os.path.join(originals, name)
            path = os.path.join(self.folder, name)
            if not os.path.isfile(kept):
                report['problems'].append('%s: no kept original' % name)
                continue
            current = b''
            if os.path.isfile(path):
                with open(path, 'rb') as handle:
                    current = handle.read()
            if hex64(murmur64(current)) not in listing[name]:
                report['skipped'].append('%s: not the file this tool wrote (an earlier install or the game)' % name)
                continue
            if dry_run:
                report['restored'].append(name)
                continue
            if game_running():
                report['problems'].append('Helldivers 2 is running: close it first')
                report['refused'] = True
                return report
            with open(kept, 'rb') as handle:
                original = handle.read()
            tmp = path + '.shodan-new'
            with open(tmp, 'wb') as handle:
                handle.write(original)
            os.replace(tmp, path)
            listing.pop(name, None)
            report['restored'].append(name)
        if not dry_run:
            save_list(listing)
        return report

    # -------------------------------------------------------------- checks
    def diff_report(self):
        out = []
        for name, entry in self.dirty():
            offsets = self.diff_offsets(entry)
            ranges = []
            for offset in offsets:
                if ranges and offset == ranges[-1][1] + 1:
                    ranges[-1][1] = offset
                else:
                    ranges.append([offset, offset])
            out.append({'name': name, 'changed_bytes': len(offsets),
                        'ranges': ['%#x-%#x' % (a, b) if a != b else '%#x' % a for a, b in ranges],
                        'edits': self.edits_in(name)})
        return out

    def verify(self):
        """Every file in the folder opens and still hashes to what game.dll holds."""
        out = {'folder': self.folder, 'files': [], 'problems': []}
        wanted = set()
        for entry in self.files.values():
            wanted.add(entry.hash)
        for name in sorted(self.files):
            entry = self.files[name]
            item = {'name': name, 'bytes': len(entry.cipher), 'hash': hex64(entry.hash),
                    'in_game_dll': entry.in_game_dll}
            try:
                plain = self.sodium.open_sealed(entry.cipher)
                item['hash_now'] = hex64(murmur64(plain))
                item['ok'] = murmur64(plain) == entry.hash
            except ValueError as why:
                item['ok'] = False
                item['error'] = str(why)
            if not item.get('ok'):
                out['problems'].append('%s does not hash to its own record' % name)
            out['files'].append(item)
        out['tables'] = [{'name': t.name, 'type': hex64(t.type_hash), 'stride': t.stride,
                          'entries': t.entries, 'kind': t.mode, 'file': t.file} for t in self.tables]
        return out

    # -------------------------------------------------------------- weapons
    def stats_of(self, name, key):
        if not self.record(name, key):
            return None
        return {stat: self.stat(name, key, stat) for stat in FIELDS.get(name, {})}

    def explosion_report(self, explosion_id):
        values = self.stats_of('explosion', explosion_id)
        if values is None:
            return {'id': explosion_id, 'note': 'not in this game build'}
        report = {'id': explosion_id}
        report.update(values)
        damage_id = values.get('damage_id')
        if damage_id is not None:
            report['damage'] = self.stats_of('damage', damage_id) or {}
        return report

    def weapon_report(self, key):
        key_bytes = hash_key(key)
        report = {'hash16': '%016X' % int.from_bytes(key_bytes, 'little'),
                  'hash': key_bytes.hex().upper()}
        for name in WEAPON_TABLES:
            values = self.stats_of(name, key_bytes)
            if values:
                report[name] = values
        projectile_id = report.get('fire mode', {}).get('projectile')
        if projectile_id is not None:
            report['projectile_id'] = projectile_id
            report['projectile'] = self.stats_of('projectile', projectile_id) or {}
            damage_id = report['projectile'].get('damage_id')
            if damage_id is not None:
                report['damage_id'] = damage_id
                report['damage'] = self.stats_of('damage', damage_id) or {}
            for which in ('impact_explosion', 'expiry_explosion'):
                explosion_id = report['projectile'].get(which)
                if explosion_id:
                    report[which] = self.explosion_report(explosion_id)
        return report

    def find_stat(self, key, stat):
        r"""(table name, record key) of a stat: the weapon's own tables first, then its projectile, that
        projectile's damage, and the explosions it sets off - the order get_weapon lists them in."""
        candidates = [(name, key) for name in WEAPON_TABLES]
        projectile_id = self.stat('fire mode', key, 'projectile')
        if projectile_id is not None:
            candidates.append(('projectile', projectile_id))
            damage_id = self.stat('projectile', projectile_id, 'damage_id')
            if damage_id is not None:
                candidates.append(('damage', damage_id))
            for which in ('impact_explosion', 'expiry_explosion'):
                explosion_id = self.stat('projectile', projectile_id, which)
                if explosion_id:
                    candidates.append(('explosion', explosion_id))
        for name, record_key in candidates:
            if stat in FIELDS.get(name, {}) and self.record(name, record_key):
                return name, record_key
        return None, None

    def set_named(self, key, stat, value):
        name, record_key = self.find_stat(key, stat)
        if not name:
            raise KeyError('no %r for this weapon (get_weapon lists the names it has)' % stat)
        return self.set_stat(name, record_key, stat, value)

    def set_explosion_id(self, key, which, explosion_id):
        stat = {'impact': 'impact_explosion', 'impact_explosion': 'impact_explosion',
                'expiry': 'expiry_explosion', 'expiry_explosion': 'expiry_explosion'}.get(which)
        if not stat:
            raise KeyError("which must be 'impact' or 'expiry'")
        explosion_id = int(explosion_id)
        if explosion_id and not self.record('explosion', explosion_id):
            raise KeyError('explosion %d is not in this game build' % explosion_id)
        projectile_id = self.stat('fire mode', key, 'projectile')
        if projectile_id is None:
            raise KeyError('this weapon has no projectile record (a beam or melee weapon?)')
        return self.set_stat('projectile', projectile_id, stat, explosion_id)

    def weapons(self):
        return CATALOG.weapons()

    def find_weapons(self, query):
        text = str(query or '').strip().lower()
        out = []
        for name, slot, hash16, note in self.weapons():
            if not text or text in name.lower() or text == hash16.lower() or text in note.lower():
                out.append({'name': name, 'slot': slot, 'hash16': hash16, 'note': note})
        return out

    def resolve_weapon(self, value):
        text = str(value).strip()
        compact = text.replace(':', '').replace(' ', '').upper()
        if re.fullmatch(r'[0-9A-F]{16}', compact):
            return hash_key(compact), compact
        for name, _slot, hash16, _note in self.weapons():
            if name.lower() == text.lower():
                return hash_key(hash16), hash16
        matches = [entry for entry in self.weapons() if text.lower() in entry[0].lower()]
        if len(matches) == 1:
            return hash_key(matches[0][2]), matches[0][2]
        if len(matches) > 1:
            raise KeyError('%r matches %d weapons: %s' % (
                text, len(matches), '; '.join(entry[0] for entry in matches[:8])))
        raise KeyError('%r is not in the panel weapon list; pass the 16 hex digit entity hash' % text)


class Catalog:
    """The panel's own weapon list, read out of src/stat_editor.lua."""

    PATTERN = re.compile(r"\{\s*'([^']*)'\s*,\s*'([^']*)'\s*,\s*'([0-9A-Fa-f]{16})'\s*(?:,\s*'([^']*)')?")

    def __init__(self, panel=None):
        self.path = panel or self.find_panel()
        self.entries = []
        if self.path:
            self.entries = self.parse(self.path)

    @staticmethod
    def find_panel():
        here = exe_dir()
        bases = [env('SHODAN_EDITOR_DIR'), os.path.dirname(os.path.dirname(here)),
                 os.path.dirname(os.path.dirname(os.path.dirname(here))), os.getcwd()]
        for base in bases:
            if not base:
                continue
            for rel in ('src/stat_editor.lua', 'app/stat_editor.lua', 'stat_editor.lua'):
                path = os.path.join(base, rel)
                if os.path.isfile(path):
                    return path
        return None

    def parse(self, path):
        entries, inside = [], False
        text = read_text(path) or ''
        for line in text.splitlines():
            if line.startswith('local WEAPONS'):
                inside = True
                continue
            if inside:
                if line.startswith('}'):
                    break
                match = self.PATTERN.search(line)
                if match:
                    entries.append((match.group(1), match.group(2), match.group(3).upper(),
                                    match.group(4) or ''))
        return entries

    def weapons(self):
        return self.entries


CATALOG = Catalog()


# ------------------------------------------------------------------ the MCP server

TOOLS = [
    {
        'name': 'game_status',
        'description': 'Where the game folder is, whether Helldivers 2 is running, how many tables were '
                       'opened, and what this session has changed but not saved.',
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        'annotations': {'readOnlyHint': True},
    },
    {
        'name': 'list_weapons',
        'description': 'The weapons the panel knows (name, slot, 16 hex digit entity hash), filtered by a '
                       'substring of the name or note. Use the hash with get_weapon or set_stat for weapons '
                       'that are not in the list (newer ones).',
        'inputSchema': {'type': 'object', 'properties': {
            'query': {'type': 'string', 'description': 'substring of a weapon name or note'},
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 500, 'default': 50},
            'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
        }, 'additionalProperties': False},
        'annotations': {'readOnlyHint': True},
    },
    {
        'name': 'get_weapon',
        'description': 'Every value this tool can read for one weapon: recoil, spread, sway, ergonomics, '
                       'fire mode, magazine, reload, heat or charge, its projectile (calibre, speed, mass, '
                       'drag), the damage record it hits with, and the explosions it sets off.',
        'inputSchema': {'type': 'object', 'properties': {
            'weapon': {'type': 'string', 'description': 'a name from list_weapons or a 16 hex digit hash'},
        }, 'required': ['weapon'], 'additionalProperties': False},
        'annotations': {'readOnlyHint': True},
    },
    {
        'name': 'list_explosions',
        'description': 'The explosion records in this build: id, damage, inner and outer radius, arc type, '
                       'and how many projectiles set each one off.',
        'inputSchema': {'type': 'object', 'properties': {
            'query': {'type': 'string', 'description': 'only ids whose damage or radius contains this text'},
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 500, 'default': 50},
            'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
        }, 'additionalProperties': False},
        'annotations': {'readOnlyHint': True},
    },
    {
        'name': 'set_stat',
        'description': 'Set one numbered field of a weapon (ergonomics, damage, durable, calibre, speed, '
                       'ap_direct, charge_gain, ...). The change stays in memory until save; save is a dry '
                       'run unless dry_run is false.',
        'inputSchema': {'type': 'object', 'properties': {
            'weapon': {'type': 'string'},
            'stat': {'type': 'string', 'description': 'get_weapon lists the names'},
            'value': {'type': 'number'},
        }, 'required': ['weapon', 'stat', 'value'], 'additionalProperties': False},
        'annotations': {'destructiveHint': True},
    },
    {
        'name': 'set_explosion_id',
        'description': 'Choose which explosion a projectile sets off when it hits something (impact) or '
                       'when it expires (expiry). 0 removes it. This is the field the panel shows but '
                       'reads only.',
        'inputSchema': {'type': 'object', 'properties': {
            'weapon': {'type': 'string'},
            'which': {'type': 'string', 'enum': ['impact', 'expiry']},
            'explosion_id': {'type': 'integer', 'minimum': 0,
                             'description': 'an id from list_explosions, or 0 for none'},
        }, 'required': ['weapon', 'which', 'explosion_id'], 'additionalProperties': False},
        'annotations': {'destructiveHint': True},
    },
    {
        'name': 'save',
        'description': 'Write the changed tables back into the game, keeping the murmur64 hash game.dll '
                       'expects for each file (the panel does the same with its reserved header bytes). A '
                       'dry run by default: it reports the correction it would use and writes nothing.',
        'inputSchema': {'type': 'object', 'properties': {
            'dry_run': {'type': 'boolean', 'default': True},
        }, 'additionalProperties': False},
        'annotations': {'destructiveHint': True},
    },
    {
        'name': 'restore',
        'description': 'Put the game\'s own files back from the copies this tool (or the launcher) kept in '
                       '%LOCALAPPDATA%\\SHODAN\\StatEditor\\originals.',
        'inputSchema': {'type': 'object', 'properties': {
            'dry_run': {'type': 'boolean', 'default': True},
        }, 'additionalProperties': False},
        'annotations': {'destructiveHint': True},
    },
    {
        'name': 'verify',
        'description': 'Open every file in the game folder, list the tables it holds, and check that each '
                       'file still hashes to the value game.dll holds for it.',
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        'annotations': {'readOnlyHint': True},
    },
    {
        'name': 'list_changes',
        'description': 'What this session changed and has not saved: file, byte ranges and every field '
                       'with its old and new value.',
        'inputSchema': {'type': 'object', 'properties': {}, 'additionalProperties': False},
        'annotations': {'readOnlyHint': True},
    },
]

PROTOCOL_VERSION = '2024-11-05'


class Session:
    """One game folder, opened once and kept in memory for the life of the server."""

    def __init__(self, folder=None, hash_dll=None, log=None):
        self.folder = folder
        self.hash_dll = hash_dll
        self.log = log
        self._game = None
        self.problems = []

    def game(self):
        if self._game is None:
            self._game = Game(self.folder, self.hash_dll, self.log).load()
        return self._game

    def status(self):
        game = self.game()
        return {
            'folder': game.folder,
            'found_by': game.found_by,
            'game_running': game_running(),
            'files': len(game.files),
            'tables': len(game.tables),
            'weapon_catalog': len(CATALOG.weapons()),
            'panel': CATALOG.path,
            'libsodium': game.sodium.path,
            'hash_dll': game.solver.dll,
            'pending_edits': len(game.edits),
            'changed_files': [name for name, _entry in game.dirty()],
            'hashes_missing_from_game_dll': [name for name, entry in game.files.items()
                                             if not entry.in_game_dll],
        }

    def call(self, name, arguments):
        game = self.game()
        arguments = arguments or {}
        if name == 'game_status':
            return self.status()
        if name == 'list_weapons':
            found = game.find_weapons(arguments.get('query', ''))
            offset = int(arguments.get('offset', 0))
            limit = int(arguments.get('limit', 50))
            return {'total': len(found), 'offset': offset, 'weapons': found[offset:offset + limit]}
        if name == 'get_weapon':
            key, hash16 = game.resolve_weapon(arguments['weapon'])
            report = game.weapon_report(key)
            report['name'] = next((entry[0] for entry in CATALOG.weapons() if entry[2] == hash16), None)
            return report
        if name == 'list_explosions':
            rows = []
            text = str(arguments.get('query', '')).lower()
            for explosion_id in sorted(game.index.get('explosion', {})):
                if not isinstance(explosion_id, int):
                    continue
                report = game.explosion_report(explosion_id)
                flat = json.dumps(report)
                if text and text not in flat.lower():
                    continue
                report['projectiles'] = sum(
                    1 for pid in game.index.get('projectile', {})
                    if isinstance(pid, int) and (
                        game.stat('projectile', pid, 'impact_explosion') == explosion_id
                        or game.stat('projectile', pid, 'expiry_explosion') == explosion_id))
                rows.append(report)
            offset = int(arguments.get('offset', 0))
            limit = int(arguments.get('limit', 50))
            return {'total': len(rows), 'offset': offset, 'explosions': rows[offset:offset + limit]}
        if name == 'set_stat':
            key, hash16 = game.resolve_weapon(arguments['weapon'])
            record = game.set_named(key, arguments['stat'], arguments['value'])
            record['hash16'] = hash16
            return {'applied': record, 'saved': False,
                    'note': 'in memory only: call save with dry_run false to write it into the game'}
        if name == 'set_explosion_id':
            key, hash16 = game.resolve_weapon(arguments['weapon'])
            record = game.set_explosion_id(key, arguments['which'], arguments['explosion_id'])
            record['hash16'] = hash16
            return {'applied': record, 'saved': False,
                    'note': 'in memory only: call save with dry_run false to write it into the game'}
        if name == 'save':
            return game.save(dry_run=bool(arguments.get('dry_run', True)))
        if name == 'restore':
            return game.restore(dry_run=bool(arguments.get('dry_run', True)))
        if name == 'verify':
            return game.verify()
        if name == 'list_changes':
            return {'edits': game.edits, 'files': game.diff_report()}
        raise KeyError('no tool %r' % name)


def reply(message_id, result):
    return {'jsonrpc': '2.0', 'id': message_id, 'result': result}


def failure(message_id, code, message):
    return {'jsonrpc': '2.0', 'id': message_id, 'error': {'code': code, 'message': message}}


def handle(session, request):
    """One JSON-RPC request -> one response, or None for a notification."""
    method = request.get('method')
    message_id = request.get('id')
    params = request.get('params') or {}
    if method == 'initialize':
        return reply(message_id, {
            'protocolVersion': params.get('protocolVersion') or PROTOCOL_VERSION,
            'capabilities': {'tools': {'listChanged': False}},
            'serverInfo': {'name': 'shodan-stat-editor', 'version': '1.0.0'},
            'instructions': 'The Helldivers 2 data tables the SHODAN Stat Editor panel edits. Read with '
                            'game_status / list_weapons / get_weapon / list_explosions / verify, change '
                            'with set_stat / set_explosion_id, then save with dry_run false.',
        })
    if method in ('notifications/initialized', 'notifications/cancelled'):
        return None
    if method == 'ping':
        return reply(message_id, {})
    if method == 'tools/list':
        return reply(message_id, {'tools': TOOLS})
    if method == 'tools/call':
        name = params.get('name')
        arguments = params.get('arguments') or {}
        try:
            result = session.call(name, arguments)
        except Exception as why:                    # a tool must not take the server down
            return reply(message_id, {'content': [{'type': 'text', 'text': '%s: %s' % (
                type(why).__name__, why)}], 'isError': True})
        return reply(message_id, {'content': [{'type': 'text',
                                               'text': json.dumps(result, indent=2, ensure_ascii=False)}]})
    if message_id is None:
        return None
    return failure(message_id, -32601, 'no method %r' % method)


def serve(session, stdin=None, stdout=None):
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError as why:
            print(json.dumps(failure(None, -32700, 'bad json: %s' % why)), file=stdout, flush=True)
            continue
        if isinstance(request, list):
            answers = [handle(session, one) for one in request]
            answers = [answer for answer in answers if answer]
            if answers:
                print(json.dumps(answers, ensure_ascii=False), file=stdout, flush=True)
            continue
        answer = handle(session, request)
        if answer:
            print(json.dumps(answer, ensure_ascii=False), file=stdout, flush=True)


# ------------------------------------------------------------------ selftest

def selftest(session):
    """Check this build without writing anything. Returns (ok, checks)."""
    checks = []

    def check(name, ok, detail=''):
        checks.append({'check': name, 'ok': bool(ok), 'detail': str(detail)})
        return bool(ok)

    game = session.game()
    check('game folder', os.path.isdir(game.folder), game.folder)
    check('files opened', len(game.files) >= 50, '%d files' % len(game.files))
    for name in ('weapon', 'fire mode', 'projectile', 'damage', 'explosion'):
        table = game.table(name)
        check('table ' + name, bool(table and table.entries),
              '%d records, stride %s' % (table.entries, table.stride) if table else 'missing')
    for name in ('attachment items', 'stratagem'):
        blocks = [table for table in game.tables if table.name == name]
        check('table ' + name, bool(blocks), '%d blocks' % len(blocks))
    missing = [name for name, entry in game.files.items() if not entry.in_game_dll]
    check('every file is in game.dll', not missing, ', '.join(missing) or 'all %d' % len(game.files))
    carrying, needs_float, unfixable = [], [], []
    for name, entry in game.files.items():
        if murmur64(entry.plain, 0, len(entry.plain)) == entry.hash:
            continue
        carrying.append(name)
        work = bytearray(entry.plain)
        ok, why = game.solver.correct(work, entry.hash, (), None)
        if ok and murmur64(work, 0, len(work)) == entry.hash:
            continue
        if 'nothing to vary' in str(why):
            needs_float.append(name)
        else:
            unfixable.append('%s (%s)' % (name, why))
    check('every file can be hashed back to its record', not unfixable,
          '%d carry a correction the panel wrote, %d of them need an edited float as the salt%s' % (
              len(carrying), len(needs_float),
              '; ' + ', '.join(unfixable) if unfixable else ''))

    # a one block file (projectile, explosion) has no spare header byte: the salt is an edited float
    table = game.table('projectile')
    entry = game.files.get(table.file) if table else None
    if check('a projectile table to try a float edit on', bool(table and entry), table and table.file):
        kept_plain = bytes(entry.plain)
        kept_baseline, kept_edits = entry.baseline, list(game.edits)
        try:
            key = next(iter(table.index))
            game.set_stat('projectile', key, 'calibre', 40.5)
            report = game.save(dry_run=True)
            rows = [one for one in report['files'] if one['name'] == table.file]
            check('a float edit gives a single block file its salt',
                  bool(rows) and rows[0].get('hash_kept') and rows[0].get('round_trip'),
                  rows[0].get('correction') if rows else 'the file was not staged')
        finally:
            entry.plain[:] = kept_plain
            entry.baseline = kept_baseline
            game.edits[:] = kept_edits
    check('panel weapon list', len(CATALOG.weapons()) > 0,
          '%d weapons from %s' % (len(CATALOG.weapons()), CATALOG.path))
    check('hash dll', True, game.solver.dll or 'not found: the slower pure python solver is used')

    gun = None
    for _name, _slot, hash16, _note in CATALOG.weapons():
        key = hash_key(hash16)
        if not game.record('fire mode', key):
            continue
        projectile = game.stat('fire mode', key, 'projectile')
        impact = game.stat('projectile', projectile, 'impact_explosion')
        if impact:
            gun = (hash16, projectile, impact)
            break
    if check('a weapon with an impact explosion', gun is not None, gun and gun[0]):
        _hash16, projectile, impact = gun
        damage_id = game.stat('explosion', impact, 'damage_id')
        damage = game.stat('damage', damage_id, 'damage')
        check('explosion %d -> damage %d' % (impact, damage_id), damage is not None,
              'damage %s' % damage)
        check('projectile %d calibre readable' % projectile,
              game.stat('projectile', projectile, 'calibre') is not None,
              'calibre %s' % game.stat('projectile', projectile, 'calibre'))
    report = game.save(dry_run=True, names=[])
    check('a dry run with no edits changes nothing', not report.get('files'),
          '%d files would change' % len(report.get('files') or []))
    return all(one['ok'] for one in checks), checks


# ------------------------------------------------------------------ the command line

HELP = """usage: stat_editor_mcp.py [-h] [--game DIR] [--native-dir DIR] [--hash-dll PATH]
                            [--panel PATH] [--json] [command] [arguments...]

With no command it speaks MCP over stdin/stdout (register it with your AI client).

commands:
  status                       where the game is, what was opened, what is pending
  weapons [text]               the panel's weapon list, filtered
  weapon NAME|HASH             every value this tool reads for one weapon
  explosions [text]            the explosion records of this build
  changes                      what is changed and not saved
  set WEAPON STAT VALUE        set one field (in memory; add --save to write it)
  set-explosion WEAPON impact|expiry ID
                               choose the explosion a projectile sets off (0 = none)
  save [--yes]                 write the changed tables into the game (dry run without --yes)
  restore [--yes]              put the game's own files back
  verify                       check every file against the hash in game.dll
  selftest                     check this build without writing

options:
  --game DIR       data/game folder (default: the launcher's remembered folder, then Steam)
  --native-dir DIR folder holding libsodium.dll and shodan_hash.dll
  --hash-dll PATH  shodan_hash.dll, the fast hash corrector
  --panel PATH     src/stat_editor.lua, the weapon list
  --json           print JSON instead of a table
  --save           with set / set-explosion: write it into the game as well
  --yes            with save / restore: really write instead of a dry run
  -h, --help       this text

exit codes: 0 ok, 2 usage, 3 no game folder, 4 refused, 5 verification failed
"""


def money(value):
    if isinstance(value, float):
        return round(value, 6)
    return value


def print_json(payload):
    print(json.dumps(payload, indent=2, ensure_ascii=False))


def print_table(rows, columns):
    if not rows:
        print('  (nothing)')
        return
    widths = [len(title) for title in columns]
    cells = []
    for row in rows:
        line = [str(row.get(column, '')) for column in columns]
        cells.append(line)
        widths = [max(width, len(text)) for width, text in zip(widths, line)]
    print('  ' + '  '.join(title.ljust(width) for title, width in zip(columns, widths)))
    print('  ' + '  '.join('-' * width for width in widths))
    for line in cells:
        print('  ' + '  '.join(text.ljust(width) for text, width in zip(line, widths)))


def short(value):
    if isinstance(value, float):
        return '%.6g' % value
    if isinstance(value, (bytes, bytearray)):
        return value.hex()
    if isinstance(value, (list, dict)):
        return json.dumps(value, ensure_ascii=False)
    return str(value)


def print_human(value, indent=0):
    """The same report as print_json, folded into something a person can read in a terminal."""
    pad = '  ' * indent
    if isinstance(value, dict):
        for key, item in value.items():
            if isinstance(item, (dict, list)) and item:
                print('%s%s:' % (pad, key))
                print_human(item, indent + 1)
            else:
                print('%s%s: %s' % (pad, key, short(item)))
    elif isinstance(value, list):
        for item in value:
            if isinstance(item, (dict, list)):
                print_human(item, indent)
                print()
            else:
                print('%s- %s' % (pad, short(item)))
    else:
        print('%s%s' % (pad, short(value)))


def describe(report, as_json):
    if as_json:
        print_json(report)
    else:
        print_human(report)


def parse_args(argv):
    options = {'game': None, 'native-dir': None, 'hash-dll': None, 'panel': None,
               'json': False, 'save': False, 'yes': False}
    rest = []
    index = 0
    while index < len(argv):
        token = argv[index]
        if token in ('-h', '--help'):
            options['help'] = True
            index += 1
            continue
        if token in ('--json', '--save', '--yes'):
            options[token[2:]] = True
            index += 1
            continue
        if token.startswith('--') and '=' in token:
            key, _ignored, value = token[2:].partition('=')
            if key not in ('game', 'native-dir', 'hash-dll', 'panel'):
                raise SystemExit(2)
            options[key] = value
            index += 1
            continue
        if token.startswith('--'):
            key = token[2:]
            if key not in ('game', 'native-dir', 'hash-dll', 'panel'):
                raise SystemExit(2)
            if index + 1 >= len(argv):
                raise SystemExit(2)
            options[key] = argv[index + 1]
            index += 2
            continue
        rest.append(token)
        index += 1
    return options, rest


def main(argv):
    if not argv:
        session = Session()
        try:
            serve(session)
        except KeyboardInterrupt:
            return 0
        return 0
    options, rest = parse_args(argv)
    if options.get('help') or not rest:
        print(HELP)
        return 0 if options.get('help') else 2
    if options['native-dir']:
        os.environ['SHODAN_NATIVE_DIR'] = options['native-dir']
    if options['hash-dll']:
        os.environ['SHODAN_HASH_DLL'] = options['hash-dll']
    if options['panel']:
        os.environ['SHODAN_EDITOR_DIR'] = options['panel']
    as_json = options['json']
    command, arguments = rest[0], rest[1:]
    # --game has to reach the folder the session opens: without it every write lands in whatever
    # install the launcher recorded, which is the live game folder
    session = Session(options['game'])
    try:
        game = session.game()
    except RuntimeError as why:
        print('stat_editor_mcp: %s' % why, file=sys.stderr)
        return 3
    try:
        return run_command(session, game, command, arguments, options)
    except KeyError as why:
        print('stat_editor_mcp: %s' % (why.args[0] if why.args else why), file=sys.stderr)
        return 4


def run_command(session, game, command, arguments, options):
    as_json = options['json']
    if command == 'status':
        describe(session.status(), as_json)
        return 0
    if command == 'weapons':
        text = arguments[0] if arguments else ''
        found = game.find_weapons(text)
        if as_json:
            print_json({'total': len(found), 'weapons': found})
        else:
            print_table(found, ['name', 'slot', 'hash16'])
        return 0
    if command == 'weapon':
        if not arguments:
            print('usage: weapon NAME|HASH', file=sys.stderr)
            return 2
        key, hash16 = game.resolve_weapon(arguments[0])
        report = game.weapon_report(key)
        report['hash16'] = hash16
        report['name'] = next((entry[0] for entry in CATALOG.weapons() if entry[2] == hash16), None)
        print_json({key: money(value) for key, value in report.items()})
        return 0
    if command == 'explosions':
        text = arguments[0].lower() if arguments else ''
        rows = []
        for explosion_id in sorted(game.index.get('explosion', {})):
            if not isinstance(explosion_id, int):
                continue
            report = game.explosion_report(explosion_id)
            if text and text not in json.dumps(report).lower():
                continue
            rows.append(report)
        if as_json:
            print_json({'total': len(rows), 'explosions': rows})
        else:
            print_table(rows, ['explosion', 'damage', 'durable', 'inner_radius', 'outer_radius', 'arc'])
        return 0
    if command == 'changes':
        describe({'edits': game.edits, 'files': game.diff_report()}, as_json)
        return 0
    if command in ('set', 'set-explosion'):
        if command == 'set' and len(arguments) < 3:
            print('usage: set WEAPON STAT VALUE [--save]', file=sys.stderr)
            return 2
        if command == 'set-explosion' and len(arguments) < 3:
            print('usage: set-explosion WEAPON impact|expiry ID [--save]', file=sys.stderr)
            return 2
        key, hash16 = game.resolve_weapon(arguments[0])
        if command == 'set':
            try:
                value = float(arguments[2])
            except ValueError:
                print('stat_editor_mcp: %r is not a number' % arguments[2], file=sys.stderr)
                return 2
            record = game.set_named(key, arguments[1], value)
        else:
            try:
                value = int(arguments[2], 0)
            except ValueError:
                print('stat_editor_mcp: %r is not an explosion id' % arguments[2], file=sys.stderr)
                return 2
            record = game.set_explosion_id(key, arguments[1], value)
        record['hash16'] = hash16
        print_json(record)
        if not options['save']:
            print('  (in memory only: add --save to write it into the game)', file=sys.stderr)
            return 0
        return write_and_report(game, dry_run=False, as_json=as_json)
    if command == 'save':
        return write_and_report(game, dry_run=not options['yes'], as_json=as_json)
    if command == 'restore':
        return restore_and_report(game, dry_run=not options['yes'], as_json=as_json)
    if command == 'verify':
        report = game.verify()
        describe(report, as_json)
        return 0 if report.get('ok') else 5
    if command == 'selftest':
        ok, checks = selftest(session)
        if as_json:
            print_json({'ok': ok, 'checks': checks})
        else:
            print_table(checks, ['check', 'ok', 'detail'])
            print('  %s' % ('all checks passed' if ok else 'SOME CHECKS FAILED'))
        return 0 if ok else 5
    print('stat_editor_mcp: no command %r (try --help)' % command, file=sys.stderr)
    return 2


def report_status(report):
    """4 when the tool refused (the game is running), 5 when a file could not be kept, else 0."""
    for line in report.get('problems') or []:
        print('stat_editor_mcp: %s' % line, file=sys.stderr)
    if report.get('refused'):
        return 4
    if report.get('problems') and not report.get('written') and not report.get('restored'):
        return 5
    return 0


def write_and_report(game, dry_run, as_json):
    report = game.save(dry_run=dry_run)
    describe(report, as_json)
    return report_status(report)


def restore_and_report(game, dry_run, as_json):
    report = game.restore(dry_run=dry_run)
    describe(report, as_json)
    return report_status(report)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
