"""Validate the JSON-compatible .strings files and Swift Localizer call sites."""
from collections import Counter
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def read_table(path):
    result = {}
    for line in path.read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('//'):
            continue
        match = re.fullmatch(r'("(?:\\.|[^"\\])*")\s*=\s*("(?:\\.|[^"\\])*");', line)
        assert match, f'Invalid strings syntax: {path}: {line}'
        key, value = map(json.loads, match.groups())
        assert key not in result, f'Duplicate key: {path}: {key}'
        assert value, f'Empty translation: {path}: {key}'
        assert Counter(re.findall(r'\{\d+\}', key)) == Counter(re.findall(r'\{\d+\}', value)), f'Placeholder mismatch: {key}'
        result[key] = value
    return result


def skip_expression(source, start):
    depth = 1
    index = start
    while index < len(source) and depth:
        if source[index] == '"':
            _, index = read_message(source, index)
            continue
        if source[index] == '(':
            depth += 1
        elif source[index] == ')':
            depth -= 1
        index += 1
    assert depth == 0, 'Unclosed interpolation'
    return index


def read_message(source, start):
    index = start + 1
    key = ''
    arguments = 0
    while index < len(source):
        if source[index] == '"':
            return json.loads('"' + key + '"'), index + 1
        if source.startswith('\\(', index):
            key += '{' + str(arguments) + '}'
            arguments += 1
            index = skip_expression(source, index + 2)
        elif source[index] == '\\':
            key += source[index:index + 2]
            index += 2
        else:
            key += source[index]
            index += 1
    raise AssertionError('Unclosed string literal')


def main():
    resources = ROOT / 'Sources/WatchMindCore/Resources'
    tables = [read_table(resources / language / 'Localizable.strings') for language in ['en.lproj', 'zh-Hans.lproj']]
    assert tables[0].keys() == tables[1].keys(), 'App translation keys differ'
    for directory in ['iOS', 'Watch', 'Sources/WatchMindCore']:
        for source in (ROOT / directory).glob('*.swift'):
            text = source.read_text()
            for match in re.finditer(r'\bl\("', text):
                key, _ = read_message(text, match.end() - 1)
                assert key in tables[0], f'Missing app translation: {source}: {key}'
    permissions = [read_table(ROOT / 'AppResources' / language / 'InfoPlist.strings') for language in ['en.lproj', 'zh-Hans.lproj']]
    assert permissions[0].keys() == permissions[1].keys(), 'Permission keys differ'
    print(f'Localization audit passed: {len(tables[0])} app keys per language, {len(permissions[0])} permission keys; placeholders and call sites verified.')


if __name__ == '__main__':
    main()
