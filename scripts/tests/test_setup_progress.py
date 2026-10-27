"""Exercise progress and failure propagation with fake tools, never a real Xcode build."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SetupProgressTests(unittest.TestCase):
    def run_setup(self, fail='', install=False):
        with tempfile.TemporaryDirectory(prefix='watchmind-build-test-') as temporary:
            tools = Path(temporary)
            programs = {
                'uname': '#!/bin/bash\necho Darwin\n',
                'xcodebuild': '''#!/bin/bash
if [[ "$1" == -version ]]; then echo 'Xcode fixture'; exit 0; fi
echo fixture-native-build
if [[ "$TEST_FAIL_STAGE" == build ]]; then echo 'error: fixture native failure' >&2; exit 42; fi
echo '** BUILD SUCCEEDED **'
''',
                'swift': '''#!/bin/bash
echo fixture-core-tests
if [[ "$TEST_FAIL_STAGE" == tests ]]; then echo 'error: fixture test failure' >&2; exit 23; fi
''',
                'xcodegen-template': '#!/bin/bash\necho fixture-xcodegen\n',
                'brew': '''#!/bin/bash
echo 'fixture Homebrew auto-update'
sleep 16
cp "$FAKE_BIN/xcodegen-template" "$FAKE_BIN/xcodegen"
chmod +x "$FAKE_BIN/xcodegen"
'''
            }
            if not install:
                programs['xcodegen'] = programs['xcodegen-template']
            for name, source in programs.items():
                path = tools / name
                path.write_text(source)
                path.chmod(0o755)
            environment = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                               FAKE_BIN=str(tools), TEST_FAIL_STAGE=fail,
                               WATCHMIND_BUILD_LOG_DIR=str(tools / 'logs'))
            result = subprocess.run(['bash', str(ROOT / 'scripts/setup-mac.sh')], cwd=ROOT,
                                    env=environment, text=True, capture_output=True, timeout=35)
            result.build_logs = [p.read_text() for p in (tools / 'logs').glob('*.log')]
            return result

    def test_all_stages_complete(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('[#####] 5/5', result.stdout)
        self.assertIn('BUILD SUCCEEDED', result.stdout)
        self.assertIn('not compiler completion', result.stdout)
        self.assertEqual(len(result.build_logs), 1)
        self.assertIn('BUILD SUCCEEDED', result.build_logs[0])

    def test_test_failure_preserves_exit_code_and_skips_native_build(self):
        result = self.run_setup(fail='tests')
        self.assertEqual(result.returncode, 23)
        self.assertIn('fixture test failure', result.stderr)
        self.assertNotIn('fixture-native-build', result.stdout)
        self.assertNotIn('[#####] 5/5', result.stdout)

    def test_native_failure_is_not_reported_as_success(self):
        result = self.run_setup(fail='build')
        self.assertEqual(result.returncode, 42)
        self.assertIn('[5/5]', result.stderr)
        self.assertNotIn('✓ 构建完成', result.stdout)
        self.assertIn('First build error', result.stderr)
        self.assertIn('error: fixture native failure', result.stderr)
        self.assertEqual(len(result.build_logs), 1)
        self.assertIn('error: fixture native failure', result.build_logs[0])

    def test_slow_homebrew_stage_emits_heartbeat(self):
        result = self.run_setup(install=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Homebrew auto-update', result.stdout)
        self.assertIn('still running', result.stdout)
        self.assertIn('Prepare XcodeGen', result.stdout)


if __name__ == '__main__':
    unittest.main()
