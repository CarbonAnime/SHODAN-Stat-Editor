-- armory.lua -- the Armory page: which armor passive stacks which others, as the Super Earth Armory Forge mod did.
--
-- This file is the choice half only. SHODAN's own Install writes the game's files; hostdata.M.stack appends the
-- chosen passives' modifiers to every family's record on the same plain text, and one hash correction and one
-- seal follow. Values are always SHODAN's: the rows copied are the ones the game's file holds now (the Armor page
-- edits them), so nothing here may retune a value.
--
-- The choices live in %LOCALAPPDATA%/SHODAN/StatEditor/armory.ini, in the Forge's own loadout.ini dialect
-- ([profile: <armor>] / conflicts / own_passive / <passive> = on|off), so an existing ArmoryForge-NoBSL.ini can be
-- read as it is; its value lines are ignored on purpose.
--
-- Passive data (ids, effects, Chinese and armor names) comes from armory_data.lua, extracted from the mod's
-- boot.lua; do not edit it by hand.
--
-- The page does not draw while SHODAN's own panel draws: host.lua calls frame() instead of paint(), and parks the
-- panel's tick (the OCLAW_UPDATE_BUS job) while it is open, so the two never fight over the keyboard.

local DATA = require('armory_data')

local M = { data = DATA, list = DATA.list, every = DATA.every or 999 }
M.FILE = 'generated_customization_passive_bonuses.dl_bin'
M.log = function() end

local EVERY = M.every

------------------------------------------------------------------ selection model
-- profiles[group] = { enabled = { [passive id] = true }, own = true|false,
--                     conflicts = 'stack' | 'strongest' }
-- group 是护甲家族 (也就是被动 id); 999 = 所有护甲, 只作用于自己没有 profile 的家族。
M.profiles = {}
M.dirty = false
M.path = nil

local BY_ID, BY_NAME, BY_RAW = {}, {}, {}
local function norm(s) return (tostring(s):lower():gsub('[^a-z0-9]', '')) end

for _, c in ipairs(DATA.list) do
    BY_ID[c.id] = c
    BY_NAME[norm(c.name)] = c.id
    BY_RAW[c.zh] = c.id
end
BY_RAW['所有护甲'] = EVERY
for _, n in ipairs({ 'Every armor', 'Every', 'All armors', 'Any armor' }) do BY_NAME[norm(n)] = EVERY end

