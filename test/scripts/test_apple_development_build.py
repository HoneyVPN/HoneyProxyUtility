"""Fixture checks for local development signing safeguards; no Apple tools run."""
import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/build_apple_development.py'
spec = importlib.util.spec_from_file_location('apple_development_build', SCRIPT)
helper = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = helper
spec.loader.exec_module(helper)
TEAM = 'ABCDE12345'
DEVICE = 'fixture-device'
CERTIFICATE = b'fixture-public-certificate'


def profile(identifier=helper.HOST, prefix='LEGACY6789'):
    return {
        'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=10),
        'TeamIdentifier': [TEAM], 'ApplicationIdentifierPrefix': [prefix],
        'ProvisionedDevices': [DEVICE], 'DeveloperCertificates': [CERTIFICATE],
        'Entitlements': {'com.apple.application-identifier': prefix + '.' + identifier,
                         helper.TEAM: TEAM, 'com.apple.security.get-task-allow': True,
                         helper.NE: ['packet-tunnel-provider'], helper.GROUPS: [helper.GROUP]},
    }


class DevelopmentSafeguards(unittest.TestCase):
    def test_prior_core_staging_is_rejected_before_binary_inspection(self):
        valid = {'repository': helper.CORE['repository'], 'revision': helper.REVISION,
                 'base_version': helper.VERSION, 'go': helper.CORE['apple']['go'],
                 'gomobile': helper.CORE['apple']['gomobile'], 'tags': sorted(helper.TAGS),
                 'prepared_builder_sha256': 'a' * 64}
        changes = [
            {'revision': '3bd162ed6f7ecbfb53a4cde6c7500e40c31fbd19'},
            {'base_version': 'v1.13.11-extended-2.1.0'},
            {'go': '1.26.2'},
            {'tags': [tag for tag in helper.TAGS if tag != 'with_clash_api']},
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'macos/Frameworks'
            directory.mkdir(parents=True)
            commands = []
            def fake(command, **kwargs):
                commands.append(command)
                raise AssertionError('Rejected metadata must never reach binary inspection')
            for changed in changes:
                with self.subTest(changed=changed):
                    path = directory / 'apple-core-build.json'
                    path.write_text(json.dumps(dict(valid, **changed)))
                    original = path.read_bytes()
                    with self.assertRaises(helper.BuildFailure):
                        helper.validate_staged_core(root, 'arm64', runner=fake)
                    self.assertEqual(path.read_bytes(), original)
            self.assertEqual(commands, [])

    def test_native_arm64_probe_remains_readonly_when_hardware_sysctl_is_restricted(self):
        commands = []
        def fake(command, **kwargs):
            commands.append(command)
            if command[0] == '/usr/bin/uname':
                return subprocess.CompletedProcess(command, 0, stdout=b'arm64\n', stderr=b'')
            return subprocess.CompletedProcess(command, 1, stdout=b'', stderr=b'Operation not permitted')
        self.assertEqual(helper.native_architecture(runner=fake), 'arm64')
        self.assertEqual([command[0] for command in commands], ['/usr/sbin/sysctl', '/usr/bin/uname'])

    def test_paid_development_profile_accepts_legacy_app_id_prefix(self):
        authorized = helper.validate_profile(profile(), helper.HOST, TEAM, certificate=CERTIFICATE, device_id=DEVICE)
        entitlements = dict(authorized, **{'com.apple.security.app-sandbox': True})
        helper.validate_signed_entitlements(entitlements, authorized, helper.HOST, TEAM)

    def test_mac_development_profile_can_omit_unrestricted_get_task_allow(self):
        candidate = profile()
        candidate['Entitlements'].pop('com.apple.security.get-task-allow')
        helper.validate_profile(candidate, helper.HOST, TEAM, certificate=CERTIFICATE, device_id=DEVICE)

    def test_wrong_expired_under_entitled_and_distribution_profiles_are_rejected(self):
        changes = [
            lambda p: p.update(ExpirationDate=datetime.now(timezone.utc) - timedelta(seconds=1)),
            lambda p: p.update(TeamIdentifier=['OTHER12345']),
            lambda p: p['Entitlements'].update({helper.GROUPS: ['ABCDE12345.*']}),
            lambda p: p['Entitlements'].update({helper.NE: []}),
            lambda p: p['Entitlements'].update({'com.apple.application-identifier': 'LEGACY6789.' + helper.PROVIDER}),
            lambda p: p.update(ProvisionedDevices=[]),
            lambda p: p.update(ProvisionedDevices=['different-device']),
            lambda p: p.update(DeveloperCertificates=[b'other-certificate']),
            lambda p: p.update(ProvisionsAllDevices=True),
        ]
        for change in changes:
            with self.subTest(change=change):
                candidate = profile()
                change(candidate)
                with self.assertRaises(helper.BuildFailure):
                    helper.validate_profile(candidate, helper.HOST, TEAM, certificate=CERTIFICATE, device_id=DEVICE)

    def test_signed_provider_cannot_omit_a_group_authorized_by_its_profile(self):
        authorized = helper.validate_profile(profile(helper.PROVIDER), helper.PROVIDER, TEAM)
        signed = dict(authorized, **{'com.apple.security.app-sandbox': True, helper.GROUPS: []})
        with self.assertRaises(helper.BuildFailure):
            helper.validate_signed_entitlements(signed, authorized, helper.PROVIDER, TEAM)

    def test_default_and_blocked_build_never_prepare_sign_or_register(self):
        for arguments in ([], ['--build', '--team-id', TEAM]):
            commands = []
            def fake(command, **kwargs):
                commands.append(command)
                return subprocess.CompletedProcess(command, 0, stdout=b'/fixture/Xcode.app/Contents/Developer\n', stderr=b'')
            with mock.patch.object(helper, 'run', fake), mock.patch.object(helper, 'preflight', return_value=([helper.Check('Signing', False, 'Missing.')], {})), mock.patch.object(helper, 'developer_directory', return_value=Path('/fixture/Xcode.app/Contents/Developer')), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(helper.main(arguments), 2)
            self.assertEqual(commands, [])

    def test_build_requires_a_team_and_does_not_echo_signing_subjects(self):
        with contextlib.redirect_stderr(io.StringIO()) as errors, self.assertRaises(SystemExit):
            helper.main(['--build'])
        self.assertIn('--build requires', errors.getvalue())
        identities = b'1) HASH "Apple Development: Private Person (ABCDE12345)"\n2) HASH "Developer ID Application: Private Company (ABCDE12345)"'
        self.assertEqual(helper.development_identity_count(identities, TEAM), 1)
        self.assertEqual(helper.development_identity_count(identities, 'OTHER12345'), 0)

    def test_planned_build_is_native_debug_only_and_cannot_update_accounts(self):
        commands = helper.build_commands(Path('/fixture/repo'), Path('/fixture/flutter/bin/flutter'), Path('/fixture/Xcode.app/Contents/Developer'), TEAM, 'arm64')
        self.assertIn('--enforce-lockfile', commands[0])
        self.assertIn('--config-only', commands[1])
        self.assertIn('Debug', commands[-1])
        self.assertIn('ARCHS=arm64', commands[-1])
        self.assertIn('CODE_SIGN_IDENTITY=Apple Development', commands[-1])
        self.assertIn('SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG HONEYPROXY_DEVELOPMENT_VPN', commands[-1])
        for command in commands:
            self.assertFalse(any('allowProvisioning' in argument or argument in ('-runFirstLaunch', '-license', 'accept') for argument in command))

    def test_real_preflight_reads_only_and_reports_missing_prerequisites_without_subjects(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            before = list(root.iterdir())
            commands = []
            def fake(command, **kwargs):
                commands.append(command)
                output = b'1' if 'hw.optional.arm64' in command else b'0 valid identities found'
                return subprocess.CompletedProcess(command, 0, stdout=output, stderr=b'PRIVATE SUBJECT')
            checks, _ = helper.preflight(root, None, root / 'missing-Xcode', None, runner=fake, system='Darwin', machine='arm64')
            self.assertTrue(any(not check.ready for check in checks))
            self.assertEqual(list(root.iterdir()), before)
            self.assertEqual([command[0] for command in commands], ['/usr/sbin/sysctl', '/usr/bin/security'])
            self.assertNotIn('PRIVATE SUBJECT', repr(checks))

    def test_bundle_verification_preserves_signed_contents_and_checks_both_profiles(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / 'HoneyProxyUtility.app'
            provider = app / 'Contents/PlugIns/HoneyProxyPacketTunnel.appex'
            for bundle, identifier in ((app, helper.HOST), (provider, helper.PROVIDER)):
                (bundle / 'Contents').mkdir(parents=True, exist_ok=True)
                (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
                (bundle / 'Contents/embedded.provisionprofile').write_bytes(b'fixture-cms-profile')
            before = {str(path.relative_to(app)): path.read_bytes() for path in app.rglob('*') if path.is_file()}
            commands = []
            def fake(command, **kwargs):
                commands.append(command)
                stdout = b''
                stderr = b''
                if '--verbose=4' in command:
                    stderr = ('Authority=Apple Development: Private Subject\nTeamIdentifier=' + TEAM).encode()
                elif '--entitlements' in command:
                    identifier = helper.PROVIDER if 'appex' in command[-1] else helper.HOST
                    signed = dict(profile(identifier)['Entitlements'], **{'com.apple.security.app-sandbox': True})
                    stdout = plistlib.dumps(signed)
                elif '--extract-certificates' in command:
                    Path(command[command.index('--extract-certificates') + 1] + '0').write_bytes(CERTIFICATE)
                elif command[0] == '/usr/bin/security':
                    identifier = helper.PROVIDER if 'appex' in command[-1] else helper.HOST
                    # plistlib expects naive UTC values in fixtures.
                    candidate = profile(identifier)
                    candidate['ExpirationDate'] = candidate['ExpirationDate'].replace(tzinfo=None)
                    stdout = plistlib.dumps(candidate)
                return subprocess.CompletedProcess(command, 0, stdout=stdout, stderr=stderr)
            helper.verify_development_bundle(app, Path('/fixture/metadata.json'), TEAM, runner=fake, device_id=DEVICE)
            after = {str(path.relative_to(app)): path.read_bytes() for path in app.rglob('*') if path.is_file()}
            self.assertEqual(before, after)
            self.assertIn('--verify-only', commands[0])
            self.assertIn('--local-development', commands[0])
            self.assertEqual(sum('--strict' in command for command in commands), 2)
            self.assertTrue(all('--xml' in command for command in commands if '--entitlements' in command))


if __name__ == '__main__':
    unittest.main()
