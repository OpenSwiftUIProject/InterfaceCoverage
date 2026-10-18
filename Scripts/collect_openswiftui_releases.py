#!/usr/bin/env python3
"""Compare OpenSwiftUI release interfaces with SDK interfaces and build a site.

`collect` compares the OpenSwiftUI and OpenSwiftUICore XCFrameworks of each
release with the SwiftUI and SwiftUICore interfaces of each Xcode. It writes the
reports and `records.json` to the work directory, and builds the site unless
`--no-site` is given. `assemble` builds one site from the work directories of
several `collect` runs, for example one run for each Xcode.

The results for one release, target, and SDK form a cache entry. An entry is
reused when its fingerprint matches: the matching rules version, the cache
version, the release assets, and the SDK interfaces are unchanged. Other tool
changes do not invalidate entries; increase a version to generate them again.
Entries stay in the work directory and can also be stored in an OCI registry,
such as GHCR, with `oras`. Release assets are downloaded with `gh` only when an
entry must be generated.

Build the tool first:

    swift build --package-path Tools/InterfaceCoverage -c release
"""

import argparse
import hashlib
import json
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone

TOOL = pathlib.Path(__file__).resolve().parent.parent
# Increase when the cache entry layout or the comparison commands change.
# Increase `ScanOptions.currentRulesVersion` in the tool when signatures change.
CACHE_VERSION = 2
ARTIFACT_TYPE = 'application/vnd.openswiftuiproject.interface-coverage.cache.v1'
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


def slug(text):
    return '-'.join(re.findall('[a-z0-9]+', text.lower()))


def rules_version():
    """Reads the matching rules version, which identifies the comparison results of the tool."""
    source = (TOOL / 'Sources/InterfaceCoverage/Model.swift').read_text()
    match = re.search(r'static let currentRulesVersion = (\d+)', source)
    if match is None:
        raise SystemExit('Cannot find ScanOptions.currentRulesVersion in Model.swift.')
    return int(match.group(1))


class OCICache:
    """Stores cache entries as OCI artifacts. A local directory uses an OCI image layout."""

    def __init__(self, repository, publish):
        self.layout = not re.match(r'^[a-z0-9.-]+(:[0-9]+)?/', repository)
        self.repository = str(pathlib.Path(repository).resolve()) if self.layout else repository
        self.publish = publish

    def _oras(self, command, tag, *arguments, cwd=None):
        options = ['--oci-layout'] if self.layout else []
        return subprocess.run(['oras', *command, *options, f'{self.repository}:{tag}', *arguments],
                              cwd=cwd, capture_output=True, text=True)

    def pull(self, tag, directory):
        return self._oras(['pull'], tag, '--output', str(directory)).returncode == 0

    def exists(self, tag):
        return self._oras(['manifest', 'fetch'], tag).returncode == 0

    def push(self, tag, directory, files):
        # Entries are immutable. An existing reference is never replaced.
        if not self.publish or self.exists(tag):
            return
        result = self._oras(['push'], tag, '--artifact-type', ARTIFACT_TYPE, *files, cwd=directory)
        if result.returncode != 0:
            raise SystemExit(f'oras push failed for {tag}:\n{result.stderr}')
        print(f'Published {self.repository}:{tag}', flush=True)


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


def asset_digests(repository, version, work):
    release = release_metadata(repository, version, work / 'releases' / version)
    digests = {asset['name']: asset['digest'] for asset in release['assets']}
    return [digests[f'Open{module}.xcframework.zip'] for module in MODULES]


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
        metadata.update({f'{name}.assetSHA256': sha256(archive_path), f'{name}.interfacePath': interfaces[0]})
        # Older releases do not record the build environment in the framework.
        for key, field in [('buildSDK', 'DTSDKName'), ('buildSDKBuild', 'DTSDKBuild'),
                           ('buildXcode', 'DTXcode'), ('buildXcodeBuild', 'DTXcodeBuild')]:
            if field in framework:
                metadata[f'{name}.{key}'] = framework[field]
    return candidates, metadata


def valid_entry(directory, fingerprint):
    """Returns the cache entry in a directory if it is complete and has the fingerprint."""
    path = directory / 'cache.json'
    if not path.exists():
        return None
    entry = json.loads(path.read_text())
    complete = all((directory / report['file']).exists() for report in entry.get('reports', []))
    if entry.get('cacheVersion') != CACHE_VERSION or entry.get('fingerprint') != fingerprint or not complete:
        return None
    return entry


