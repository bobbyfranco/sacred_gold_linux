#!/usr/bin/env bash
exec python3 - "$0" "$@" <<'PYTHON_INSTALLER'
import argparse
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

PAYLOAD_SHA256 = '828c01e32bfa2f6b39e22ff51324cd839276eddc60898ea6cd638b7aa8c005c9'
MARKER = b'\n__SACRED_PAYLOAD__\n'

parser = argparse.ArgumentParser(description='Install the patched Sacred Gold game to a folder of your choice.')
parser.add_argument('--install-dir', type=Path, help='Destination game folder; opens a dialog when omitted')
parser.add_argument('--no-shortcut', action='store_true', help='Do not add an applications-menu shortcut')
parser.add_argument('--check', action='store_true', help='Verify the embedded game archive without installing')
parser.add_argument('--shortcut-dir', type=Path, help=argparse.SUPPRESS)
args = parser.parse_args(sys.argv[2:])
installer = Path(sys.argv[1]).resolve()
gui = args.install_dir is None and not args.check and shutil.which('zenity') and (os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY'))

def dialog(kind, message):
    if gui:
        subprocess.run(['zenity', kind, '--title=Sacred Gold', '--text=' + message, '--no-markup'], check=False)
    else:
        print(message, file=sys.stderr if kind == '--error' else sys.stdout)

def desktop_string(value):
    return str(value).replace('\\', '\\\\').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t')

def desktop_exec(path):
    # Desktop Exec has its own quoting and percent field-code rules.
    value = str(path).replace('%', '%%')
    for char in ('\\', '"', '`', '$'):
        value = value.replace(char, '\\' + char)
    return desktop_string('"' + value + '"')

def payload_offset(stream):
    header = stream.read(65536)
    pos = header.find(MARKER)
    if pos < 0:
        raise RuntimeError('The embedded game archive was not found.')
    return pos + len(MARKER)

def verify(stream, offset):
    stream.seek(offset)
    digest = hashlib.sha256()
    while block := stream.read(4 * 1024 * 1024):
        digest.update(block)
    if digest.hexdigest() != PAYLOAD_SHA256:
        raise RuntimeError('The installer archive is damaged. Copy the installer again.')
    stream.seek(offset)

def main():
    if not shutil.which('tar') or not shutil.which('zstd'):
        raise RuntimeError('Please install tar and zstd before using this installer.')
    if not args.check and args.install_dir is None:
        default = Path.home() / 'Games' / 'Sacred Gold'
        if gui:
            result = subprocess.run(['zenity', '--entry', '--title=Install Sacred Gold',
                '--text=Choose the folder where Sacred Gold will be installed:',
                '--entry-text=' + str(default)], capture_output=True, text=True)
            if result.returncode:
                return
            args.install_dir = Path(result.stdout.strip()).expanduser()
        else:
            response = input(f'Install folder [{default}]: ').strip()
            args.install_dir = Path(response).expanduser() if response else default
    with installer.open('rb') as stream:
        offset = payload_offset(stream)
        verify(stream, offset)
        if args.check:
            print('Embedded game archive checksum verified.')
            return
        target = args.install_dir.expanduser().resolve()
        if target.exists():
            raise RuntimeError(f'The destination already exists. Choose a new folder:\n{target}')
        if any(c in str(target) for c in '\n\r'):
            raise RuntimeError('Choose a folder without newline characters in its name.')
        target.parent.mkdir(parents=True, exist_ok=True)
        if shutil.disk_usage(target.parent).free < 3 * 1024**3:
            raise RuntimeError('The destination needs at least 3 GB of free space.')
        print(f'Installing Sacred Gold into {target}', flush=True)
        progress = None
        if gui:
            progress = subprocess.Popen(['zenity', '--progress', '--pulsate', '--auto-close', '--no-cancel',
                '--title=Installing Sacred Gold', '--text=Copying the game files…'], stdin=subprocess.PIPE)
        try:
            with tempfile.TemporaryDirectory(prefix='.sacred-install-', dir=target.parent) as stage:
                subprocess.run(['tar', '--zstd', '--no-same-owner', '-xf', '-', '-C', stage], stdin=stream, check=True)
                game = Path(stage) / 'Sacred-Portable'
                if not (game / 'run-sacred').is_file() or not (game / 'sacred').is_file():
                    raise RuntimeError('The game files in the installer are incomplete.')
                # The legacy uninstaller targets the original system installation.
                (game / 'uninstall').unlink(missing_ok=True)
                shutil.rmtree(game / '.manifest', ignore_errors=True)
                (game / 'run-sacred').chmod(0o755)
                (game / 'sacred').chmod(0o755)
                if target.exists():
                    raise RuntimeError('The destination was created during installation; choose a new folder.')
                game.rename(target)
        finally:
            if progress:
                progress.stdin.close()
                progress.wait()
        shortcut_note = ''
        if not args.no_shortcut:
            shortcut_dir = args.shortcut_dir or Path(os.environ.get('XDG_DATA_HOME', str(Path.home() / '.local/share'))) / 'applications'
            shortcut_dir.mkdir(parents=True, exist_ok=True)
            identity = hashlib.sha256(str(target).encode()).hexdigest()[:12]
            shortcut = shortcut_dir / f'sacred-gold-{identity}.desktop'
            shortcut.write_text('[Desktop Entry]\nType=Application\nName=Sacred Gold\n'
                'Comment=Explore Ancaria\n'
                f'Exec={desktop_exec(target / "run-sacred")}\n'
                f'Path={desktop_string(target)}\n'
                f'Icon={desktop_string(target / "icon.xpm")}\n'
                'Terminal=false\nCategories=Game;RolePlaying;\n', encoding='utf-8')
            (target / 'INSTALLATION.txt').write_text(
                f'Installed game: {target}\nApplications shortcut: {shortcut}\n\n'
                'To uninstall, delete this game folder and the shortcut listed above.\n'
                'Saves are in ~/.lgp/sacred and are preserved when you remove the game.\n'
                'If you move this folder after installing, launch run-sacred directly;\n'
                'the applications-menu shortcut refers to the installation location.\n', encoding='utf-8')
            if shutil.which('update-desktop-database'):
                subprocess.run(['update-desktop-database', str(shortcut_dir)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            shortcut_note = '\nYou can now launch Sacred Gold from the applications menu.'
        dialog('--info', f'Sacred Gold is installed in:\n{target}{shortcut_note}\n\nYou can also run the run-sacred file in that folder.')

try:
    main()
except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
    dialog('--error', str(exc))
    sys.exit(1)
PYTHON_INSTALLER
exit $?
