# SHODAN Stat Editor Offline - this fork

Fork of [SHODAN-HORAI/SHODAN-Stat-Editor](https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor) that keeps an
armoury line on top of upstream's releases. Everything upstream has still works; the list below is what this fork
adds. It is carried as a merge of the `feat/armory-*` branch onto the upstream release commit, so a new upstream
release can be taken by merging again (see "Taking a new upstream release").

## What the fork adds

- **Armoury tab** (`offline/armory.lua`, `offline/armory_data.lua`): armour passives with their effects, stacked
  passives (up to three effects, each with its description), and vehicle part health and armour - rows are
  generated per part instead of a single hull value.
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

本 Fork 在上游 v3.2.0 基础上保留并整合了魔改内容：军械库页（护甲被动、载具部件血量与护甲）、可修改发射的
射弹 ID（借盐修复，单块表也能装机）、支持输入法打中文搜索、窗口可缩放、三语言名称与搜索、以及 MCP 服务器。
更新源指向本 Fork 的 Releases，因此点"更新"不会把魔改版换回原版。
