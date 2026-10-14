#!/usr/bin/env python3
"""Escape hatch ratchet.

Fails (exit code 1) when the branch loosens one of the guardrails that keep the
views small, styled from the shared tokens and free of business logic, compared
with the base:

  - Oversized view files: a Swift file under App/ or Mac/App/ above the line
    threshold that is new, or that grew compared with the base.
  - Literal styling: the number of hard-coded corner radii, font sizes and
    hex or RGB colours across App/ and Mac/App/. BriareusRadius, Theme's fonts
    and Theme's colours replace them.
  - Networking in views: URLSession or URLRequest in a file under App/ or
    Mac/App/ that did not already use them. Requests belong in Mac/Core.
  - UI frameworks in the core: SwiftUI, UIKit or AppKit imported anywhere in
    Mac/Core/. This one is absolute, not a ratchet.

Existing debt is tolerated; adding to it is not. Fix the finding instead of
widening the exemption. Files that shrink or stay the same always pass.

Usage:
  python3 scripts/check_escape_hatches.py [base]

The base defaults to origin/main. Override with the first argument.
"""
import re
import subprocess
import sys

VIEW_LINE_THRESHOLD = 300
VIEW_ROOTS = ('App/', 'Mac/App/')
CORE_ROOT = 'Mac/Core/'

LITERAL_STYLE = {
    'corner radius': re.compile(r'cornerRadius:\s*[0-9.]+'),
    'font size': re.compile(r'\.system\(size:\s*[0-9.]+'),
    'colour literal': re.compile(r'Color\((hex|red:|\.sRGB)'),
}
NETWORKING = re.compile(r'\bURLSession\b|\bURLRequest\(')
UI_IMPORT = re.compile(r'^\s*import\s+(SwiftUI|UIKit|AppKit)\b', re.MULTILINE)


def git(*args):
    result = subprocess.run(['git', *args], capture_output=True, text=True)
    return result.stdout if result.returncode == 0 else None


def swift_files(ref, roots):
    listing = git('ls-tree', '-r', '--name-only', ref, '--', *roots) if ref else git('ls-files', '--', *roots)
    return {path for path in (listing or '').splitlines() if path.endswith('.swift')}


def read(ref, path):
    if ref:
        return git('show', f'{ref}:{path}') or ''
    with open(path, encoding='utf-8') as handle:
        return handle.read()


def line_count(text):
    return len(text.splitlines())


def literal_counts(ref, files):
    totals = dict.fromkeys(LITERAL_STYLE, 0)
    for path in files:
        text = read(ref, path)
        for name, pattern in LITERAL_STYLE.items():
            totals[name] += len(pattern.findall(text))
    return totals


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else 'origin/main'
    merge_base = (git('merge-base', base, 'HEAD') or '').strip()
    if not merge_base:
        print(f'Cannot resolve the base {base}; fetch it first. A skipped check is not a pass.')
        return 2

    failures = []
    head_views = swift_files(None, VIEW_ROOTS)
    base_views = swift_files(merge_base, VIEW_ROOTS)

    for path in sorted(head_views):
        lines = line_count(read(None, path))
        if lines <= VIEW_LINE_THRESHOLD:
            continue
        before = line_count(read(merge_base, path)) if path in base_views else None
        if before is None:
            failures.append(f'{path}: new view file has {lines} lines (limit {VIEW_LINE_THRESHOLD}). Split it into components.')
        elif lines > before:
            failures.append(f'{path}: grew from {before} to {lines} lines while above {VIEW_LINE_THRESHOLD}. Extract a component or move logic to a model or Mac/Core.')

    head_literals = literal_counts(None, head_views)
    base_literals = literal_counts(merge_base, base_views)
    for name in LITERAL_STYLE:
        if head_literals[name] > base_literals[name]:
            failures.append(f'Hard-coded {name}s rose from {base_literals[name]} to {head_literals[name]}. Use BriareusRadius, Theme fonts or Theme colours.')

    for path in sorted(head_views):
        if not NETWORKING.search(read(None, path)):
            continue
        if path in base_views and NETWORKING.search(read(merge_base, path)):
            continue
        failures.append(f'{path}: starts using URLSession or URLRequest. Put requests in Mac/Core and call them from a model.')

    for path in sorted(swift_files(None, (CORE_ROOT,))):
        match = UI_IMPORT.search(read(None, path))
        if match:
            failures.append(f'{path}: imports {match.group(1)}. Mac/Core is compiled by both apps and `swift test`; keep it free of UI frameworks.')

    if failures:
        print('Escape hatch check failed:')
        for failure in failures:
            print(f'  - {failure}')
        return 1
    print(f'Escape hatch check passed against {base} ({merge_base[:8]}).')
    return 0


if __name__ == '__main__':
    sys.exit(main())
