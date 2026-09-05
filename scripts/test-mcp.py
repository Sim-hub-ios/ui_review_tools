#!/usr/bin/env python3
"""Exercise the actual stdio executable, using a disposable local Review."""
import base64
import hashlib
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import uuid
import zlib


def png():
    def chunk(kind, data):
        return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
    pixels = (b'\x00' + b'\xf0\xf4\xfa' * 80) * 120
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 80, 120, 8, 2, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels)) + chunk(b'IEND', b'')


def main():
    executable = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/ui-review-mcp').resolve()
    with tempfile.TemporaryDirectory(prefix='UIReview-mcp-test-') as directory:
        root = pathlib.Path(directory)
        (root / 'assets').mkdir()
        rid, sid, iid = [str(uuid.uuid4()).upper() for _ in range(3)]
        asset = root / 'assets' / f'{sid}.png'
        asset.write_bytes(png())
        issue = {'id': iid, 'region': {'x': 8, 'y': 12, 'width': 40, 'height': 60},
                 'normalizedRegion': {'x': .1, 'y': .1, 'width': .5, 'height': .5}, 'comment': '统一为 16pt'}
        shot = {'id': sid, 'name': '测试.png', 'createdAt': '2026-09-05T00:00:00Z',
                'pixelWidth': 80, 'pixelHeight': 120, 'originalPath': f'assets/{sid}.png', 'issues': [issue]}
        review = {'id': rid, 'title': 'MCP test', 'createdAt': '2026-09-05T00:00:00Z',
                  'updatedAt': '2026-09-05T00:00:00Z', 'screenshots': [shot]}
        library = {'schemaVersion': 1, 'currentReviewID': rid, 'reviews': [review]}
        database = root / 'library.json'
        database.write_text(json.dumps(library), encoding='utf8')
        before = hashlib.sha256(database.read_bytes() + asset.read_bytes()).hexdigest()
        process = subprocess.Popen([str(executable), '--data-dir', str(root)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        count = 0
        try:
            def request(method, params=None):
                nonlocal count
                count += 1
                process.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': count, 'method': method, 'params': params or {}}) + '\n')
                process.stdin.flush()
                result = json.loads(process.stdout.readline())
                assert result['id'] == count and result['jsonrpc'] == '2.0', result
                return result

            def tool(name, **args):
                return request('tools/call', {'name': name, 'arguments': args})['result']

            assert request('initialize', {'protocolVersion': '2025-11-25', 'clientInfo': {'name': 'test', 'version': '1'}, 'capabilities': {}})['result']['protocolVersion'] == '2025-11-25'
            process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
            process.stdin.flush()
            tools = request('tools/list')['result']['tools']
            assert len(tools) == 5 and all(t['annotations']['readOnlyHint'] for t in tools)
            assert json.loads(tool('get_current_review')['content'][0]['text'])['id'] == rid
            assert len(json.loads(tool('list_reviews')['content'][0]['text'])) == 1
            assert json.loads(tool('get_review', review_id=rid)['content'][0]['text'])['title'] == 'MCP test'
            assert json.loads(tool('get_issues', screenshot_id=sid)['content'][0]['text'])[0]['issues'][0]['comment'] == '统一为 16pt'
            original = tool('get_screenshot', screenshot_id=sid, variant='original')
            assert base64.b64decode(original['content'][1]['data']) == asset.read_bytes()
            annotated = tool('get_screenshot', screenshot_id=sid)
            assert annotated['content'][1]['type'] == 'image'
            assert base64.b64decode(annotated['content'][1]['data']).startswith(b'\x89PNG')
            assert tool('get_screenshot', screenshot_id=sid, variant='bad')['isError']
            assert tool('get_review', review_id='missing')['isError']
            assert tool('get_review')['isError']
            assert tool('get_screenshot', screenshot_id=sid, path='/etc/hosts')['isError']
            assert tool('delete_review', review_id=rid)['isError']
            assert request('unrecognized')['error']['code'] == -32601
            assert request('ping')['result'] == {}
            assert before == hashlib.sha256(database.read_bytes() + asset.read_bytes()).hexdigest(), 'MCP modified user data'
            review['title'] = 'Updated while server running'
            database.write_text(json.dumps(library), encoding='utf8')
            assert json.loads(tool('get_current_review')['content'][0]['text'])['title'] == review['title']
            database.write_text('{bad', encoding='utf8')
            assert tool('get_current_review')['isError']
            process.stdin.close()
            assert process.wait(timeout=10) == 0
            assert not process.stderr.read()
            print(f'MCP integration passed: {count} JSON-RPC requests; original/annotated images, live reload, errors, read-only verified.')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()


if __name__ == '__main__':
    main()
