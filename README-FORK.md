# SHODAN Stat Editor Offline - this fork

Fork of [SHODAN-HORAI/SHODAN-Stat-Editor](https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor) that keeps an
armoury line on top of upstream's releases. Everything upstream has still works; the list below is what this fork
adds. It is carried as a merge of the `feat/armory-*` branch onto the upstream release commit, so a new upstream
release can be taken by merging again (see "Taking a new upstream release").

## What the fork adds

- **Armoury tab** (`offline/armory.lua`, `offline/armory_data.lua`): armour passives with their effects, stacked
  passives (up to three effects, each with its description), and vehicle part health and armour - rows are
  generated per part instead of a single hull value.
- **Move while reloading keeps its row**
  That switch used to exist only while it was off, so turning it on made the row vanish and the value you saved
  was refused. Any weapon with a reload now shows the row either way.
- **A record you edited stays in the Records tab**: installing a change re-reads every object it touched, and a
  projectile, explosion or status record page was re-read as if it were a weapon - which emptied it. The list
  only shows pages that have rows, so that record then vanished from the Records tab and from search for the rest
  of the session. Record pages no longer go through the weapon pass, keep the rows they already have while the
  tables are half read, and an empty page is never cached.
- **A projectile id that can be changed**: a table that holds one block has no other block's salt to borrow, so a
  u32-only change (a projectile id, an explosion id, a shrapnel count) used to end with
  "nothing to vary for the hash" and the whole install aborted. `offline/hostdata.lua` now borrows a nearby
  float and moves it by a fraction of its own value (under 0.1%) when the change has no float of its own. The
  hash still matches; the borrowed value stays inside the game's noise.
- **Text typed through the window**: `offline/engine_shim.lua` takes WM_CHAR from the window procedure and hands
  the characters to the panel (`Application.typed_text()`), so an IME (Chinese, Japanese, Korean) reaches the
  search field. Key polling stays as the fallback.
- **A resizable window and a laid-out bar**: the window can be resized and maximised; the bottom bar lays its
  buttons out from the window width; sizes scale with the screen; the position is remembered.
- **Three languages, searched in their own script**: names, kinds and part labels have zh-Hans, zh-Hant and ru
  translations, and the search box matches the translated name as well.
- **An MCP server** (`offline/mcp/stat_editor_mcp.py`): an AI assistant can list weapons, read a weapon's stats,
  set a stat, install or restore, over stdio. `--game DIR` edits a copy instead of the live install.
- **The rows the game's own data has, shown by name**: the projectile and explosion record pages now carry
  simulation steps, lifetime and its randomness, decal size, both impact types, the full ricochet block (max
  ricochets, threshold angle and speed, angle loss, both spreads), the effect templates (hit effect, fire,
  status volume, raycast), the three audio events, the +244 flag half word with the two bits that have a name,
  and - on an explosion - terrain deformation, surface impact, noise and wind templates and the arc type.
  Weapon pages gained simulation steps, lifetime, lifetime randomness and max ricochets. The enum fields show
  the game's own number: this build ships no name table, so the editor names nothing it cannot prove.
- **Every value button clicks again in a wide window**: the value row's click region is registered before its
  five buttons instead of over them, so `--`, `-`, `+`, `++` and `R` reach the buttons; the scroll bar and the
  page buttons move with the value column instead of staying at a fixed x.
- **A proximity fuse that works**: the blast angle (+136) and the blast proximity (+148) have to move together -
  the angle to 360 and the radius large enough. A crossbow bolt bursts in flight at 360 with 6 m; 3 m at 80 did
  nothing. The record page's angle now goes up to 360 (it stopped at 180, and 360 is what the airburst rounds
  use), the weapon page has its own blast angle row, and both hints carry the measured result, including "keep
  the radius above about speed / frame rate" - a 500 m/s bolt covers 4.2 m per 120 Hz tick, so a 3 m sphere is skipped.
- **Updates come from this fork.** `offline/update.lua` points at `CarbonAnime/SHODAN-Stat-Editor`, so an
  update keeps the armoury; upstream's zip would replace the panel with one that has none.

## Building

The release zip is built by `.github/workflows/dev-build.yml` (LuaJIT at the commit the releases use, libsodium
official build) and `offline/package.py` packs it. By hand:

1. MSVC 2022 (x64) and a built LuaJIT (`lua51.lib`, `lua51.dll`) in `offline/runtime/` together with
   `libsodium.dll`.
2. `offline/launcher/build.bat` builds `SHODAN Stat Editor Offline.exe` and `shodan_hash.dll`
   (hash search, the downloader and the installer).
3. `python offline/package.py [name]` writes `offline/release/<name>.zip`.

## Taking a new upstream release

```
git fetch upstream && git checkout -b feat/armory-<version> upstream/main
git merge feat/armory-<previous>          # four files usually conflict: hostdata, host, engine_shim, the panel
python tests/luac.py && python tests/run_headless.py
```

The conflicts are in the same places every time: the passive stacking in `offline/hostdata.lua`, the bottom bar
and the window in `offline/host.lua` and `offline/engine_shim.lua`, and the weapon-list row and the value-row
label in `src/stat_editor_offline.lua`. Keep upstream's behaviour and re-apply the fork's additions on top.

## 中文说明

本 Fork 在上游 v3.2.1 基础上保留并整合了魔改内容：军械库页（护甲被动、载具部件血量与护甲）、可修改发射的
射弹 ID（借盐修复，单块表也能装机）、支持输入法打中文搜索、窗口可缩放、三语言名称与搜索、以及 MCP 服务器。
v3.2.1 起：射弹与爆炸记录页补齐了游戏自带数据里的字段（模拟步数、寿命与随机寿命、贴花尺寸、表面/跳弹碰撞类型、
跳弹整组、效果模板、音频事件、标志位位域；爆炸页另有弹坑/地形形变、表面碰撞、噪音与风效模板、电弧类型），
武器页也加了模拟步数、寿命、随机寿命与最大跳弹数；并修好了宽窗口下数值列右侧 --/-/+/++/R 点不动、
以及滚动条错位的问题。
更新源指向本 Fork 的 Releases，因此点"更新"不会把魔改版换回原版。
v3.2.2 起：近炸引信可用 —— 爆炸角（+136）必须 360、爆炸接近度（+148）必须够大，实测 CB-9 弩箭 360° + 6 米在飞行中起爆；
射弹页爆炸角上限放宽到 360、武器页新增爆炸角行，说明里写明实测结论与「半径建议大于初速/120」。
MCP 服务器补齐 blast_angle / fuse_proximity / fuse_delay / arming / sim_steps / lifetime_random / max_ricochets 字段，
并修正 lifetime 的偏移（+52，原先是 +56 随机寿命）。
