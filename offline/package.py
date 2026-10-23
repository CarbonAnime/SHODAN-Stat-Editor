"""Packs SHODAN Stat Editor Offline: the launcher, LuaJIT, libsodium, the host and the built stat_editor.lua.
  python package.py [<name>]   ->  ../addons/stat_editor/release/<name>.zip (in the GitHub repository: release/) (default SHODAN-Stat-Editor-Offline-v<version>)"""
import os, re, subprocess, sys, zipfile
HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, '..', 'addons', 'stat_editor')
PANEL = os.path.join(ADDON, 'stat_editor_offline.lua')   # build.py --offline
if not os.path.exists(PANEL):                             # the GitHub repository: the built panel is src/'s
    PANEL = os.path.join(HERE, '..', 'src', 'stat_editor_offline.lua')
RELEASE = os.path.join(ADDON if os.path.isdir(ADDON) else HERE, 'release')
TOP = 'SHODAN Stat Editor Offline'
files = {
    'SHODAN Stat Editor Offline.exe': os.path.join(HERE, 'launcher', 'SHODAN Stat Editor Offline.exe'),
    'lua51.dll': os.path.join(HERE, 'runtime', 'lua51.dll'),
    'libsodium.dll': os.path.join(HERE, 'runtime', 'libsodium.dll'),
    'shodan_hash.dll': os.path.join(HERE, 'launcher', 'shodan_hash.dll'),
    'app/stat_editor.lua': PANEL,
}
for m in ('host', 'engine_shim', 'install', 'gamedata', 'hostdata', 'update', 'armory', 'armory_data'):
    files['app/%s.lua' % m] = os.path.join(HERE, m + '.lua')
# the armory (weapon passives, vehicle parts) and the MCP server, kept by this fork: see README-FORK.md
for m in ('README-FORK.md', 'CHANGES.txt'):
    if os.path.exists(os.path.join(HERE, '..', m)):
        files[m] = os.path.join(HERE, '..', m)
for m in ('stat_editor_mcp.py', 'README.md'):
    if os.path.exists(os.path.join(HERE, 'mcp', m)):
        files['mcp/' + m] = os.path.join(HERE, 'mcp', m)
DEV = re.compile(r'[ \t]*--\[\[DEV\]\].*?--\[\[/DEV\]\][^\n]*\n', re.S)   # test hooks: not in the package
VERSION = re.search(r"version = '([\d.]+)'", open(PANEL, encoding='utf-8').read()).group(1)
readme = r"""SHODAN Stat Editor Offline v{version}  (SSEO)
by SHODAN - https://github.com/SHODAN-HORAI/SHODAN-Stat-Editor

Change the stats of weapons, throwables, stratagems, vehicles, attachments and armor passives in Helldivers 2's
own data files. No mod loader, and the game does not need to run: the changes apply when the game starts.

HOW TO USE
1. Close Helldivers 2.
2. Start "SHODAN Stat Editor Offline.exe" (keep it in this folder, next to "app" and the .dll files).
   It finds the game through Steam. If it cannot, write the path of your Helldivers 2 folder into
   %LOCALAPPDATA%\SHODAN\StatEditor\game folder.txt and start it again.
3. Change values in the panel. Settings > Language: English, Simplified Chinese, Traditional Chinese, Russian.
4. Press "Install into the game", then start the game.

"Restore the game's files" puts the game's own files back. The originals are kept in
%LOCALAPPDATA%\SHODAN\StatEditor\originals, with your values, presets and logs.
After a game update, or Steam's "Verify integrity of game files", the game's own files are back:
start SSEO and press Install again.

UPDATES
At start SSEO asks GitHub for its latest release. When there is a newer one, "Update to v..." appears at the
top right: it downloads the release, swaps the new files in next to the program and restarts it. Your values,
presets and the game's originals stay as they are. Settings > Updates: Ask (the button) or Automatic (updates
at start without asking). Settings > Update channel: Releases (tested versions) or Every commit (the development
build of every change, before testing: it may break).

NOT AVAILABLE OFFLINE
Grenade swaps, speedloader / clip sizes and unlocking unused items need the running game.
Projectile swaps work, but a swapped projectile has its trail only if someone in the mission carries
the weapon it comes from. Arc chain length / split also apply with other players.

GOOD TO KNOW
- Windows SmartScreen or an antivirus may warn about the program the first time (it is not signed).
- SSEO changes the game's data files. The changed files keep the checksum the game expects, but use it at
  your own risk, and keep to private games with friends if in doubt.
- Licences: SSEO is GPL-3.0 (see the GitHub page). It ships LuaJIT (MIT) and libsodium (ISC):
  see THIRD-PARTY-NOTICES.txt.
"""
# app/build.txt: which build this is, for the updater (a development build is new when its commit differs).
# The commit: SSEO_COMMIT (the CI's), else the GitHub repository's HEAD (package after committing a release).
REPO = os.path.join(HERE, '..') if not os.path.isdir(ADDON) else os.path.join(HERE, '..', '..', 'github', 'SHODAN-Stat-Editor')
CHANNEL = os.environ.get('SSEO_CHANNEL', 'release')
COMMIT = os.environ.get('SSEO_COMMIT', '')
if not COMMIT and os.path.isdir(os.path.join(REPO, '.git')):
    git = lambda *a: subprocess.run(['git', '-C', REPO] + list(a), capture_output=True, text=True).stdout.strip()
    COMMIT = git('rev-parse', 'HEAD')
    if git('status', '--porcelain', '--untracked-files=no'):
        print('note: the repository has uncommitted changes; build.txt names its HEAD', COMMIT[:7])
build_txt = 'version=%s\ncommit=%s\nchannel=%s\n' % (VERSION, COMMIT, CHANNEL)
os.makedirs(RELEASE, exist_ok=True)
name = sys.argv[1] if len(sys.argv) > 1 else 'SHODAN-Stat-Editor-Offline-v' + VERSION
out = os.path.join(RELEASE, name + '.zip')
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for arc, src in sorted(files.items()):
        if arc.startswith('app/') and arc != 'app/stat_editor.lua':
            text = DEV.sub('', open(src, encoding='utf-8').read())
            assert 'DEV' not in text and 'SHODAN_HOST_TEST' not in text, arc
            z.writestr(TOP + '/' + arc, text)
        else:
            z.write(src, TOP + '/' + arc)
    z.writestr(TOP + '/README.txt', readme.format(version=VERSION).replace('\n', '\r\n'))
    z.writestr(TOP + '/app/build.txt', build_txt)
    notices = [open(os.path.join(HERE, 'licenses', n), encoding='utf-8').read().strip() for n in ('LuaJIT.txt', 'libsodium.txt')]
    z.writestr(TOP + '/THIRD-PARTY-NOTICES.txt', ('\n\n' + '=' * 79 + '\n\n').join(notices).replace('\n', '\r\n') + '\r\n')
print(out, os.path.getsize(out) // 1024, 'KB;', build_txt.replace('\n', ' '))
