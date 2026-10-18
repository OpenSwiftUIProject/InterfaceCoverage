#!/usr/bin/env python3
"""Compare OpenSwiftUI release interfaces with SDK interfaces and build a site.

For each release, the script downloads the OpenSwiftUI and OpenSwiftUICore
XCFrameworks with `gh`, verifies their published SHA-256 digests, and compares
their public interfaces with the SwiftUI and SwiftUICore interfaces of each
Xcode. It writes one JSON report per comparison, a site manifest, and the site.

Downloads are cached in the work directory. Build the tool first:

    swift build --package-path Tools/InterfaceCoverage -c release
"""

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import subprocess
import zipfile
from datetime import datetime, timezone

TOOL = pathlib.Path(__file__).resolve().parent.parent
MODULES = ['SwiftUI', 'SwiftUICore']
# The combined scope comes first, so summaries and the site show it first.
SCOPES = [('SwiftUI + SwiftUICore', MODULES), ('SwiftUI', ['SwiftUI']), ('SwiftUICore', ['SwiftUICore'])]
TARGETS = {
    'iOS': dict(platform='ios', variant='simulator', sdk='iPhoneSimulator',
                candidate='arm64-apple-ios-simulator', reference='arm64-apple-ios-simulator',
                note='Public interfaces from published XCFrameworks; arm64 simulator slice.'),
    'macOS': dict(platform='macos', variant=None, sdk='MacOSX',
                  candidate='arm64-apple-macos', reference='arm64e-apple-macos',
                  note='Public interfaces from published XCFrameworks; arm64 macOS slice.'),
}


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def gh(*arguments):
    return subprocess.check_output(['gh', *arguments], text=True)


def release_metadata(repository, version, directory, refresh=False):
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / 'release.json'
    if refresh or not path.exists():
        path.write_text(gh('release', 'view', version, '--repo', repository,
                           '--json', 'url,publishedAt,tagName,assets') + '\n')
    return json.loads(path.read_text())


def published_releases(repository, work):
    """Returns the published releases that include both XCFrameworks, oldest first."""
    releases = json.loads(gh('release', 'list', '--repo', repository, '--limit', '1000',
                             '--exclude-drafts', '--json', 'tagName,publishedAt'))
    result = []
    for release in sorted(releases, key=lambda item: item['publishedAt']):
        version = release['tagName']
        wanted = [f'Open{module}.xcframework.zip' for module in MODULES]
        names = {asset['name'] for asset in release_metadata(repository, version, work / 'releases' / version)['assets']}
        if not all(name in names for name in wanted):
            # Assets can be added after the metadata was cached.
            names = {asset['name'] for asset in release_metadata(repository, version, work / 'releases' / version, refresh=True)['assets']}
        if all(name in names for name in wanted):
            result.append(version)
    return result


def fetch_release(repository, version, directory):
    """Downloads the release metadata and XCFrameworks once, then verifies them."""
    release = release_metadata(repository, version, directory)
    names = {asset['name'] for asset in release['assets']}
    wanted = [f'Open{module}.xcframework.zip' for module in MODULES]
    if 'release-manifest.json' in names:
        wanted.append('release-manifest.json')
    for name in wanted:
        if not (directory / name).exists():
            subprocess.run(['gh', 'release', 'download', version, '--repo', repository,
                            '--pattern', name, '--dir', str(directory)], check=True)
    for asset in release['assets']:
        if asset['name'] in wanted:
            assert asset['digest'] == f"sha256:{sha256(directory / asset['name'])}", asset['name']
    manifest_path = directory / 'release-manifest.json'
    if manifest_path.exists():
        details = json.loads(manifest_path.read_text())
        assert details['version'] == version, manifest_path
        commit, commit_source = details['sha'], 'Published release-manifest.json'
        for name in wanted[:len(MODULES)]:
            assert details['files'][name] == sha256(directory / name), name
    else:
        commit_path = directory / 'tag-commit.json'
        if not commit_path.exists():
            sha = gh('api', f'repos/{repository}/commits/{version}', '--jq', '.sha').strip()
            commit_path.write_text(json.dumps(dict(sha=sha)) + '\n')
        commit, commit_source = json.loads(commit_path.read_text())['sha'], 'GitHub release tag'
    assert re.fullmatch('[a-f0-9]{40}', commit), commit
    return release, commit, commit_source


