#!/usr/bin/env python3
"""Exercise maintenance code in an unprivileged fixture root, never /Applications or launchd."""
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

repo = Path(__file__).resolve().parent.parent
binary = repo / 'build/native-tests/maintenance-fixture'
binary.parent.mkdir(parents=True, exist_ok=True)
subprocess.run(['xcrun', 'clang++', '-std=c++17', '-O1', '-fobjc-arc', '-fblocks',
                '-DMEQ_INSTALLER_FIXTURE', '-fsanitize=address,undefined', '-fno-sanitize-recover=all',
                '-I', str(repo / 'Sources/CTransport'), str(repo / 'Installer/Tools/Maintenance.mm'),
                '-framework', 'Foundation', '-framework', 'Security', '-o', str(binary)], check=True)

def populate(root):
    support = root / 'Library/Application Support/myEq'
    support.mkdir(parents=True)
    for src, dst in [
        (repo / 'build/artifacts.noindex/myEq.app', root / 'Applications/myEq.app'),
        (repo / 'build/native/myEq.driver', root / 'Library/Audio/Plug-Ins/HAL/myEq.driver'),
    ]:
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(src, dst)
    for name in ['myEqBridge', 'myEqMaintenance']:
        shutil.copy2(repo / 'build/native' / name, support / name)
    daemon = root / 'Library/LaunchDaemons/com.tc.myEq.bridge.plist'
    daemon.parent.mkdir(parents=True)
    shutil.copy2(repo / 'Installer/com.tc.myEq.bridge.plist', daemon)
    subprocess.run(['python3', 'scripts/package-trust.py', 'installer', str(support / 'trust.plist'),
                    str(root / 'Applications/myEq.app')], cwd=repo, check=True, capture_output=True)
    os.chmod(root / 'Applications', 0o775)  # The normal system Applications mode is supported.
    return support

def run(root, op, success):
    result = subprocess.run([str(binary), str(root), op], text=True, capture_output=True, timeout=30)
    if (result.returncode == 0) != success:
        raise AssertionError((op, result.returncode, result.stderr))
    if 'AddressSanitizer' in result.stderr or 'runtime error:' in result.stderr:
        raise AssertionError(result.stderr)
    return result.stdout.strip()

def resign_and_update(bundle, manifest, role):
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True, capture_output=True)
    detail = subprocess.run(['codesign', '-d', '--verbose=4', str(bundle)], check=True, capture_output=True, text=True).stderr
    trust = plistlib.loads(manifest.read_bytes())
    trust[role] = re.search(r'^CDHash=([0-9a-f]{40})$', detail, re.M).group(1)
    manifest.write_bytes(plistlib.dumps(trust))

