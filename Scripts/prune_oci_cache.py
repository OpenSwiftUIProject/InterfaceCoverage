#!/usr/bin/env python3
"""Delete cache entries that the last coverage run did not use.

`collect` writes the OCI tags that it reads or writes to `oci-tags.txt` in its
work directory. This script keeps the package versions that have one of those
tags and deletes the others, including untagged versions. It uses `gh` with a
token that can delete versions of the container package.
"""

import argparse
import json
import pathlib
import subprocess


def package_versions(org, package):
    """Returns `(id, tags)` for every version of the container package."""
    output = subprocess.check_output([
        'gh', 'api', '--paginate', f'/orgs/{org}/packages/container/{package}/versions?per_page=100',
        '--jq', '.[] | {id, tags: .metadata.container.tags}',
    ], text=True)
    return [(item['id'], item['tags']) for item in map(json.loads, output.splitlines())]


def unused_versions(versions, keep):
    """Returns the versions that have no tag in `keep`."""
    return [(identifier, tags) for identifier, tags in versions if not set(tags) & keep]


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--org', default='OpenSwiftUIProject')
    parser.add_argument('--package', default='interface-coverage-cache')
    parser.add_argument('--keep', nargs='+', required=True, type=pathlib.Path,
                        help='Files with the tags to keep, one tag on each line.')
    parser.add_argument('--dry-run', action='store_true', help='List the versions to delete without deleting them.')
    arguments = parser.parse_args()

    keep = {line.strip() for path in arguments.keep for line in path.read_text().splitlines() if line.strip()}
    # An empty list means that a run failed to report its tags, not that every entry is unused.
    if not keep:
        raise SystemExit('No tags to keep. Refusing to delete every cache entry.')
    versions = package_versions(arguments.org, arguments.package)
    unused = unused_versions(versions, keep)
    print(f'{len(versions)} versions, {len(keep)} tags to keep, {len(unused)} versions to delete.')
    for identifier, tags in unused:
        print(f"{'Would delete' if arguments.dry_run else 'Deleting'} {identifier} {', '.join(tags) or '(untagged)'}")
        if not arguments.dry_run:
            subprocess.run(['gh', 'api', '--method', 'DELETE', '--silent',
                            f'/orgs/{arguments.org}/packages/container/{arguments.package}/versions/{identifier}'], check=True)


if __name__ == '__main__':
    main()
