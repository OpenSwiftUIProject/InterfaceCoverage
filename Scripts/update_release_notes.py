#!/usr/bin/env python3
"""Add the interface coverage of a release to its release notes.

The script reads `summary/<project>/<version>.json` from the coverage site and
writes a Markdown table between two markers in the release notes. Running it
again replaces the table, so it is safe to repeat. It uses `gh` to read and edit
the release, which needs a token with write access to the repository contents.
"""

import argparse
import json
import subprocess
import time
import urllib.error
import urllib.request

START = '<!-- interface-coverage:start -->'
END = '<!-- interface-coverage:end -->'


def load_summary(source, attempts):
    """Reads a summary from a file or URL. A new site can take some time to appear."""
    if not source.startswith(('http://', 'https://')):
        with open(source) as file:
            return json.load(file)
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(source, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code != 404 or attempt == attempts - 1:
                raise
        time.sleep(30)


def section(summary, baselines, profile):
    results = [item for item in summary['results']
               if item['profile'] == profile and (not baselines or item['baseline'] in baselines)]
    if not results:
        raise SystemExit(f"No results for {', '.join(baselines) or 'any baseline'} in the '{profile}' profile.")
    scopes = list(dict.fromkeys(item['scope'] for item in results))
    rows = list(dict.fromkeys(item['baseline'] for item in results))
    if baselines:
        rows = [baseline for baseline in baselines if baseline in rows]
    lines = [START, '### Interface coverage', '',
             f"{summary['note']} Coverage is not a measure of completed behavior.", '',
             '| Baseline | ' + ' | '.join(scopes) + ' |', '| --- | ' + ' | '.join('---:' for _ in scopes) + ' |']
    for baseline in rows:
        cells = []
        for scope in scopes:
            item = next((item for item in results if item['baseline'] == baseline and item['scope'] == scope), None)
            if item is None:
                cells.append('—')
            else:
                value = 'n/a' if item.get('percent') is None else f"{item['percent']:.2f}%"
                cells.append(f"[{value}]({item['url']})")
        lines.append(f'| {baseline} | ' + ' | '.join(cells) + ' |')
    return '\n'.join(lines + [END])


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--repository', default='OpenSwiftUIProject/OpenSwiftUI')
    parser.add_argument('--version', required=True, help='Release tag.')
    parser.add_argument('--summary', required=True, help='Summary JSON path or URL.')
    parser.add_argument('--baseline', action='append', default=[], help='Baseline to show. Repeat for more. The default is all.')
    parser.add_argument('--profile', default='Default')
    parser.add_argument('--attempts', type=int, default=20, help='Attempts to read a summary URL, 30 seconds apart.')
    parser.add_argument('--dry-run', action='store_true', help='Print the new release notes instead of editing the release.')
    arguments = parser.parse_args()

    summary = load_summary(arguments.summary, arguments.attempts)
    if summary['version'] != arguments.version:
        raise SystemExit(f"The summary is for {summary['version']}, not {arguments.version}.")
    block = section(summary, arguments.baseline, arguments.profile)
    body = subprocess.check_output(['gh', 'release', 'view', arguments.version, '--repo', arguments.repository,
                                    '--json', 'body', '--jq', '.body'], text=True).rstrip('\n')
    if START in body and END in body:
        before, rest = body.split(START, 1)
        body = before + block + rest.split(END, 1)[1]
    else:
        body = f'{body}\n\n{block}' if body else block
    if arguments.dry_run:
        print(body)
        return
    subprocess.run(['gh', 'release', 'edit', arguments.version, '--repo', arguments.repository, '--notes-file', '-'],
                   input=body + '\n', text=True, check=True)


if __name__ == '__main__':
    main()
