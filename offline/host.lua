-- SHODAN Stat Editor Offline: Stat Editor's own panel (stat_editor.lua, the in-game mod) in a desktop window,
-- editing the game's data files instead of the running game. The files are decrypted into memory as the game
-- holds them, the panel finds and edits them there, and Install writes the changed ones into the game folder.
-- host.lua [stat_editor.lua]
local here = (debug.getinfo(1, 'S').source:match('^@(.*[/\\])') or './')
package.path = here .. '?.lua;' .. package.path

local ffi = require('ffi')
local shim = require('engine_shim')
local G = require('gamedata')
local D = require('hostdata')
local I = require('install')
local U = require('update')
local AR = require('armory')

pcall(ffi.cdef, 'uint64_t GetTickCount64(void);')
local function clock() return tonumber(ffi.C.GetTickCount64()) / 1000 end
local log_file = nil
local function log(text)
    if not log_file then
        I.mkdirs(I.logs)
        log_file = io.open(I.logs .. '/SHODANStatEditorHost.log', 'w')
        if not log_file then log_file = false end
    end
    if log_file then log_file:write(os.date('%H:%M:%S '), text, '\n'); log_file:flush() end
end

local BACK = { 255, 12, 15, 19 }
local BEZEL = 6                       -- the outline's gap from the window's edge (the panel's too)
local GOLD, WHITE, MUTED, WARN, GOOD = { 255, 255, 213, 0 }, { 255, 238, 242, 246 }, { 255, 153, 171, 184 },
                                        { 255, 255, 150, 60 }, { 255, 120, 220, 140 }

local function centred(text, y, size, c)
    shim.text(text, (shim.w - shim.text_width(text, size)) / 2, y, size, c)
end

-- a screen with a few lines of text (loading, problems)
local function screen(lines)
    shim.fill(0, 0, shim.w, shim.h, BACK)
    local s = shim.h / 1080
    local y = shim.h * 0.42
    for k, line in ipairs(lines) do
        local size = (k == 1 and 34 or 20) * s
        centred(line, y, size, k == 1 and GOLD or MUTED)
        y = y + size * 1.8
    end
    shim.present()
end

local function fatal(text)
    log('stopped: ' .. text)
    shim.message_box(text, 0x10)
    os.exit(1)
end

-- ---------------------------------------------------------------- start
local function main()
    shim.open('SHODAN Stat Editor Offline')
    shim.pump()
    local migrated = I.migrate()
    if migrated then log('copied ' .. migrated .. ' files from the CowboyBingus folder') end
    screen({ 'SHODAN Stat Editor Offline', 'Looking for Helldivers 2...' })
    local exe_dir = here:gsub('[/\\]app[/\\]$', ''):gsub('[/\\]$', '')
    local game = I.find_game(exe_dir)
    if not game then
        fatal('Helldivers 2 was not found.\n\nWrite the path of its folder (the one holding "data") into\n'
              .. I.home:gsub('/', '\\') .. '\\game folder.txt\nand start again.')
    end
    log('game: ' .. game)
    AR.log = log
    AR.init(game, I.home .. '/armory.ini')   -- the Armory page's choices (first time: the Forge's own)
    log('hash search: ' .. (G.native and 'native, every core' or 'Lua (shodan_hash.dll not found)'))
    screen({ 'SHODAN Stat Editor Offline', 'Reading the game\'s data files...' })
    shim.pump()
    local originals, ours, problems, count = I.originals(game)
    if count == 0 then fatal('No game data files in ' .. game) end
    for _, p in ipairs(D.load(game, originals)) do problems[#problems + 1] = p end
    for _, p in ipairs(problems) do log('problem: ' .. p) end
    local loaded = 0
    for _ in pairs(D.files) do loaded = loaded + 1 end
    log(string.format('%d of %d files loaded, %d installed by an earlier install', loaded, count,
        (function() local n = 0; for _ in pairs(ours) do n = n + 1 end return n end)()))
    if loaded == 0 then
        fatal('None of the game\'s data files could be read:\n\n' .. table.concat(problems, '\n', 1, math.min(#problems, 8))
              .. '\n\nVerify the game files in Steam and start again.')
    end
    if #problems > 0 then
        shim.message_box('Some of the game\'s data files are not as this editor expects; their stats cannot be edited:\n\n'
                         .. table.concat(problems, '\n', 1, math.min(#problems, 10))
                         .. '\n\nIf another tool changed them, verify the game files in Steam.', 0x30)
    end

    -- ------------------------------------------------------------ the editor
    screen({ 'SHODAN Stat Editor Offline', 'Finding the stats...' })
    rawset(_G, 'SHODAN_OFFLINE', true)
    -- the panel's first language (until one is chosen in Settings): Windows' display language, if translated
    pcall(ffi.cdef, 'uint16_t GetUserDefaultUILanguage(void);')
    local id = ffi.C.GetUserDefaultUILanguage()
    local primary, sub = id % 1024, math.floor(id / 1024)
    if rawget(_G, 'SHODAN_OFFLINE_LANG') == nil then rawset(_G, 'SHODAN_OFFLINE_LANG', primary == 0x04 and ((sub == 2 or sub == 4) and 'zh-Hans' or 'zh-Hant')
                                      or primary == 0x19 and 'ru' or nil) end
    stingray = shim.engine()
    function update(dt) end
    local editor = arg and arg[1] or here .. 'stat_editor.lua'
    local chunk, why = loadfile(editor)
    if not chunk then fatal('Could not load ' .. editor .. ':\n' .. tostring(why)) end
    local ok, err = pcall(chunk)
    if not ok then fatal('Stat Editor did not start:\n' .. tostring(err)) end
    local state = rawget(_G, 'ShodanStatEditor')
    if type(state) ~= 'table' then fatal('Stat Editor did not start (no state).') end
    local build = U.build(here)   -- app/build.txt: version, commit, channel
    shim.set_title('SHODAN Stat Editor Offline v' .. tostring(state.version)
                   .. (build.channel == 'dev' and build.commit and ' (dev ' .. build.commit:sub(1, 7) .. ')' or ''))
    -- the host's own text in the panel's language, drawn with its font
    local function tr(text) return type(state.tr) == 'function' and state.tr(text) or text end
    if type(state.lang) == 'function' then shim.lang = state.lang end

    -- ------------------------------------------------------------ the host's bar (below the panel)
    local bar = { hover = nil, message = nil, tone = MUTED, note = nil, busy = nil, base = nil, buttons = {} }
    -- text cut to fit room, a whole character at a time, with an ellipsis (UTF-8 aware)
    local function cut(text, size, room)
        local chars = {}
        for c in text:gmatch('[%z\1-\127\194-\244][\128-\191]*') do chars[#chars + 1] = c end
        while #chars > 1 and shim.text_width(table.concat(chars) .. '...', size) > room do chars[#chars] = nil end
        return table.concat(chars) .. '...'
    end

    -- one line of the bar: the font shrinks to fit room, then the text is cut (nothing overruns its box)
    local function bar_line(text, x, y, size, smallest, room, colour)
        room = math.max(40, room)
        while size > smallest and shim.text_width(text, size) > room do size = size - 0.5 end
        if shim.text_width(text, size) > room then text = cut(text, size, room) end
        shim.text(text, x, y, size, colour)
        return size
    end

    -- The bar follows the window: the buttons are sized to their labels and squeezed only when the window is
    -- too narrow for them, and the status text has a row of its own above them.
    local function layout()
        local s = math.max(0.55, shim.h / 1080)
        local pad, gap = 30 * s, 12 * s
        bar.s = s
        bar.band = 1032 * s                 -- the panel's bottom edge; everything below it is the bar
        bar.text_y = bar.band + 14 * s      -- the status line, on its own row
        local y0, y1 = bar.band + 19 * s, shim.h - 3 * s
        local rows = {
            { key = 'install', label = 'Install into the game' },
            { key = 'restore', label = 'Restore the game\'s files' },
            { key = 'armory', label = 'Armor passives 护甲叠加 (F5)' },
        }
        local wanted, total = {}, 0
        for i, row in ipairs(rows) do
            local w = shim.text_width(tr(row.label), 15 * s) + 26 * s
            wanted[i] = math.max(130 * s, math.min(320 * s, w))
            total = total + wanted[i]
        end
        total = total + gap * (#rows - 1)
        local room = math.max(120 * s, shim.w - pad * 2)
        local squeeze = total > room and room / total or 1
        bar.buttons = {}
        local x = pad
        for i, row in ipairs(rows) do
            local w = wanted[i] * squeeze
            bar.buttons[i] = { key = row.key, label = row.label, x0 = x, x1 = x + w, y0 = y0, y1 = y1 }
            x = x + w + gap * squeeze
        end
        if bar.release then
            local x1 = shim.w - pad
            bar.buttons[#bar.buttons + 1] = { key = 'update', label = 'Update to ' .. bar.release.label,
                                              x0 = x1 - 170 * s, x1 = x1, y0 = 9 * s, y1 = 41 * s, gold = true }
        end
    end
    layout()

    local function installed_count() local n = 0; for _, v in pairs(ours) do if v then n = n + 1 end end return n end

    local function status()
        if bar.busy then return bar.busy, WARN end
        if bar.message then return bar.message, bar.tone end
        if state.phase ~= 'ready' then return 'Finding the stats...', MUTED end
        local n = installed_count()
        local dirty = bar.base and state.writes ~= bar.base
        if dirty and n == 0 then return 'Your values are not in the game yet: close the game, then Install.', WARN end
        if dirty then return 'Changed since the last install: Install to put it in the game.', WARN end
        if n > 0 then return 'Your values are installed (' .. n .. ' game files). Close the game before installing.', GOOD end
        return 'The game\'s own files are in place. Close the game, then Install to play with your values.', MUTED
    end

    local function paint_bar()
        local s = bar.s
        shim.fill(0, bar.band, shim.w, shim.h, BACK)
        shim.fill(0, 0, shim.w, 46 * s, BACK)
        shim.text('SHODAN Stat Editor', 30 * s, 32 * s, 24 * s, GOLD, true)
        local t = tr('OFFLINE  -  edits the game\'s files; they apply when the game starts')
        if not bar.release then shim.text(t, shim.w - 30 * s - shim.text_width(t, 15 * s), 31 * s, 15 * s, MUTED) end
        -- the status first: it has its own row, so nothing is ever drawn under a button's label
        local text, tone = status()
        text = tr(text)
        if bar.note then text = text .. ' ' .. tr(bar.note) end
        bar_line(text, 30 * s, bar.text_y, 13 * s, 9 * s, shim.w - 60 * s, tone)
        for _, b in ipairs(bar.buttons) do
            local hovered = bar.hover == b.key and not bar.busy
            shim.fill(b.x0, b.y0, b.x1, b.y1, hovered and { 255, 52, 66, 80 } or { 255, 28, 34, 42 })
            local edge = hovered and GOLD or { 255, 70, 82, 94 }
            local e = math.max(1, math.floor(2 * s + 0.5))
            shim.fill(b.x0, b.y0, b.x1, b.y0 + e, edge); shim.fill(b.x0, b.y1 - e, b.x1, b.y1, edge)
            shim.fill(b.x0, b.y0, b.x0 + e, b.y1, edge); shim.fill(b.x1 - e, b.y0, b.x1, b.y1, edge)
            shim.flush()
            local size, label, room = 15 * s, tr(b.label), math.max(20, b.x1 - b.x0 - 10 * s)
            while size > 9 * s and shim.text_width(label, size) > room do size = size - 0.5 end
            if shim.text_width(label, size) > room then label = cut(label, size, room) end
            shim.text(label, (b.x0 + b.x1 - shim.text_width(label, size)) / 2, (b.y0 + b.y1) / 2 + size * 0.35, size,
                      b.gold and GOLD or WHITE)
        end
    end

    local function paint()
        if state.phase == 'ready' then
            shim.paint_guis(BACK)
        else
            shim.fill(0, 0, shim.w, shim.h, BACK)
            centred(tr('Finding the stats...'), shim.h * 0.45, 30 * bar.s, GOLD)
            centred(tostring(state.status or ''), shim.h * 0.45 + 40 * bar.s, 18 * bar.s, MUTED)
        end
        paint_bar()
        shim.present()
    end

    local function say(text, tone, note) bar.message, bar.tone, bar.note = text, tone or MUTED, note end

    local function busy(text)
        bar.busy = text
        paint()
        shim.pump()
    end

    -- ------------------------------------------------------------ install / restore
    local function install()
        if I.game_running() then say('Helldivers 2 is running: close it, then Install.', WARN); return end
        busy('Installing: finding what changed...')
        local changes, problems = D.diff()
        if problems and #problems > 0 then
            for _, c in ipairs(changes) do G.free(c.plain) end
            bar.busy = nil
            local first = problems[1]
            log('install stopped: ' .. first.name .. ': ' .. tostring(first.why))
            say('Not installed: ' .. first.name .. ' could not be read (' .. tostring(first.why)
                .. '). Nothing was changed.', WARN)
            return
        end
        -- the Armor page's choices on top of the panel's own passive page: one writer, one hash correction
        local stacks, own_off, policy = AR.selection(state.stacks and state.stacks() or {},
                                                     state.own_off and state.own_off() or {}, D.passives())
        local stacked, why_not = D.stack(changes, stacks, log, own_off, policy)
        if not stacked then
            for _, c in ipairs(changes) do G.free(c.plain) end
            bar.busy = nil
            log('install stopped: passive stacking: ' .. tostring(why_not))
            say('Not installed: the armor passives could not be stacked (' .. tostring(why_not) .. '). Nothing was changed.', WARN)
            return
        end
        local writes, made, back, nudged = {}, 0, 0, 0
        for k, c in ipairs(changes) do
            busy(string.format('Installing: preparing %s (%d of %d)...', c.name, k, #changes))
            local sealed, why = D.build(c, function(text) log(c.name .. ': ' .. text); shim.pump() end)
            if not sealed then
                for j = k + 1, #changes do G.free(changes[j].plain) end
                bar.busy = nil
                log('install stopped: ' .. c.name .. ': ' .. tostring(why))
                say('Not installed: ' .. c.name .. ' could not be prepared (' .. tostring(why) .. '). Nothing was changed.', WARN)
                return
            end
            writes[c.name], made = sealed, made + 1
            if c.borrowed and #c.borrowed > 0 then nudged = nudged + 1 end
        end
        for name, mine in pairs(ours) do
            if mine and not writes[name] then writes[name], back = originals[name], back + 1 end
        end
        if not next(writes) then
            bar.busy, bar.base = nil, state.writes
            say('Nothing to install: your values are the game\'s own.', GOOD)
            return
        end
        busy('Installing: writing the files...')
        local done, why = I.write_files(game, writes, originals)
        bar.busy = nil
        if not done then
            log('install failed: ' .. tostring(why))
            say('Not installed: ' .. tostring(why), WARN)
            return
        end
        for name, data in pairs(writes) do ours[name] = data ~= originals[name] end
        bar.base = state.writes
        local armor = AR.touches() and ('  ' .. AR.summary()) or ''
        log(string.format('installed: %d changed, %d back to the original, %d had a decimal value borrowed for the hash',
            made, back, nudged))
        say(string.format('Installed (%d game files changed%s). Start the game to play with your values.', made,
            back > 0 and ', ' .. back .. ' back to the original' or '') .. armor, GOOD,
            nudged > 0 and 'A file of one block has no spare header room, so one decimal value in it moved a few units'
                .. ' in the last place: that is how it keeps the hash the game knows.' or nil)
    end

    local function restore()
        if I.game_running() then say('Helldivers 2 is running: close it, then restore.', WARN); return end
        local writes = {}
        for name, mine in pairs(ours) do if mine then writes[name] = originals[name] end end
        if not next(writes) then say('The game\'s own files are already in place.', GOOD); return end
        busy('Restoring the game\'s files...')
        local done, why = I.write_files(game, writes, originals)
        bar.busy = nil
        if not done then say('Not restored: ' .. tostring(why), WARN); return end
        for name in pairs(writes) do ours[name] = false end
        bar.base = nil
        log('restored the originals')
        say('The game\'s own files are back. Your values stay saved here (Install puts them in again).', GOOD)
    end

    -- ------------------------------------------------------------ updates (update.lua)
    local exe_dir = exe_dir
    local function update_program()
        local release = bar.release
        busy('Updating: downloading ' .. release.label .. '...')
        local zip = U.dir .. '/' .. release.name
        local job, why = U.fetch(release.url, zip)
        local done = nil
        if job then
            repeat
                if not shim.pump() then bar.busy = nil; return false end
                shim.sleep(20)
                done, why = U.poll(job)
            until done ~= nil
        end
        if not done then
            bar.busy = nil
            log('update: download failed: ' .. tostring(why))
            say('Update failed: ' .. tostring(why) .. '. The release page has it: ' .. U.PAGE, WARN)
            return false
        end
        busy('Updating: installing ' .. release.label .. '...')
        local exe, problem = U.install(zip, exe_dir, log)
        bar.busy = nil
        if not exe then
            log('update: not installed: ' .. tostring(problem))
            say('Update failed: ' .. tostring(problem) .. '. Nothing was changed.', WARN)
            return false
        end
        log('update: ' .. release.label .. ' installed, restarting: ' .. exe)
        U.note(release.label)
        bar.restart = exe
        return true
    end

    -- ------------------------------------------------------------ the frame loop
    local painted, was_down, was_f5, armed, said_ready = nil, false, false, nil, false
    local last = clock()
    while shim.pump() do
        local now = clock()
        update(math.min(0.1, now - last))
        last = now
        if state.phase == 'ready' and not said_ready then
            said_ready = true
            bar.base = installed_count() > 0 and state.writes or nil
            log(string.format('ready: %s weapons, %s values applied, %s refused', tostring(state.weapons),
                tostring(state.applied), tostring(state.refused)))
            local stacks = state.stacks and state.stacks() or {}
            local own_off = state.own_off and state.own_off() or {}
            if installed_count() == 0 and ((state.applied or 0) > 0 or next(stacks) or next(own_off)) then bar.base = -1 end
            if I.game_running() then say('Helldivers 2 is running: you can edit, but close it before you Install.', WARN) end
            local updated = U.cleanup()
            if updated then say('Updated to ' .. updated .. '.', GOOD) end
        end
        -- updates: asked at start, and again when Settings > Update channel changes
        local channel = type(state.update_channel) == 'function' and state.update_channel() or 'releases'
        if said_ready and U.available and channel ~= bar.channel and not U.checking and not bar.restart then
            bar.channel = channel
            if bar.release then bar.release = nil; layout() end
            U.check(channel)
        end
        if U.checking then
            local current = { version = state.version, commit = build.commit }
            local release = U.check_poll(current)
            if release and bar.channel ~= U.channel then release = nil end   -- the channel changed meanwhile
            if release then
                bar.release = release
                layout()
                log('update: ' .. release.label .. ' is available (' .. release.name .. ')')
                -- Settings > Updates: Automatic
                if type(state.updates) == 'function' and state.updates() == 'auto' and update_program() then break end
            elseif release == false then
                log('update: nothing newer on ' .. tostring(U.channel) .. ' than v' .. tostring(current.version)
                    .. (current.commit and ' (' .. current.commit:sub(1, 7) .. ')' or ''))
            end
        end
        -- the bar's buttons
        -- F5 opens the armor page: it draws instead of the panel, and parks the panel's tick while it is up
        local f5 = state.phase == 'ready' and shim.focused() and shim.key_down(0x74) or false
        if f5 and not was_f5 then
            if AR.is_open() then AR.close() else AR.show() end
            painted = nil
        end
        was_f5 = f5
        if AR.is_open() then
            local ok, err = pcall(AR.frame, shim)
            if not ok then
                AR.close()
                log('armory page failed: ' .. tostring(err))
                say('The armor page stopped: ' .. tostring(err), WARN)
                painted = nil
            end
            shim.sleep(10)
        else
        local x, y = nil, nil
        if shim.focused() then x, y = shim.cursor() end
        local hover = nil
        for _, b in ipairs(bar.buttons) do
            if x and x >= b.x0 and x < b.x1 and y >= b.y0 and y < b.y1 then hover = b.key end
        end
        bar.hover = hover
        local down = shim.focused() and shim.key_down(0x01)
        if down and not was_down then armed = hover end
        if not down and was_down and armed and armed == hover and state.phase == 'ready' then
            bar.message = nil
            if hover == 'install' then install() elseif hover == 'restore' then restore()
            elseif hover == 'armory' then AR.show(); painted = nil
            elseif hover == 'update' and update_program() then break end
            armed = nil
        end
        was_down = down
        -- a resized window: the bar re-lays itself out (the panel follows through Gui.resolution)
        local size = shim.w .. 'x' .. shim.h
        if size ~= bar.size then bar.size = size; layout(); painted = nil end
        local text = status()
        local signature = table.concat({ shim.version, size, state.phase, tostring(state.status), tostring(hover), text,
                                         shim.lang(), bar.release and bar.release.label or '', tostring(bar.note) }, '|')
        if signature ~= painted then
            painted = signature
            paint()
        end
        shim.sleep(state.phase == 'ready' and 10 or 1)
        end
    end
    -- the editor saves its values a moment after a change
    local stop = clock() + 1.5
    while clock() < stop do update(0.05); shim.sleep(20) end
    if bar.restart then
        local go = true
        if go and not U.launch(bar.restart) then
            shim.message_box('Updated. Start ' .. bar.restart:gsub('/', '\\') .. ' again.', 0x40)
        end
    end
    log('closed')
end

local ok, err = xpcall(main, debug.traceback)
if not ok then
    log('error: ' .. tostring(err))
    shim.message_box('SHODAN Stat Editor Offline stopped:\n\n' .. tostring(err), 0x10)
end