def release_inputs(repository, version, target, work):
    """Extracts the candidate interfaces of one release and target."""
    directory = work / 'releases' / version
    release, commit, commit_source = fetch_release(repository, version, directory)
    settings = TARGETS[target]
    metadata = dict(candidateOrigin='GitHub release XCFramework', candidateCommit=commit,
                    candidateCommitSource=commit_source, releaseURL=release['url'],
                    releasePublishedAt=release['publishedAt'])
    candidates = {}
    for module in MODULES:
        name = f'Open{module}'
        archive_path = directory / f'{name}.xcframework.zip'
        with zipfile.ZipFile(archive_path) as archive:
            xcframework = f'{name}.xcframework'
            info = plistlib.loads(archive.read(f'{xcframework}/Info.plist'))
            libraries = [item for item in info['AvailableLibraries']
                         if item['SupportedPlatform'] == settings['platform']
                         and item.get('SupportedPlatformVariant') == settings['variant']
                         and 'arm64' in item['SupportedArchitectures']]
            assert len(libraries) == 1, (version, name, target, libraries)
            library = libraries[0]
            prefix = f"{xcframework}/{library['LibraryIdentifier']}/{library['LibraryPath']}/"
            suffix = f"Modules/{name}.swiftmodule/{settings['candidate']}.swiftinterface"
            interfaces = [path for path in archive.namelist() if path.startswith(prefix) and path.endswith(suffix)]
            assert len(interfaces) == 1, (version, name, target, interfaces)
            plists = [path for path in archive.namelist() if path.startswith(prefix) and path.endswith('/Info.plist')]
            assert len(plists) == 1, plists
            framework = plistlib.loads(archive.read(plists[0]))
            path = work / 'inputs' / f'openswiftui-{version}' / target / f'{name}.swiftinterface'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(archive.read(interfaces[0]))
            candidates[module] = path
        metadata.update({f'{name}.assetSHA256': sha256(archive_path), f'{name}.interfacePath': interfaces[0],
                         f'{name}.buildSDK': framework['DTSDKName'], f'{name}.buildSDKBuild': framework['DTSDKBuild'],
                         f'{name}.buildXcode': framework['DTXcode'], f'{name}.buildXcodeBuild': framework['DTXcodeBuild']})
    return candidates, metadata


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    releases = parser.add_mutually_exclusive_group(required=True)
    releases.add_argument('--release', action='append', help='Release tag. Repeat for more releases.')
    releases.add_argument('--all-releases', action='store_true',
                          help='Use every published release that includes both XCFrameworks.')
    parser.add_argument('--xcode', action='append', required=True, type=pathlib.Path,
                        help='Xcode application that supplies the baseline SDK. Repeat for more baselines.')
    parser.add_argument('--target', action='append', choices=sorted(TARGETS), help='Target. The default is iOS and macOS.')
    parser.add_argument('--repository', default='OpenSwiftUIProject/OpenSwiftUI')
    parser.add_argument('--work', type=pathlib.Path, default=TOOL / '.preview', help='Directory for downloads, inputs, and reports.')
    parser.add_argument('--site', type=pathlib.Path, help='Site output directory. The default is WORK/site.')
    parser.add_argument('--site-url', help='Published site address for absolute links in summaries.')
    parser.add_argument('--include-manifest', type=pathlib.Path,
                        help='Existing site manifest whose reports for other projects are kept.')
    parser.add_argument('--tool', type=pathlib.Path, default=TOOL / '.build/release/interface-coverage')
    arguments = parser.parse_args()
    work = arguments.work.resolve()
    site = (arguments.site or work / 'site').resolve()
    tool_commit = subprocess.check_output(['git', '-C', str(TOOL), 'rev-parse', 'HEAD'], text=True).strip()
    if subprocess.check_output(['git', '-C', str(TOOL), 'status', '--porcelain', '--', 'Sources', 'Package.swift'], text=True):
        tool_commit += '-dirty'
    collected = datetime.now(timezone.utc).isoformat()
    versions = published_releases(arguments.repository, work) if arguments.all_releases else arguments.release
    # A report is reused when the tool binary and the input interfaces are unchanged.
    tool_digest = sha256(arguments.tool)

    records = []
    if arguments.include_manifest:
        base = arguments.include_manifest.resolve().parent
        for record in json.loads(arguments.include_manifest.read_text())['reports']:
            if record['project'] != 'OpenSwiftUI':
                records.append(dict(record, report=str((base / record['report']).resolve())))

    for target in arguments.target or ['iOS', 'macOS']:
        settings = TARGETS[target]
        candidates = {version: release_inputs(arguments.repository, version, target, work) for version in versions}
        for xcode in arguments.xcode:
            sdk = xcode / f"Contents/Developer/Platforms/{settings['sdk']}.platform/Developer/SDKs/{settings['sdk']}.sdk"
            sdk_settings_data = (sdk / 'SDKSettings.plist').read_bytes()
            sdk_settings = plistlib.loads(sdk_settings_data)
            baseline = f"{target} {sdk_settings['Version']}"
            sdk_metadata = dict(baselineSDK=sdk_settings['CanonicalName'], baselineXcode=xcode.stem,
                                sdkSettingsSHA256=hashlib.sha256(sdk_settings_data).hexdigest(),
                                targetEnvironment=settings['variant'] or 'native')
            references = {}
            for module in MODULES:
                source = sdk / f"System/Library/Frameworks/{module}.framework/Modules/{module}.swiftmodule/{settings['reference']}.swiftinterface"
                path = work / 'inputs' / sdk_settings['CanonicalName'] / f'{module}.swiftinterface'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(source.read_bytes())
                references[module] = path
            for version in versions:
                candidate_paths, release_metadata = candidates[version]
                for scope, modules in SCOPES:
                    destination = work / 'reports' / 'openswiftui' / version / target / f"{sdk_settings['CanonicalName']}-{'-'.join(modules)}.json"
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    command = [str(arguments.tool)]
                    command += [item for module in modules for item in ('--reference', str(references[module]))]
                    command += [item for module in modules for item in ('--candidate', str(candidate_paths[module]))]
                    command += ['--format', 'json', '--output', str(destination)]
                    key = json.dumps(dict(tool=tool_digest, command=command[1:], inputs=[
                        sha256(references[module]) for module in modules] + [sha256(candidate_paths[module]) for module in modules]))
                    key_path = destination.with_suffix('.key')
                    if not destination.exists() or not key_path.exists() or key_path.read_text() != key:
                        subprocess.run(command, check=True)
                        key_path.write_text(key)
                    summary = json.loads(destination.read_text())['coverage']['summary']
                    print(version, baseline, scope, f"{summary['matched']}/{summary['reference']}", flush=True)
                    records.append(dict(
                        project='OpenSwiftUI', version=version, target=target, baseline=baseline, scope=scope,
                        profile='Default', report=str(destination), notes=[settings['note']],
                        metadata=dict(release_metadata, **sdk_metadata, toolCommit=tool_commit, collectedAt=collected)))

    manifest = work / 'manifest.json'
    specification = dict(schemaVersion=1, title='InterfaceCoverage', reports=records)
    if arguments.site_url:
        specification['siteURL'] = arguments.site_url
    manifest.write_text(json.dumps(specification, indent=2) + '\n')
    subprocess.run([str(arguments.tool), 'site', '--manifest', str(manifest), '--output', str(site)], check=True)
    print(f'Generated {len(records)} comparisons in {site}.', flush=True)


if __name__ == '__main__':
    main()
