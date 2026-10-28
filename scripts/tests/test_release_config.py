"""Static publishing guard tests using synthetic build settings; no signing or websites verified."""
from pathlib import Path
import json
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[2]

class ReleaseConfigurationTests(unittest.TestCase):
    def settings(self):
        common = {'CONFIGURATION': 'Release', 'DEVELOPMENT_TEAM': 'ABC1234567',
                  'WATCHMIND_APP_BUNDLE_ID': 'org.fixture.watchmind',
                  'WATCHMIND_PRIVACY_POLICY_URL': 'https://publisher.fixture.dev/privacy',
                  'WATCHMIND_SUPPORT_URL': 'https://publisher.fixture.dev/support',
                  'WATCHMIND_OPERATOR_NAME': 'Synthetic test publisher'}
        phone = dict(common, PRODUCT_BUNDLE_IDENTIFIER='org.fixture.watchmind')
        watch = dict(common, PRODUCT_BUNDLE_IDENTIFIER='org.fixture.watchmind.watchkitapp')
        return [{'target': 'WatchMind', 'buildSettings': phone}, {'target': 'WatchMindWatch', 'buildSettings': watch}]

    def run_guard(self, settings):
        with tempfile.TemporaryDirectory(prefix='watchmind-release-guard-') as folder:
            path = Path(folder)/'settings.json'
            path.write_text(json.dumps(settings))
            return subprocess.run([sys.executable, str(ROOT/'scripts/check-release-config.py'), '--settings-json', str(path)],
                                  cwd=ROOT, text=True, capture_output=True, timeout=10)

    def test_real_icon_files_and_valid_settings_structure(self):
        result = self.run_guard(self.settings())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Still verify actual HTTPS pages', result.stdout)

    def test_repository_defaults_and_missing_legal_identity_block_distribution(self):
        settings = self.settings()
        settings[0]['buildSettings'].update(DEVELOPMENT_TEAM='', PRODUCT_BUNDLE_IDENTIFIER='com.watchmind.app',
            WATCHMIND_OPERATOR_NAME='', WATCHMIND_PRIVACY_POLICY_URL='', WATCHMIND_SUPPORT_URL='')
        result = self.run_guard(settings)
        self.assertNotEqual(result.returncode, 0)
        for expected in ['Team', 'Bundle ID', 'PRIVACY_POLICY', 'SUPPORT_URL', 'publisher']:
            self.assertIn(expected, result.stdout)

    def test_mismatched_watch_identity_and_unsafe_policy_fail(self):
        settings = self.settings()
        settings[1]['buildSettings'].update(DEVELOPMENT_TEAM='ZZZ1234567', PRODUCT_BUNDLE_IDENTIFIER='org.unrelated.watch')
        settings[0]['buildSettings']['WATCHMIND_PRIVACY_POLICY_URL'] = 'https://key@publisher.fixture.dev/privacy'
        result = self.run_guard(settings)
        self.assertNotEqual(result.returncode, 0)
        for expected in ['same Apple', 'prefixed', 'PRIVACY_POLICY']:
            self.assertIn(expected, result.stdout)

if __name__ == '__main__':
    unittest.main()
