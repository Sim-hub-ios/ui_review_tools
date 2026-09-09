#!/usr/bin/env python3
"""Run V2 stdio contracts against a disposable media-test library, with the App closed."""
import base64
import hashlib
import json
import pathlib
import subprocess
import sys

executable, directory = sys.argv[1:3]
root = pathlib.Path(directory)
database = root / 'library.json'
original = database.read_bytes()
lib = json.loads(original)
review = lib['reviews'][0]
animation = review['animations'][0]
issue = animation['issues'][0]
proc = subprocess.Popen([executable, '--data-dir', str(root)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
sequence = 0

def rpc(method, params):
    global sequence
    sequence += 1
    proc.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': sequence, 'method': method, 'params': params}) + '\n')
    proc.stdin.flush()
    value = json.loads(proc.stdout.readline())
    assert value['id'] == sequence, value
    return value['result']

def tool(name, **kwargs):
    return rpc('tools/call', {'name': name, 'arguments': kwargs})

def text(value):
    assert not value.get('isError'), value
    return json.loads(value['content'][0]['text'])

args = {'review_id': review['id'], 'animation_id': animation['id'], 'expected_revision': lib['revision']}
try:
    rpc('initialize', {'protocolVersion': '2025-11-25'})
    assert len(rpc('tools/list', {})['tools']) == 9
    old = text(tool('get_review', review_id=review['id']))
    assert not {'animations', 'videoAssets', 'itemOrder'} & old.keys()
    assert text(tool('list_animations', review_id=review['id'], limit=1))['animations'][0]['id'] == animation['id']
    detail = text(tool('get_animation', **args))
    assert detail['animation']['issues'][0]['region'] == issue['region']
    result = tool('get_animation_frame', **args, issue_id=issue['id'], variant='annotated', max_dimension=320)
    meta = text(result)['frames'][0]
    assert meta['actualTime'] == issue['region']['actualTime'], meta
    assert max(meta['renderedWidth'], meta['renderedHeight']) == 320
    assert base64.b64decode(result['content'][1]['data']).startswith(b'\x89PNG')
    assert len(json.dumps(result).encode()) < 12_000_000
    frames = tool('get_animation_frames', **args, issue_id=issue['id'], count=3, max_dimension=256)
    assert text(frames)['returnedCount'] == 3
    assert tool('get_animation_frames', **args, issue_id=issue['id'], count=True)['isError']
    assert tool('get_animation_frame', **args, time={'value': 0, 'timescale': True})['isError']
    assert tool('get_animation_frame', **args, time={'value': 0, 'timescale': 1}, source='reference')['isError']
    stale = dict(args, expected_revision='00000000-0000-0000-0000-000000000000')
    assert tool('get_animation', **stale)['isError']
    assert database.read_bytes() == original
    print(f'Motion MCP passed: {sequence} requests; V1 projection, V2 metadata, exact region frame, finite sequence, argument validation, stale revision and read-only data verified.')
finally:
    proc.stdin.close()
    proc.wait(timeout=10)
    assert proc.returncode == 0, proc.stderr.read()
