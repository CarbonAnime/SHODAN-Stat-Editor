-- SHODAN Stat Editor Offline: updates from the GitHub releases.
-- At start the latest release is asked for in the background (shodan_hash.dll's fetch thread). When it is newer,
-- Update downloads its zip (only from this repository's releases) and shodan_hash.dll installs it (update.c: it
-- unpacks and checks the zip, swaps the new files in next to the program, the running exe and DLLs renamed to
-- *.old and removed at the next start) and starts the new one. Nothing in %LOCALAPPDATA%\SHODAN\StatEditor
-- (values, presets, originals) is touched.
local ffi = require('ffi')
local I = require('install')

for _, declaration in ipairs({
    'int MultiByteToWideChar(uint32_t cp, uint32_t flags, const char *s, int n, uint16_t *w, int wn);',
    'int WideCharToMultiByte(uint32_t cp, uint32_t flags, const uint16_t *w, int wn, char *s, int n, const char *d, int *u);',
    'void *shodan_fetch(const uint16_t *url, const uint16_t *path);',
    'int shodan_fetch_result(void *handle);',
    'int shodan_install(const uint16_t *zip, const uint16_t *program, const uint16_t *dir, uint16_t *exe, int exe_size, char *msg, int msg_size);',
    'int shodan_launch(const uint16_t *exe);',
    'int shodan_cleanup(const uint16_t *dir);',
}) do pcall(ffi.cdef, declaration) end
local C = ffi.C

local M = {}
M.REPO = 'CarbonAnime/SHODAN-Stat-Editor'   -- this fork: its releases carry the armoury too, upstream's would replace it
M.LATEST = 'https://api.github.com/repos/' .. M.REPO .. '/releases/latest'
M.PAGE = 'https://github.com/' .. M.REPO .. '/releases/latest'
M.EVERY_COMMIT = 'https://api.github.com/repos/' .. M.REPO .. '/releases/tags/dev'   -- the development build
local DOWNLOADS = 'https://github.com/' .. M.REPO .. '/releases/download/'
M.dir = I.home .. '/update'

local here = (debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or '')
local native
for _, at in ipairs({ here .. 'launcher/shodan_hash.dll', here .. 'shodan_hash.dll', here .. '../shodan_hash.dll' }) do
    local ok, lib = pcall(ffi.load, at)
    if ok then
        local has = pcall(function() return lib.shodan_fetch and lib.shodan_install end)
        if has then native = lib; break end
    end
end
M.available = native ~= nil

-- ---------------------------------------------------------------- text (UTF-8 -> UTF-16)
local function wide(s)
    if not s:match('^%a+://') then s = s:gsub('/', '\\') end   -- paths with Windows' separators; URLs as they are
    local n = C.MultiByteToWideChar(65001, 0, s, #s, nil, 0)
    local w = ffi.new('uint16_t[?]', n + 1)
    C.MultiByteToWideChar(65001, 0, s, #s, w, n)
    w[n] = 0
    return w
end
local function narrow(w)   -- (with forward slashes)
    local n = C.WideCharToMultiByte(65001, 0, w, -1, nil, 0, nil, nil)
    local s = ffi.new('char[?]', n)
    C.WideCharToMultiByte(65001, 0, w, -1, s, n, nil, nil)
    return (ffi.string(s):gsub('\\', '/'))
end
local function exists(path)
    local f = io.open(path, 'rb')
    if f then f:close() end
    return f ~= nil
end

-- ---------------------------------------------------------------- versions
local function parts(v)
    local out = {}
    for n in tostring(v or ''):gmatch('%d+') do out[#out + 1] = tonumber(n) end
    return out
end
-- true when version a is newer than b
function M.newer(a, b)
    local x, y = parts(a), parts(b)
    for k = 1, math.max(#x, #y) do
        local p, q = x[k] or 0, y[k] or 0
        if p ~= q then return p > q end
    end
    return false
end

-- what the API's JSON offers: { version, url, name, label } for a release (its zip: this repository's downloads
-- only, not a language-only zip), { commit, url, name, label } for the development build (its zip is named
-- ...-dev-<commit>.zip, built by .github/workflows/dev-build.yml from every commit)
function M.parse(json, channel)
    for url in json:gmatch('"browser_download_url"%s*:%s*"([^"]+)"') do
        local name = url:match('([^/]+)$')
        if url:sub(1, #DOWNLOADS) == DOWNLOADS and name:match('%.zip$') then
            if channel == 'commits' then
                local commit = name:match('%-dev%-(%x+)%.zip$')
                if commit then return { commit = commit:lower(), url = url, name = name, label = 'dev ' .. commit:sub(1, 7) } end
            elseif not name:match('%-zh%-Hans%.zip$') and not name:match('%-zh%-Hant%.zip$') and not name:match('%-ru%.zip$')
                   and not name:match('%-dev%-') then
                local version = json:match('"tag_name"%s*:%s*"v?([%d%.]+)"')
                if not version then return nil end
                return { version = version, url = url, name = name, label = 'v' .. version }
            end
        end
    end
    return nil
end

-- this program's build (app/build.txt, written by package.py): { version, commit, channel } (empty if missing)
function M.build(app)
    local out = {}
    local f = io.open(app .. 'build.txt', 'rb')
    if not f then return out end
    for k, v in f:read('*a'):gmatch('(%a+)%s*=%s*([^\r\n]+)') do out[k] = v end
    f:close()
    return out
end

-- ---------------------------------------------------------------- downloads
-- starts a download into a file; poll(job) is nil while it runs, then true or false and the reason
function M.fetch(url, path)
    if not native then return nil, 'the download helper (shodan_hash.dll) is missing' end
    os.remove(path)
    local job = native.shodan_fetch(wide(url), wide(path))
    if job == nil then return nil, 'could not start the download' end
    return { handle = job, path = path }
end
function M.poll(job)
    if job.done ~= nil then return job.done, job.why end
    local r = native.shodan_fetch_result(job.handle)
    if r == -1 then return nil end
    job.done = r == 200 and exists(job.path)
    if not job.done then job.why = r > 0 and 'the server answered ' .. r or 'no connection (' .. r .. ')' end
    return job.done, job.why
end

-- asks (in the background) for the latest release, or the development build when channel is 'commits';
-- call M.check_poll() each frame until it gives a result
function M.check(channel)
    M.channel = channel == 'commits' and 'commits' or 'releases'
    M.checking = M.fetch(M.channel == 'commits' and M.EVERY_COMMIT or M.LATEST, M.dir .. '/latest.json')
end
-- nil while asking; then what to update to, or false. current: { version, commit } of this program. A release
-- is newer by its version; the development build is new when it was built from another commit than this program.
function M.check_poll(current)
    if not M.checking then return false end
    local done = M.poll(M.checking)
    if done == nil then return nil end
    M.checking = nil
    if not done then return false end
    local f = io.open(M.dir .. '/latest.json', 'rb')
    local json = f and f:read('*a') or ''
    if f then f:close() end
    os.remove(M.dir .. '/latest.json')
    local offer = M.parse(json, M.channel)
    if not offer then return false end
    if offer.commit then
        local mine = (current.commit or ''):lower()
        if mine ~= '' and mine:sub(1, #offer.commit) == offer.commit then return false end
        return offer
    end
    if M.newer(offer.version, current.version) then return offer end
    return false
end

-- ---------------------------------------------------------------- installing
-- swaps the downloaded zip's files in over `program` (the folder holding the exe), in shodan_hash.dll (update.c).
-- Returns the new exe's path, or nil and the reason (everything put back as it was).
function M.install(zip, program, log)
    log = log or function() end
    if not native then return nil, 'the update helper (shodan_hash.dll) is missing' end
    local exe, msg = ffi.new('uint16_t[1100]'), ffi.new('char[65536]')
    local ok = native.shodan_install(wide(zip), wide(program), wide(M.dir), exe, 1100, msg, 65536)
    local text = ffi.string(msg)
    if ok == 0 then return nil, (text:gsub('\\', '/')) end
    for rel in text:gmatch('[^\n]+') do log('updated ' .. rel:gsub('\\', '/')) end
    return narrow(exe)
end

-- what was just installed, for the next start to say so
function M.note(label)   -- 'v3.0.2' or 'dev abc1234'
    local f = io.open(M.dir .. '/updated.txt', 'wb')
    if f then f:write(label); f:close() end
end

-- starts a program (the updated one) in its folder
function M.launch(exe)
    return native ~= nil and native.shodan_launch(wide(exe)) ~= 0
end

-- after an update: the files it set aside (the old program may still be closing, so what can't go yet stays
-- listed for the next start) and its other leftovers. Returns the version an update just installed
-- ('v3.0.2', 'dev abc1234'), if any.
function M.cleanup()
    local note = io.open(M.dir .. '/updated.txt', 'rb')
    local updated = note and note:read('*a'):match('^([%w%. ]+)$')
    if note then note:close() end
    if native then native.shodan_cleanup(wide(M.dir)) end
    return updated
end

return M
