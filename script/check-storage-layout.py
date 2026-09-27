#!/usr/bin/env python3
"""Compare compiler storage layouts of the working tree against one or more git baselines.

Never reads RPC or deployed state. Run from the repository root.

Baseline selection (first match wins):
  1. one or more `--base <git-ref>` arguments;
  2. the STORAGE_LAYOUT_BASE environment variable (comma-separated refs);
  3. DEPLOYED_BASE below: the commit that built the live Base mainnet core implementations
     (docs/MAINNET_EVENTS_DEPLOY.md section 0). For PerpEngine and PerpInternals this was
     confirmed on 2026-09-27 by comparing the build with the deployed runtime bytecode.

For a proxy upgrade the baseline MUST be the commit that built the implementation currently
behind that proxy, not origin/main. The Base Sepolia PerpEngine was built from a different
commit; pass it explicitly. `--base origin/main` only checks unreleased drift. CI runs this
script with the default baseline (.github/workflows/ci.yml, storage-layout job).

Set SOLC to a Solidity 0.8.24 binary if it is not in a standard svm location.
Only the known trailing PauseGuardian array expansion is accepted.
"""
import argparse, json, os, pathlib, posixpath, re, subprocess

# Live Base mainnet core implementations were deployed from this commit on 2026-07-14.
# Update it in the same change that records a new mainnet upgrade.
DEPLOYED_BASE = '278fbbcc781b2d614a6191bc9ef60bc9402efa35'


def find_solc():
    if os.environ.get('SOLC'):
        return os.environ['SOLC']
    home = pathlib.Path.home()
    for d in [home / '.svm', home / '.local/share/svm', home / 'Library/Application Support/svm']:
        candidate = d / '0.8.24' / 'solc-0.8.24'
        if candidate.exists():
            return str(candidate)
    raise SystemExit('solc 0.8.24 not found; run `forge build` once or set SOLC')


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument('--base', action='append', help='git ref of a baseline to compare against (repeatable)')
cli = parser.parse_args()
bases = cli.base or [b for b in os.environ.get('STORAGE_LAYOUT_BASE', '').split(',') if b] or [DEPLOYED_BASE]
solc = find_solc()
remaps = {'@openzeppelin/contracts/': 'lib/openzeppelin-contracts/contracts/', '@openzeppelin/contracts-upgradeable/': 'lib/openzeppelin-contracts-upgradeable/contracts/', 'solady/': 'lib/solady/src/'}


def exists_at(ref, path):
    return subprocess.run(['git', 'cat-file', '-e', ref + ':' + path], capture_output=True).returncode == 0


def build(ref, base_ref):
    sources = {}

    def add(path):
        if path in sources:
            return
        if ref and path.startswith('src/'):
            content = subprocess.check_output(['git', 'show', ref + ':' + path], text=True)
        else:
            content = pathlib.Path(path).read_text()
        sources[path] = {'content': content}
        for imp in re.findall(r'import\s+(?:[^;]*?from\s+)?[\"\x27]([^\"\x27]+)', content):
            if imp.startswith('.'):
                p = posixpath.normpath(posixpath.join(posixpath.dirname(path), imp))
            else:
                p = imp
                for prefix, target in remaps.items():
                    if p.startswith(prefix):
                        p = target + p[len(prefix):]
                        break
            add(p)

    # Only layouts that already exist at the baseline can be compared; new namespaces are free.
    layout_paths = [str(p) for p in pathlib.Path('src').rglob('*.sol') if 'struct Layout' in p.read_text() and p.name != 'StorageLib.sol' and exists_at(base_ref, str(p))]
    extra = [p for p in ['src/events/EventMarket.sol'] if exists_at(base_ref, p)]
    for p in ['src/libraries/StorageLib.sol'] + extra + layout_paths:
        add(p)
    libs = re.findall(r'library\s+(\w+)\s*\{', sources['src/libraries/StorageLib.sol']['content'])
    harness = 'pragma solidity 0.8.24; import "src/libraries/StorageLib.sol";\n' + ''.join('import "' + p + '";\n' for p in layout_paths)
    for lib in libs + [pathlib.Path(p).stem for p in layout_paths]:
        harness += f'contract {lib}Harness {{ {lib}.Layout internal state; }}\n'
    sources['LayoutHarness.sol'] = {'content': harness}
    args = {'language': 'Solidity', 'sources': sources, 'settings': {'evmVersion': 'cancun', 'remappings': [k + '=' + v for k, v in remaps.items()], 'outputSelection': {'*': {'*': ['storageLayout']}}}}
    run = subprocess.run([solc, '--standard-json'], input=json.dumps(args), text=True, capture_output=True)
    out = json.loads(run.stdout)
    errors = [e['formattedMessage'] for e in out.get('errors', []) if e['severity'] == 'error']
    if errors:
        raise Exception(errors)
    return out['contracts']


def compare(base_ref):
    a, b = build(base_ref, base_ref), build(None, base_ref)
    state = {'checks': 0, 'expansions': []}

    def compare_types(old, new, ot, nt, path):
        x, y = old[ot], new[nt]
        assert x['encoding'] == y['encoding'], path
        if 'members' in x:
            assert len(y['members']) >= len(x['members']), path
            for m, n in zip(x['members'], y['members']):
                assert (m['label'], m['slot'], m['offset']) == (n['label'], n['slot'], n['offset']), (path, m, n)
                state['checks'] += 1
                compare_types(old, new, m['type'], n['type'], path + '.' + m['label'])
        elif 'key' in x:
            compare_types(old, new, x['key'], y['key'], path + '.key')
            compare_types(old, new, x['value'], y['value'], path + '.value')
        elif 'base' in x:
            if x['numberOfBytes'] != y['numberOfBytes']:
                assert path == 'PauseGuardianStorageHarness.state.rings.value.entries' and x['label'].endswith('[128]') and y['label'].endswith('[721]'), path
                state['expansions'].append(path)
            compare_types(old, new, x['base'], y['base'], path + '[]')
        else:
            assert (x['label'], x['numberOfBytes']) == (y['label'], y['numberOfBytes']), path

    compared = 0
    for file, names in a.items():
        if file != 'LayoutHarness.sol' and file != 'src/events/EventMarket.sol':
            continue
        for name, artifact in names.items():
            old = artifact['storageLayout']
            new = b[file][name]['storageLayout']
            assert len(new['storage']) >= len(old['storage'])
            for m, n in zip(old['storage'], new['storage']):
                assert (m['label'], m['slot'], m['offset']) == (n['label'], n['slot'], n['offset'])
                compare_types(old['types'], new['types'], m['type'], n['type'], name + '.' + m['label'])
            compared += 1
    assert compared > 0 and state['checks'] > 0, 'no layouts compared for ' + base_ref
    return {'base': subprocess.check_output(['git', 'rev-parse', base_ref], text=True).strip(), 'baseRef': base_ref, 'compiler': '0.8.24', 'layoutsCompared': compared, 'memberChecks': state['checks'], 'allowedTrailingArrayExpansions': state['expansions'], 'status': 'PASS'}


results = [compare(ref) for ref in bases]
print(json.dumps(results[0] if len(results) == 1 else results, indent=2))
