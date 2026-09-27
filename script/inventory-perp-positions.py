#!/usr/bin/env python3
"""Read-only inventory of a live PerpEngine: subjects, position ids, open interest, live positions.

Uses only eth_blockNumber, eth_getCode, eth_getLogs and eth_call. Never signs or sends anything.

    python3 script/inventory-perp-positions.py --rpc "$BASE_RPC_URL" \
        --engine 0x24b84FAA257d811213f488d48A7BB276cdCf9D9F \
        --registry 0xae1C575368311C9b9C0405270B0992A3bCa51CB6

Subjects are collected from every PerpEngine PositionOpened / MarkPushed log and from every
SubjectRegistry log's first indexed topic (a superset; non-subject topics simply read zero OI).
Position ids come from every PositionOpened log. Prints SUBJECT_IDS for
script/UpgradePerpEngine.s.sol and exits non-zero when any OI or live position is found.
"""
import argparse, json, sys, time, urllib.error, urllib.request

POSITION_OPENED = '0x681339de2fc0d7f07de725291ff0a0f2e7996e23624c3eb0e1dc7a7264a28cbf'
MARK_PUSHED = '0x173b47b88463e1ee6e805276169f15891ed9e154c6d205daa7429cd5b2ea99d4'
# Selectors from `cast sig`: openInterestOf(bytes32), positionOf(bytes32).
SELECTORS = {'openInterestOf(bytes32)': '0x95b25ab0', 'positionOf(bytes32)': '0x9fedf616'}

ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
ap.add_argument('--rpc', required=True)
ap.add_argument('--engine', required=True)
ap.add_argument('--registry', required=True)
ap.add_argument('--from-block', type=int, help='default: first block where engine or registry has code')
ap.add_argument('--step', type=int, default=1000, help='eth_getLogs block range (public Base mainnet RPC max 2000, Sepolia max 1000)')
args = ap.parse_args()


def rpc(method, params):
    delay = 1.0
    for attempt in range(8):
        try:
            body = json.dumps({'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params}).encode()
            req = urllib.request.Request(args.rpc, body, {'Content-Type': 'application/json', 'User-Agent': 'pm-inventory'})
            res = json.load(urllib.request.urlopen(req, timeout=60))
            if 'error' in res:
                raise RuntimeError(res['error'])
            return res['result']
        except (urllib.error.URLError, RuntimeError, TimeoutError) as err:
            last = err
            time.sleep(delay)
            delay = min(delay * 2, 16)
    raise SystemExit(f'{method} failed: {last}')


head = int(rpc('eth_blockNumber', []), 16)


def first_code_block(addr):
    lo, hi = 0, head
    while lo < hi:
        mid = (lo + hi) // 2
        if rpc('eth_getCode', [addr, hex(mid)]) not in ('0x', ''):
            hi = mid
        else:
            lo = mid + 1
    return lo


start = args.from_block if args.from_block is not None else min(first_code_block(args.engine), first_code_block(args.registry))


def logs(addr):
    out, block = [], start
    while block <= head:
        end = min(block + args.step - 1, head)
        out += rpc('eth_getLogs', [{'address': addr, 'fromBlock': hex(block), 'toBlock': hex(end)}])
        block = end + 1
    return out


engine_logs, registry_logs = logs(args.engine), logs(args.registry)
subjects, positions = set(), set()
for log in engine_logs:
    if log['topics'][0] == POSITION_OPENED:
        positions.add(log['topics'][1])
        subjects.add(log['topics'][3])
    elif log['topics'][0] == MARK_PUSHED:
        subjects.add(log['topics'][1])
for log in registry_logs:
    if len(log['topics']) > 1:
        subjects.add(log['topics'][1])


def call(sig, word):
    return rpc('eth_call', [{'to': args.engine, 'data': SELECTORS[sig] + word[2:]}, hex(head)])


nonzero_oi, live = [], []
for subject in sorted(subjects):
    r = call('openInterestOf(bytes32)', subject)
    long_oi, short_oi = int(r[2:66], 16), int(r[66:130], 16)
    if long_oi or short_oi:
        nonzero_oi.append((subject, long_oi, short_oi))
for position in sorted(positions):
    r = call('positionOf(bytes32)', position)
    if int(r[2:66], 16):  # Position.size != 0
        live.append(position)

print(json.dumps({
    'engine': args.engine, 'fromBlock': start, 'atBlock': head,
    'engineLogs': len(engine_logs), 'registryLogs': len(registry_logs),
    'positionOpenedLogs': sum(1 for l in engine_logs if l['topics'][0] == POSITION_OPENED),
    'subjectsChecked': len(subjects), 'positionIdsChecked': len(positions),
    'subjectsWithOpenInterest': [{'subject': s, 'long': l, 'short': h} for s, l, h in nonzero_oi],
    'livePositions': live,
}, indent=2))
print('SUBJECT_IDS=' + ','.join(sorted(subjects)))
sys.exit(1 if nonzero_oi or live else 0)