def collect(arguments):
    work = arguments.work.resolve()
    tool_commit = subprocess.check_output(['git', '-C', str(TOOL), 'rev-parse', 'HEAD'], text=True).strip()
    if subprocess.check_output(['git', '-C', str(TOOL), 'status', '--porcelain', '--', 'Sources', 'Package.swift'], text=True):
        tool_commit += '-dirty'
    rules = rules_version()
    oci = OCICache(arguments.oci_repository, arguments.publish_oci_cache) if arguments.oci_repository else None
    versions = published_releases(arguments.repository, work) if arguments.all_releases else arguments.release
    inputs = {}
    records = []
    for target in arguments.target or ['iOS', 'macOS']:
        settings = TARGETS[target]
        for xcode in arguments.xcode:
            sdk = xcode / f"Contents/Developer/Platforms/{settings['sdk']}.platform/Developer/SDKs/{settings['sdk']}.sdk"
            sdk_settings_data = (sdk / 'SDKSettings.plist').read_bytes()
            sdk_settings = plistlib.loads(sdk_settings_data)
            sdk_name = sdk_settings['CanonicalName']
            baseline = f"{target} {sdk_settings['Version']}"
            references = {}
            for module in MODULES:
                source = sdk / f"System/Library/Frameworks/{module}.framework/Modules/{module}.swiftmodule/{settings['reference']}.swiftinterface"
                path = work / 'inputs' / sdk_name / f'{module}.swiftinterface'
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(source.read_bytes())
                references[module] = path
            for version in versions:
                fingerprint = hashlib.sha256(json.dumps(dict(
                    cacheVersion=CACHE_VERSION, rulesVersion=rules, target=settings, scopes=SCOPES,
                    candidates=asset_digests(arguments.repository, version, work),
                    references=[sha256(references[module]) for module in MODULES],
                ), sort_keys=True).encode()).hexdigest()
                tag = f'{version}-{sdk_name}-{fingerprint[:16]}'
                directory = work / 'reports' / 'openswiftui' / version / target / sdk_name
                entry, source = valid_entry(directory, fingerprint), 'local cache'
                if entry is None and oci:
                    with tempfile.TemporaryDirectory() as temporary:
                        if oci.pull(tag, temporary) and valid_entry(pathlib.Path(temporary), fingerprint):
                            shutil.rmtree(directory, ignore_errors=True)
                            shutil.copytree(temporary, directory)
                            entry, source = valid_entry(directory, fingerprint), 'OCI cache'
                if entry is None:
                    if (version, target) not in inputs:
                        inputs[version, target] = release_inputs(arguments.repository, version, target, work)
                    candidates, release_info = inputs[version, target]
                    shutil.rmtree(directory, ignore_errors=True)
                    directory.mkdir(parents=True)
                    reports = []
                    for scope, modules in SCOPES:
                        name = f'{slug(scope)}.json'
                        command = [str(arguments.tool)]
                        command += [item for module in modules for item in ('--reference', str(references[module]))]
                        command += [item for module in modules for item in ('--candidate', str(candidates[module]))]
                        command += ['--format', 'json', '--output', str(directory / name)]
                        subprocess.run(command, check=True)
                        reports.append(dict(scope=scope, file=name))
                    entry = dict(
                        cacheVersion=CACHE_VERSION, fingerprint=fingerprint, version=version, target=target,
                        baseline=baseline, sdk=sdk_name, reports=reports,
                        metadata=dict(release_info, baselineSDK=sdk_name, baselineXcode=xcode.stem,
                                      sdkSettingsSHA256=hashlib.sha256(sdk_settings_data).hexdigest(),
                                      targetEnvironment=settings['variant'] or 'native', toolCommit=tool_commit,
                                      rulesVersion=str(rules),
                                      collectedAt=datetime.now(timezone.utc).isoformat()))
                    (directory / 'cache.json').write_text(json.dumps(entry, indent=2, sort_keys=True) + '\n')
                    source = 'generated'
                if oci:
                    oci.push(tag, directory, ['cache.json', *(report['file'] for report in entry['reports'])])
                for report in entry['reports']:
                    path = directory / report['file']
                    summary = json.loads(path.read_text())['coverage']['summary']
                    print(version, baseline, report['scope'], f"{summary['matched']}/{summary['reference']}", f'({source})', flush=True)
                    records.append(dict(project='OpenSwiftUI', version=version, target=target, baseline=baseline,
                                        scope=report['scope'], profile='Default', notes=[settings['note']],
                                        report=str(path.relative_to(work)), metadata=entry['metadata']))
    (work / 'records.json').write_text(json.dumps(records, indent=2) + '\n')
    if not arguments.no_site:
        build_site([work], arguments)