-- 页面走的分组顺序: 先「所有护甲」, 再按模组表里的顺序
M.groups = { EVERY }
for _, c in ipairs(DATA.list) do M.groups[#M.groups + 1] = c.id end

function M.find(text)
    if text == nil then return nil end
    text = tostring(text):match('^%s*(.-)%s*$')
    local n = tonumber(text)
    if n and (BY_ID[n] or n == EVERY) then return n end
    return BY_RAW[text] or BY_NAME[norm(text)]
end

function M.group(id)
    local p = M.profiles[id]
    if not p then
        p = { enabled = {}, own = true, conflicts = 'stack' }
        M.profiles[id] = p
    end
    return p
end

local function group_name(id)
    if id == EVERY then return '所有护甲  Every armor' end
    local c = BY_ID[id]
    return c and ('#' .. id .. '  ' .. c.zh .. '  ' .. c.name) or ('#' .. id)
end
M.group_name = group_name

local function chosen(p)
    local n = 0
    for id, on in pairs(p.enabled) do if on and BY_ID[id] then n = n + 1 end end
    return n
end

-- 有几组已设置 / 共几条叠加
function M.count()
    local groups, rows = 0, 0
    for _, id in ipairs(M.groups) do
        local p = M.profiles[id]
        if p then
            local n = chosen(p)
            if n > 0 or p.own == false then
                groups = groups + 1
                rows = rows + n
            end
        end
    end
    return groups, rows
end

function M.touches()
    local groups = M.count()
    return groups > 0
end

------------------------------------------------------------------ settings file
-- SAF 自己的 loadout.ini 方言: [settings] / [profile: <名字>] / conflicts / own_passive /
-- <被动名> = on|off。数值行 (<被动>.<效果> = 数值, raw, raw_stats, swap, weight) 一律
-- 忽略 —— 数值以 SHODAN 为准。用户现有 ArmoryForge-NoBSL.ini 的叠加选择可以直接接过来。
local TRUE_WORDS = { on = true, yes = true, ['true'] = true, ['1'] = true, y = true }
local FALSE_WORDS = { off = false, no = false, ['false'] = false, ['0'] = false, n = false }

-- 返回 profiles, 被忽略的数值行数, 提示信息
function M.parse(text)
    local profiles, notes = {}, {}
    local section, prof = nil, nil
    local dropped = 0
    for raw in (tostring(text) .. '\n'):gmatch('([^\n]*)\n') do
        local line = raw:gsub('\r$', '')
        if not line:match('^%s*$') and not line:match('^%s*[;#]') then
            local v = line:gsub('%s[;#].*$', ''):match('^%s*(.-)%s*$')
            local head = v:match('^%[(.+)%]$')
            if head then
                section, prof = head, nil
                local name = head:match('^%s*[Pp][Rr][Oo][Ff][Ii][Ll][Ee]%s*:%s*(.-)%s*$')
                if name then
                    local id = M.find(name)
                    if id then
                        prof = { enabled = {}, own = true, conflicts = 'stack' }
                        profiles[id] = prof
                    else
                        notes[#notes + 1] = '未知护甲组 [' .. head .. ']，已跳过'
                    end
                end
            else
                local k, val = v:match('^(.-)%s*=%s*(.*)$')
                if k and prof then
                    local lk = k:lower()
                    if lk == 'conflicts' then
                        prof.conflicts = val:lower() == 'strongest' and 'strongest' or 'stack'
                    elseif lk == 'own_passive' or lk == 'own' then
                        prof.own = not (FALSE_WORDS[val:lower()] or val:lower() == 'off')
                    elseif lk == 'raw' or lk == 'raw_stats' or lk == 'swap' or lk == 'weight'
                        or lk == 'base' or lk == 'retire' or lk == 'hotkey' or lk == 'swap_hotkey'
                        or lk == 'panel_scale' or lk == 'name' then
                        -- 模组的其它设置项, 与叠加无关
                    elseif k:find('%.') then
                        dropped = dropped + 1          -- <被动>.<效果> = 数值: 数值归 SHODAN 管
                    else
                        local id = M.find(k)
                        local lv = val:lower()
                        if id then
                            if TRUE_WORDS[lv] then prof.enabled[id] = true
                            elseif FALSE_WORDS[lv] or lv == '' then prof.enabled[id] = nil end
                        end
                    end
                end
            end
        end
    end
    return profiles, dropped, notes
end

function M.serialize()
    local out = {
        '; SHODAN Stat Editor —— 护甲叠加（Super Earth Armory Forge 的选择部分）',
        '; 数值不在这个文件里: 数值取自 SHODAN 自己的护甲被动页, 这里只记「叠哪些」。',
        '; 可以把 ArmoryForge-NoBSL.ini 的内容拷进来（里面的数值行会被忽略）。',
        '[settings]',
        'name = SHODAN armory',
    }
    for _, id in ipairs(M.groups) do
        local p = M.profiles[id]
        if p then
            local n = chosen(p)
            if n > 0 or p.own == false then
                out[#out + 1] = ''
                out[#out + 1] = '[profile: ' .. (id == EVERY and 'Every armor' or BY_ID[id].name) .. ']'
                out[#out + 1] = 'conflicts = ' .. (p.conflicts == 'strongest' and 'strongest' or 'stack')
                out[#out + 1] = 'own_passive = ' .. (p.own == false and 'off' or 'on')
                local ids = {}
                for pid, on in pairs(p.enabled) do if on and BY_ID[pid] then ids[#ids + 1] = pid end end
                table.sort(ids)
                for _, pid in ipairs(ids) do out[#out + 1] = BY_ID[pid].name .. ' = on' end
            end
        end
    end
    return table.concat(out, '\n') .. '\n'
end

function M.load(path)
    M.path = path
    M.profiles = {}
    local f = path and io.open(path, 'rb')
    if not f then return false end
    local text = f:read('*a') or ''
    f:close()
    local profiles, dropped, notes = M.parse(text)
    M.profiles = profiles
    for _, n in ipairs(notes) do M.log('armory: ' .. n) end
    if dropped > 0 then
        M.log('armory: ' .. dropped .. ' 行数值已忽略（数值以 SHODAN 的护甲被动页为准）')
    end
    return true
end

function M.save()
    if not M.path then return end
    local f = io.open(M.path, 'wb')
    if not f then return end
    f:write(M.serialize())
    f:close()
    M.dirty = false
end

-- 第一次使用且没有自己的设置文件时, 试着接住模组留下的选择
function M.import(game, localappdata)
    local candidates = {}
    if game then
        candidates[#candidates + 1] = game .. '/ArmoryForge-NoBSL.ini'
        candidates[#candidates + 1] = game .. '/ArmoryForge-NoBSL.pending.ini'
    end
    if localappdata then candidates[#candidates + 1] = localappdata .. '/CowboyBingus/Helldivers2/ArmoryForge/loadout.ini' end
    for _, path in ipairs(candidates) do
        local f = io.open(path, 'rb')
        if f then
            local text = f:read('*a') or ''
            f:close()
            local profiles, dropped = M.parse(text)
            local ids = {}
            for id in pairs(profiles) do ids[#ids + 1] = id end
            if #ids > 0 then
                M.profiles = profiles
                M.imported = path
                M.log(string.format('armory: 从 %s 接住 %d 组选择（忽略 %d 行数值）', path, #ids, dropped))
                return path, dropped
            end
        end
    end
    return nil
end

function M.init(game, settings_path)
    M.game = game
    if not M.load(settings_path) then
        local home = (os.getenv('LOCALAPPDATA') or '.'):gsub('\\', '/')
        local imported = M.import(game, home)
        if imported then M.save() end
    end
end

-- 本页的选择 -> hostdata.M.stack 的三张表: stacks (护甲家族 id -> 要叠的被动 id), own_off
-- (家族 id -> true: 只留叠上来的, 原生被动关掉), policy (家族 id -> 'stack' | 'strongest')。
-- SHODAN 自己的护甲被动页 (state.stacks / state.own_off) 是底, 两边都开时取并集; 具体家族有设置就用它,
-- 否则用「所有护甲」(999)。ids: 这个游戏文件里真实存在的被动 id。
local function active(p) return p ~= nil and (chosen(p) > 0 or p.own == false) end

function M.selection(player_stacks, player_off, ids)
    local stacks, own, policy = {}, {}, {}
    for id, list in pairs(player_stacks or {}) do
        local t = {}
        for _, s in ipairs(list) do t[#t + 1] = s end
        stacks[id] = t
    end
    for id, off in pairs(player_off or {}) do if off then own[id] = true end end
    local function add(id, p)
        local list, seen = stacks[id] or {}, {}
        for _, s in ipairs(list) do seen[s] = true end
        for src, on in pairs(p.enabled) do
            if on and BY_ID[src] and src ~= id and not seen[src] then seen[src] = true; list[#list + 1] = src end
        end
        table.sort(list)
        stacks[id] = list
        if p.own == false then own[id] = true end
        policy[id] = p.conflicts == 'strongest' and 'strongest' or 'stack'
    end
    local every = M.profiles[EVERY]
    for _, id in ipairs(ids or {}) do
        if id ~= 0 then
            local p = M.profiles[id]
            if active(p) then add(id, p)
            elseif active(every) then add(id, every) end
        end
    end
    return stacks, own, policy
end

------------------------------------------------------------------ the page
local VK = { up = 0x26, down = 0x28, left = 0x25, right = 0x27, space = 0x20, enter = 0x0D,
             pgup = 0x21, pgdn = 0x22, home = 0x24, end_ = 0x23, esc = 0x1B, f3 = 0x72, f4 = 0x73 }

local C = {
    back = { 255, 12, 15, 19 },
    sel = { 255, 34, 56, 78 }, gold = { 255, 255, 213, 0 }, white = { 255, 238, 242, 246 },
    muted = { 255, 153, 171, 184 }, good = { 255, 120, 220, 140 }, warn = { 255, 255, 150, 60 },
}

M.open = false
local ui = { group = 1, row = 1, scroll = 1, was = {}, message = nil }

local function say(text) ui.message = { text = text, till = os.clock() + 4 } end

local function current()
    local id = M.groups[ui.group]
    return id, M.group(id)
end

local function rows()
    local gid, p = current()
    local out = {
        { kind = 'group', label = '护甲组  Armor group   (← → / F3 F4)', value = group_name(gid) },
        { kind = 'conflicts', label = '冲突策略  Conflicts   (空格切换)',
          value = p.conflicts == 'strongest' and '仅限最强 strongest' or '全部叠加 stack' },
        { kind = 'own', label = '本组原生被动  Native passive   (空格切换)',
          value = p.own == false and '关闭 off' or '保留 keep', yellow = p.own == false },
        { kind = 'all', label = '全部勾选 / 全部取消   (空格)', value = chosen(p) .. ' / ' .. #DATA.list },
    }
    for _, c in ipairs(DATA.list) do
        local on = p.enabled[c.id] and true or false
        out[#out + 1] = {
            kind = 'passive', id = c.id, label = '#' .. c.id .. '  ' .. c.zh, extra = c.name,
            value = c.id == gid and '本组自身' or (on and '[x]' or '[ ]'), on = on, self_group = c.id == gid,
        }
    end
    return out
end

local function act(dir)
    local list = rows()
    local r = list[ui.row]
    if not r then return end
    if r.kind == 'group' then
        ui.group = ((ui.group - 1 + dir) % #M.groups) + 1
        ui.row, ui.scroll = 1, 1
    elseif r.kind == 'conflicts' then
        local _, p = current()
        p.conflicts = p.conflicts == 'strongest' and 'stack' or 'strongest'
        M.dirty = true
    elseif r.kind == 'own' then
        local _, p = current()
        p.own = not p.own
        M.dirty = true
    elseif r.kind == 'all' then
        local gid, p = current()
        local all, n = true, 0
        for _, c in ipairs(DATA.list) do
            if c.id ~= gid then
                n = n + 1
                if not p.enabled[c.id] then all = false end
            end
        end
        p.enabled = {}
        if not all then for _, c in ipairs(DATA.list) do if c.id ~= gid then p.enabled[c.id] = true end end end
        M.dirty = true
        say(all and '本组已清空' or ('本组已全选 ' .. n .. ' 条'))
    elseif r.kind == 'passive' then
        if r.self_group then say('本组自己的被动不用叠（它本来就是这条记录）') return end
        local _, p = current()
        p.enabled[r.id] = (not p.enabled[r.id]) and true or nil
        M.dirty = true
    end
end

local function pressed(shim, name)
    local v = shim.key_down(VK[name])
    local was = ui.was[name]
    ui.was[name] = v
    return v and not was
end

function M.frame(shim)
    if not M.open then return end
    local s = shim.h / 1080
    local size = 19 * s
    local row_h = 28 * s

    shim.fill(0, 0, shim.w, shim.h, C.back)
    shim.text('护甲叠加   Super Earth Armory Forge   (F5 关闭)', 40 * s, 40 * s, 25 * s, C.gold, true)
    local groups, total = M.count()
    shim.text('词条数值取自 SHODAN 的护甲被动页；这一页只决定「哪个护甲家族叠哪些被动」   已设 '
        .. groups .. ' 组 / ' .. total .. ' 条   ' .. (M.imported and ('（已接住模组的设置）') or ''),
        40 * s, 72 * s, 15 * s, C.muted)

    local list = rows()
    local visible = 24
    if ui.row < ui.scroll then ui.scroll = ui.row end
    if ui.row > ui.scroll + visible - 1 then ui.scroll = ui.row - visible + 1 end
    if ui.scroll < 1 then ui.scroll = 1 end
    local y = 104 * s
    for i = ui.scroll, math.min(#list, ui.scroll + visible - 1) do
        local r = list[i]
        local top = y + (i - ui.scroll) * row_h
        if i == ui.row then shim.fill(30 * s, top, shim.w - 30 * s, top + row_h, C.sel) end
        local color = C.white
        if r.kind == 'passive' then color = r.self_group and C.muted or (r.on and C.good or C.muted) end
        if r.yellow then color = C.gold end
        shim.text(r.label, 48 * s, top + row_h * 0.74, size, color)
        if r.extra then
            shim.text('  ' .. r.extra, 48 * s + shim.text_width(r.label, size), top + row_h * 0.74,
                size * 0.85, C.muted)
        end
        if r.value then
            local vw = shim.text_width(r.value, size)
            shim.text(r.value, shim.w - 60 * s - vw, top + row_h * 0.74, size,
                i == ui.row and C.gold or (r.kind == 'passive' and color or C.white))
        end
    end
    shim.flush()

    -- 底部: 高亮被动有哪些效果 (名字来自模组自己的表), 然后是按键提示
    local r = list[ui.row]
    if r and r.kind == 'passive' then
        local c = BY_ID[r.id]
        local parts = {}
        for _, e in ipairs(c.effects) do parts[#parts + 1] = e.label end
        local line = table.concat(parts, ' · ')
        if c.armors ~= '' then line = line .. '    护甲: ' .. c.armors end
        local fit = 15 * s
        while fit > 9 * s and shim.text_width(line, fit) > shim.w - 80 * s do fit = fit - 0.5 end
        shim.text(line, 40 * s, shim.h - 76 * s, fit, C.muted)
    end
    shim.text('↑↓ 选择    ←→ 切换开关/换组    空格 切换    F3 / F4 上/下一组    PgUp/PgDn 快速移动    F5 / ESC 返回',
        40 * s, shim.h - 42 * s, 15 * s, C.muted)
    if ui.message and os.clock() < ui.message.till then
        shim.text(ui.message.text, 40 * s, shim.h - 106 * s, 15 * s, C.warn)
    end

    if pressed(shim, 'esc') then M.close()
    elseif pressed(shim, 'f3') then ui.group = ((ui.group - 2) % #M.groups) + 1; ui.row, ui.scroll = 1, 1
    elseif pressed(shim, 'f4') then ui.group = (ui.group % #M.groups) + 1; ui.row, ui.scroll = 1, 1
    elseif pressed(shim, 'up') then ui.row = math.max(1, ui.row - 1)
    elseif pressed(shim, 'down') then ui.row = math.min(#list, ui.row + 1)
    elseif pressed(shim, 'pgup') then ui.row = math.max(1, ui.row - 10)
    elseif pressed(shim, 'pgdn') then ui.row = math.min(#list, ui.row + 10)
    elseif pressed(shim, 'home') then ui.row, ui.scroll = 1, 1
    elseif pressed(shim, 'end_') then ui.row = #list
    elseif pressed(shim, 'left') then act(-1)
    elseif pressed(shim, 'right') then act(1)
    elseif pressed(shim, 'space') or pressed(shim, 'enter') then act(1)
    end
    shim.present()
end

function M.is_open() return M.open end

-- 编辑器自己的 tick 会画面板、也会抢键盘: 本页打开时先把它摘下来
local function park(on)
    local bus = rawget(_G, 'OCLAW_UPDATE_BUS')
    if type(bus) == 'table' and type(bus.jobs) == 'table' then
        if on then
            M._parked = bus.jobs['ShodanStatEditor']
            bus.jobs['ShodanStatEditor'] = nil
        elseif M._parked then
            bus.jobs['ShodanStatEditor'] = M._parked
            M._parked = nil
        end
    end
end

function M.show()
    if M.open then return end
    M.open = true
    ui.row, ui.scroll, ui.was = 1, 1, {}
    for i, id in ipairs(M.groups) do
        local p = M.profiles[id]
        if p and (chosen(p) > 0 or p.own == false) then ui.group = i; break end
    end
    park(true)
end

function M.close()
    if not M.open then return end
    M.open = false
    park(false)
    if M.dirty then
        local ok, why = pcall(M.save)
        if not ok then say('设置没存上: ' .. tostring(why)) end
    end
end

function M.summary()
    local groups, total = M.count()
    if groups == 0 then return '护甲叠加：未设' end
    return '护甲叠加：' .. groups .. ' 组 / ' .. total .. ' 条'
end

return M