with tempfile.TemporaryDirectory(prefix='myeq-installer-test-', dir='/private/tmp') as tmp:
    base = Path(tmp)
    for case in ['valid', 'legacy_background', 'bad_process_type', 'symlink', 'maintenance_symlink', 'hardlink', 'writable', 'acl', 'forged_helper', 'bad_manifest', 'bad_daemon', 'truncated', 'missing']:
        root = base / case
        root.mkdir()
        support = populate(root)
        victim = base / (case + '-unrelated')
        victim.write_bytes(b'unrelated fixture data')
        bridge = support / 'myEqBridge'
        if case in ('legacy_background', 'bad_process_type'):
            p = root / 'Library/LaunchDaemons/com.tc.myEq.bridge.plist'
            job = plistlib.loads(p.read_bytes())
            job['ProcessType'] = 'Background' if case == 'legacy_background' else 'Standard'
            p.write_bytes(plistlib.dumps(job))
        elif case == 'symlink':
            bridge.unlink(); bridge.symlink_to(victim)
        elif case == 'maintenance_symlink':
            (support / 'myEqMaintenance').unlink(); (support / 'myEqMaintenance').symlink_to(victim)
        elif case == 'hardlink':
            bridge.unlink(); os.link(victim, bridge)
        elif case == 'writable':
            bridge.chmod(0o777)
        elif case == 'acl':
            subprocess.run(['chmod', '+a', 'everyone allow write', str(bridge)], check=True)
        elif case == 'forged_helper':
            (root / 'Applications/myEq.app/Contents/Helpers/myEqRecovery').write_bytes(b'not the signed helper')
        elif case == 'bad_manifest':
            p = support / 'trust.plist'; trust = plistlib.loads(p.read_bytes()); trust['bridge'] = '0' * 40; p.write_bytes(plistlib.dumps(trust))
        elif case == 'bad_daemon':
            p = root / 'Library/LaunchDaemons/com.tc.myEq.bridge.plist'; job = plistlib.loads(p.read_bytes()); job['ProgramArguments'] = ['/bin/false']; p.write_bytes(plistlib.dumps(job))
        elif case == 'truncated':
            (support / 'trust.plist').write_bytes(b'broken plist')
        elif case == 'missing':
            bridge.unlink()
        run(root, 'verify', case in ('valid', 'legacy_background'))
        if case not in ('valid', 'legacy_background'):
            run(root, 'prepare', False)
            run(root, 'audio-reload-policy', False)
        assert victim.read_bytes() == b'unrelated fixture data'
        if case == 'valid':
            assert run(root, 'audio-reload-policy', True) == 'reload'  # Fresh installation.
            run(root, 'prepare', True)
            backup = support / 'previous.noindex'
            assert (backup / 'myEq.app').is_dir()
            assert run(root, 'audio-reload-policy', True) == 'keep'
            # App-only updates must preserve the running audio server.
            app = root / 'Applications/myEq.app'
            (app / 'Contents/Resources/reload-fixture.txt').write_text('new app')
            resign_and_update(app, support / 'trust.plist', 'app')
            assert run(root, 'audio-reload-policy', True) == 'keep'
            # A linked snapshot cannot justify skipping the reload.
            saved = support / 'saved.noindex'; backup.rename(saved); backup.symlink_to(saved)
            run(root, 'audio-reload-policy', False)
            backup.unlink(); saved.rename(backup)
            # A different, valid previous driver requires a reload.
            old_driver = backup / 'myEq.driver'
            (old_driver / 'Contents/Resources/reload-fixture.txt').write_text('older driver')
            resign_and_update(old_driver, backup / 'trust.plist', 'driver')
            assert run(root, 'audio-reload-policy', True) == 'reload'
            run(root, 'rollback', True)
            run(root, 'uninstall', True)
            assert not (root / 'Applications/myEq.app').exists()
            assert not (root / 'Library/Audio/Plug-Ins/HAL/myEq.driver').exists()
    fresh = base / 'fresh'; fresh.mkdir()
    run(fresh, 'prepare', True)
    # Exercise the shell guard before it execs the native utility. Only this
    # private copy substitutes paths/UID; production has no fixture override.
    harmless = base / 'harmless'
    subprocess.run(['xcrun', 'clang', '-x', 'c', '-', '-o', str(harmless)],
                   input='int main(void) { return 0; }', text=True, check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(harmless)], check=True, capture_output=True)
    for case in ['valid', 'linked_parent', 'linked_executable', 'writable_parent', 'writable_executable', 'acl', 'acl_with_xattr', 'hardlink']:
        root = base / ('guard-' + case)
        support = root / 'Library/Application Support/myEq'
        support.mkdir(parents=True)
        executable = support / 'myEqMaintenance'
        shutil.copyfile(harmless, executable)  # Signed, harmless exec target; no system flags.
        executable.chmod(0o755)
        original = (repo / 'scripts/maintenance.sh').read_text()
        fixture = original.replace('/Library', str(root) + '/Library')
        fixture = fixture.replace('-ne 0', f'-ne {os.getuid()}').replace('"$owner" != 0', f'"$owner" != {os.getuid()}')
        script = base / ('guard-' + case + '.sh'); script.write_text(fixture)
        if case == 'linked_parent':
            moved = support.with_name('saved'); support.rename(moved); support.symlink_to(moved)
        elif case == 'linked_executable':
            executable.unlink(); executable.symlink_to('/usr/bin/true')
        elif case == 'writable_parent':
            support.chmod(0o777)
        elif case == 'writable_executable':
            executable.chmod(0o777)
        elif case in ['acl', 'acl_with_xattr']:
            subprocess.run(['chmod', '+a', 'everyone allow write', str(executable)], check=True)
            if case == 'acl_with_xattr':
                subprocess.run(['/usr/bin/xattr', '-w', 'com.tc.myEq.fixture', 'test', str(executable)], check=True)
        elif case == 'hardlink':
            os.link(executable, support / 'extra-link')
        result = subprocess.run(['/bin/bash', str(script), 'uninstall'], capture_output=True, text=True, timeout=10)
        assert (result.returncode == 0) == (case == 'valid'), (case, result.stderr)
print('PASS: unprivileged installer fixtures, upgrade snapshot, rollback, uninstall and hostile path/signature rejection (ASan/UBSan).')