def build_site(directories, arguments):
    """Builds one site from the records of one or more work directories."""
    records = []
    if arguments.include_manifest:
        base = arguments.include_manifest.resolve().parent
        for record in json.loads(arguments.include_manifest.read_text())['reports']:
            if record['project'] != 'OpenSwiftUI':
                records.append(dict(record, report=str((base / record['report']).resolve())))
    # Manifest order sets the baseline order, so sort the records of all runs.
    collected = []
    for directory in directories:
        for record in json.loads((directory / 'records.json').read_text()):
            collected.append(dict(record, report=str((directory / record['report']).resolve())))
    scopes = [scope for scope, _ in SCOPES]
    targets = list(TARGETS)
    collected.sort(key=lambda record: (targets.index(record['target']),
                                       [int(part) for part in re.findall(r'\d+', record['baseline'])],
                                       scopes.index(record['scope'])))
    records += collected
    work = arguments.work.resolve()
    work.mkdir(parents=True, exist_ok=True)
    manifest = work / 'manifest.json'
    specification = dict(schemaVersion=1, title='InterfaceCoverage', reports=records)
    if arguments.site_url:
        specification['siteURL'] = arguments.site_url
    manifest.write_text(json.dumps(specification, indent=2) + '\n')
    site = (arguments.site or work / 'site').resolve()
    subprocess.run([str(arguments.tool), 'site', '--manifest', str(manifest), '--output', str(site)], check=True)
    print(f'Generated {len(records)} comparisons in {site}.', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    commands = parser.add_subparsers(dest='command', required=True)

    def add_site_options(command):
        command.add_argument('--work', type=pathlib.Path, default=TOOL / '.preview',
                             help='Directory for downloads, inputs, reports, and the manifest.')
        command.add_argument('--site', type=pathlib.Path, help='Site output directory. The default is WORK/site.')
        command.add_argument('--site-url', help='Published site address for absolute links in summaries.')
        command.add_argument('--include-manifest', type=pathlib.Path,
                             help='Existing site manifest whose reports for other projects are kept.')
        command.add_argument('--tool', type=pathlib.Path, default=TOOL / '.build/release/interface-coverage')

    collect_command = commands.add_parser('collect', help='Compare releases with the SDKs of one or more Xcodes.')
    releases = collect_command.add_mutually_exclusive_group(required=True)
    releases.add_argument('--release', action='append', help='Release tag. Repeat for more releases.')
    releases.add_argument('--all-releases', action='store_true',
                          help='Use every published release that includes both XCFrameworks.')
    collect_command.add_argument('--xcode', action='append', required=True, type=pathlib.Path,
                                 help='Xcode application that supplies the baseline SDK. Repeat for more baselines.')
    collect_command.add_argument('--target', action='append', choices=sorted(TARGETS),
                                 help='Target. The default is iOS and macOS.')
    collect_command.add_argument('--repository', default='OpenSwiftUIProject/OpenSwiftUI')
    collect_command.add_argument('--oci-repository',
                                 help='OCI repository for cache entries, such as ghcr.io/owner/name, or a local OCI layout directory.')
    collect_command.add_argument('--publish-oci-cache', action='store_true',
                                 help='Push new cache entries to the OCI repository.')
    collect_command.add_argument('--no-site', action='store_true', help='Write the reports and records only.')
    add_site_options(collect_command)

    assemble_command = commands.add_parser('assemble', help='Build one site from the work directories of collect runs.')
    assemble_command.add_argument('--input', action='append', required=True, type=pathlib.Path,
                                  help='Work directory of a collect run. Repeat for more runs.')
    add_site_options(assemble_command)

    arguments = parser.parse_args()
    if arguments.command == 'collect':
        collect(arguments)
    else:
        build_site([directory.resolve() for directory in arguments.input], arguments)


if __name__ == '__main__':
    main()
