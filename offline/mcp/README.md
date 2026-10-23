# SHODAN Stat Editor MCP server

`stat_editor_mcp.py` gives scripts and AI agents the same reach as SSEO's window: it finds the game,
opens the sealed tables in `data\game`, names their records, edits values in memory, and puts the
changed files back with the checksum `game.dll` expects. No mod loader, no game running, no Lua --
Python 3.8 or newer and the two DLLs the release already ships.

It is one file and uses the standard library only. Run it as a command line, or with no arguments to
serve the [Model Context Protocol](https://modelcontextprotocol.io) on stdin/stdout.

## Requirements

- Windows and Python 3.8 or newer; there is nothing to `pip install`.
- `libsodium.dll` and `shodan_hash.dll` from the release folder next to
  `SHODAN Stat Editor Offline.exe` (`--native-dir`, or `SHODAN_NATIVE_DIR`). libsodium opens and
  seals the files; shodan_hash is what makes a checksum correction take milliseconds instead of
  minutes -- without it the pure Python search runs.
- Helldivers 2, for `...\steamapps\common\Helldivers 2\data\game` only. The game does not run.

## Command line

```
python offline\mcp\stat_editor_mcp.py selftest
python offline\mcp\stat_editor_mcp.py status
python offline\mcp\stat_editor_mcp.py weapons grenade
python offline\mcp\stat_editor_mcp.py weapon "GL-21 Grenade Launcher"
python offline\mcp\stat_editor_mcp.py explosions 7.5
python offline\mcp\stat_editor_mcp.py set "GL-21 Grenade Launcher" calibre 60
python offline\mcp\stat_editor_mcp.py set "GL-21 Grenade Launcher" calibre 60 --save
python offline\mcp\stat_editor_mcp.py set-explosion "GL-21 Grenade Launcher" impact 361 --save
python offline\mcp\stat_editor_mcp.py changes
python offline\mcp\stat_editor_mcp.py save --yes
python offline\mcp\stat_editor_mcp.py verify
python offline\mcp\stat_editor_mcp.py restore --yes
```

Start with `selftest`: it writes nothing and checks the game folder, the tables it opens, every file
against the hashes in `game.dll`, and one checksum correction with a float edit.

`set` and `set-explosion` only change memory; `--save` writes it. `save` and `restore` are dry
runs without `--yes`. Everything that takes time (opening 55 files) happens once per run.

Options:

| Option | Meaning |
|---|---|
| `--game DIR` | the `data\game` folder (default: the folder the window remembered, then Steam) |
| `--native-dir DIR` | the folder holding `libsodium.dll` and `shodan_hash.dll` |
| `--hash-dll PATH` | `shodan_hash.dll` on its own |
| `--panel PATH` | `src/stat_editor.lua`, the weapon list (default: the checkout this file sits in) |
| `--json` | `status`, `changes`, `verify`, `save` and `restore` report as JSON instead of text |
| `--save` | with `set` / `set-explosion`: write into the game as well |
| `--yes` | with `save` / `restore`: really write instead of a dry run |

Exit codes: **0** ok, **2** usage, **3** no game folder, **4** refused (the game is running, or a
weapon this build does not have), **5** a check failed.

## Register it with an AI client

```json
{
  "mcpServers": {
    "shodan-stat-editor": {
      "command": "python",
      "args": ["C:\\path\\to\\offline\\mcp\\stat_editor_mcp.py"],
      "env": { "SHODAN_NATIVE_DIR": "C:\\path\\to\\SHODAN Stat Editor Offline" }
    }
  }
}
```

The server speaks protocol `2024-11-05`: `initialize`, `tools/list` and `tools/call`, one JSON
object per line, and nothing but protocol replies on stdout.

## Tools

| Tool | Arguments | What it does |
|---|---|---|
| `game_status` | -- | the game folder, whether the game is running, the tables it opened, what is edited but not saved (read only) |
| `list_weapons` | `query`, `limit`, `offset` | the panel's weapon list: name, slot, 16 hex digit entity hash (read only) |
| `get_weapon` | `weapon` | every value of one weapon: handling, fire mode, magazine, reload, heat, its projectile, that projectile's damage and the explosions it sets off (read only) |
| `list_explosions` | `query`, `limit`, `offset` | the explosion records of this build, with the damage each one does and how many projectiles set it off (read only) |
| `set_stat` | `weapon`, `stat`, `value` | set one named field (in memory) |
| `set_explosion_id` | `weapon`, `which` (`impact`/`expiry`), `explosion_id` | choose which explosion a projectile sets off when it hits, or when it expires; 0 is none |
| `save` | `dry_run` (default `true`) | correct the checksums and write the changed files into the game |
| `restore` | `dry_run` (default `true`) | put the game's own files back |
| `verify` | -- | open every file and check it against `game.dll` (read only) |
| `list_changes` | -- | what is edited and not saved: file, byte ranges, every field with its old and new value (read only) |

`weapon` is a name from `list_weapons`, a unique part of one, or the 16 hex digit entity hash -- the
hash is the way to reach weapons newer than the panel's list.

## Stat names

`set_stat` takes the names `get_weapon` prints, looked up in this order: the weapon's own
tables, then its projectile, that projectile's damage record, then the explosions it sets off.

| Table | Names |
|---|---|
| weapon | `recoil_h_start`, `recoil_h_end`, `recoil_v_start`, `recoil_v_end`, `spread`, `spread_aim`, `sway`, `aim_block_length`, `suppressed`, `aim_zoom`, `scope_sway`, `noise`, `burst`, `fire_mode`, `ergonomics`, `crosshair` |
| fire mode | `projectile`, `rpm_x`, `rpm`, `rpm_z`, `zeroing_slots`, `zeroing_hipfire`, `projectile_entity`, `spinup` |
| magazine | `capacity`, `magazines`, `refill`, `max_magazines`, `reload_threshold`, `chambered` |
| reload | `reload_time` |
| weapon heat | `overheat_temperature`, `warning_temperature`, `emission_temperature`, `heat_per_shot`, `cooling`, `cooling_overheated`, `firing_charge`, `charge_gain`, `charge_loss`, `reset_charge` |
| projectile | `calibre`, `pellets`, `speed`, `mass`, `drag`, `gravity`, `lifetime`, `damage_id`, `pen_slowdown`, `impact_explosion`, `expiry_explosion` |
| damage | `damage`, `durable`, `ap_direct`, `ap_slight`, `ap_large`, `ap_extreme`, `demolition`, `stagger`, `push`, `element` |
| explosion | `damage_id`, `inner_radius`, `outer_radius`, `shockwave`, `fragments`, `fragment_projectile`, `arc` |

A value a weapon does not have (heat on a grenade launcher, a magazine on a laser) is an error, not
a write to somebody else's record.

## How a change reaches the game

Reading is one pass: 55 sealed files are opened, their tables parsed, and the records named by the
same offsets the panel uses. Editing only changes that copy in memory.

`save` re-seals each changed file and gives it back the murmur64 hash `game.dll` holds for it. The
editor does that by writing the correction into the reserved bytes of the file's last block header,
which is what "keeps the checksum the game expects" means. Two files (`generated_projectile_settings`,
`generated_explosion_settings`) consist of a single block: there is no spare header byte there, so
when nothing with decimals was edited the correction borrows one float of the record you touched and
moves it by a few units in the last place. The report says which one (`nudged`), and the change is
thousands of times smaller than the smallest step the game can show. Without that, a change that only
touches whole numbers -- an explosion id, for instance -- could not be installed at all.

The game's own files are kept in `%LOCALAPPDATA%\SHODAN\StatEditor\originals`, the list of what was
written in `installed.txt`, both shared with the window.

## Sharing the game folder with the window

The server and SSEO read the same files and keep their own copy in memory. Save from one, then start
the other (or restart it) -- do not have both open on the same file and press save in each in turn,
or the later write wins with the older numbers. Neither writes while Helldivers 2 runs: both refuse.

## What it does not do

The in-game features -- grenade swap, rounds per reload / clip sizes, unlocking unused items (M-104
Incinerator FRV, P-41 Ombudsman, G-11 Caltrops, LAS-22 Shear) -- need the running game and exist only
in the panel. Stratagem and attachment tables are opened and counted, but no tool names their fields
yet; the panel edits them.
