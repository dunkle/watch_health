"""Validate resolved Apple Release settings and icon assets before public distribution.

Generate input on a Mac:
  xcodebuild -project WatchMind.xcodeproj -scheme WatchMind -configuration Release -showBuildSettings -json > /tmp/WatchMind-release-settings.json
  python3 scripts/check-release-config.py --settings-json /tmp/WatchMind-release-settings.json

This intentionally fails for the repository's unconfigured publishing identity / URLs.
It neither invents legal contacts nor claims certificates, App Store approval or site availability.
"""
from pathlib import Path
import argparse
import json
import re
import struct
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]


def public_https(value):
    try:
        url = urlsplit(value)
        host = (url.hostname or '').lower()
        return (url.scheme == 'https' and '.' in host and host not in {'example.com', 'example.net', 'example.org'}
                and not host.endswith(('.example', '.invalid', '.test', '.localhost'))
                and not all(part.isdecimal() for part in host.split('.'))
                and not url.username and not url.password and not url.query and not url.fragment and '$(' not in value)
    except ValueError:
        return False


def check_icons(errors):
    for name in ['AppIcon', 'WatchAppIcon']:
        directory = ROOT / 'AppResources/Assets.xcassets' / (name + '.appiconset')
        try:
            images = json.loads((directory / 'Contents.json').read_text())['images']
            assert images and any(row.get('size') == '1024x1024' for row in images)
            for image in images:
                data = (directory / image['filename']).read_bytes()
                assert data[:8] == b'\x89PNG\r\n\x1a\n'
                width, height = struct.unpack('>II', data[16:24])
                expected = float(image['size'].split('x')[0]) * float(image.get('scale', '1x')[:-1])
                assert width == height == expected
                assert data[25] == 2, 'Icons must be opaque RGB PNGs'
        except (OSError, ValueError, KeyError, AssertionError):
            errors.append(name + ' icon catalog is incomplete or invalid')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--settings-json', type=Path, required=True)
    args = parser.parse_args()
    errors = []
    check_icons(errors)
    try:
        rows = json.loads(args.settings_json.read_text())
        settings = next(row['buildSettings'] for row in rows if row.get('target') == 'WatchMind')
        watch = next(row['buildSettings'] for row in rows if row.get('target') == 'WatchMindWatch')
    except (OSError, ValueError, KeyError, StopIteration, TypeError):
        raise SystemExit('FAIL: supply resolved WatchMind Release -showBuildSettings -json output.')
    if settings.get('CONFIGURATION') != 'Release':
        errors.append('Build settings must use the Release configuration')
    if not re.fullmatch(r'[A-Z0-9]{10}', settings.get('DEVELOPMENT_TEAM', '')):
        errors.append('Set a valid Apple development Team before signing')
    bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER', '')
    if bundle == 'com.watchmind.app' or not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', bundle):
        errors.append('Choose and register a unique production Bundle ID instead of the repository default')
    if settings.get('WATCHMIND_APP_BUNDLE_ID') != bundle or watch.get('WATCHMIND_APP_BUNDLE_ID') != bundle:
        errors.append('Set WATCHMIND_APP_BUNDLE_ID consistently so the Watch companion matches the iPhone app')
    if not watch.get('PRODUCT_BUNDLE_IDENTIFIER', '').startswith(bundle + '.'):
        errors.append('The Watch Bundle ID must be prefixed by the iPhone Bundle ID')
    if watch.get('DEVELOPMENT_TEAM') != settings.get('DEVELOPMENT_TEAM'):
        errors.append('Both app targets must use the same Apple development Team')
    for key in ['WATCHMIND_PRIVACY_POLICY_URL', 'WATCHMIND_SUPPORT_URL']:
        if not public_https(settings.get(key, '')):
            errors.append('Configure a real public HTTPS value for ' + key)
    operator = settings.get('WATCHMIND_OPERATOR_NAME', '').strip()
    if not operator or '$(' in operator:
        errors.append('Configure the actual publisher in WATCHMIND_OPERATOR_NAME')
    if errors:
        for error in errors:
            print('FAIL:', error)
        raise SystemExit(1)
    print('Release identity, policy/support settings and icon files passed static validation.')
    print('Still verify actual HTTPS pages, signing, privacy disclosures, Archive, devices and App Store validation.')


if __name__ == '__main__':
    main()
