"""Run actual AppModel orchestration with platform stand-ins; not an Apple SDK build."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
swift = os.environ.get('SWIFT_BIN', 'swift')
swiftc = str(Path(swift).with_name('swiftc')) if '/' in swift else 'swiftc'
build = subprocess.check_output([swift, 'build', '--show-bin-path'], cwd=root, text=True).strip()
objects = sorted((Path(build) / 'WatchMindCore.build').glob('*.swift.o'))
assert objects, 'Run scripts/check.sh first to build the core objects'
with tempfile.TemporaryDirectory(prefix='watchmind-model-') as temporary:
    target = Path(temporary)
    source = (root / 'iOS/AppModel.swift').read_text().replace('import SwiftUI', 'import Foundation').replace('import AVFoundation', '').replace('UserDefaults.standard', 'ScenarioDefaults.store')
    (target / 'AppModel.swift').write_text(source)
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH='/tmp/watchmind-model-module-cache')
    command = [swiftc, '-swift-version', '5', '-I', str(Path(build) / 'Modules'),
               str(root / 'scripts/tests/appmodel/PlatformDoubles.swift'), str(target / 'AppModel.swift'),
               str(root / 'scripts/tests/appmodel/Scenarios.swift'), *map(str, objects), '-o', str(target / 'scenarios')]
    subprocess.run(command, cwd=root, env=environment, check=True)
    subprocess.run([str(target / 'scenarios')], cwd=root, env=environment, check=True, timeout=30)
