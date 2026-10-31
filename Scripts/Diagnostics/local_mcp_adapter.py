"""Authenticated JSON-only loopback diagnostic adapter for an existing Bridge.

This script binds only to 127.0.0.1 and creates no external listener or tunnel.
The caller key and local credential stay on this machine.
"""
import argparse
import ctypes
import ctypes.wintypes as w
import http.client
import http.server
import json
import os
from pathlib import Path
import secrets

MAX_BODY = 1024 * 1024
MAX_RESPONSE = 8 * 1024 * 1024


def local_credential():
    class Credential(ctypes.Structure):
        _fields_ = [('flags', w.DWORD), ('type', w.DWORD), ('target', w.LPWSTR),
                    ('comment', w.LPWSTR), ('written', w.FILETIME),
                    ('size', w.DWORD), ('blob', ctypes.POINTER(ctypes.c_ubyte)),
                    ('persist', w.DWORD), ('count', w.DWORD), ('attrs', ctypes.c_void_p),
                    ('alias', w.LPWSTR), ('user', w.LPWSTR)]
    api = ctypes.WinDLL('advapi32', use_last_error=True)
    p = ctypes.POINTER(Credential)()
    api.CredReadW.argtypes = [w.LPCWSTR, w.DWORD, w.DWORD,
                             ctypes.POINTER(ctypes.POINTER(Credential))]
    api.CredReadW.restype = w.BOOL
    api.CredFree.argtypes = [ctypes.c_void_p]
    target = 'com.openai.codex-bridge.secrets.service-mcp-path-secret'
    if not api.CredReadW(target, 1, 0, ctypes.byref(p)):
        raise RuntimeError('Cannot read the local Bridge credential: ' + str(ctypes.get_last_error()))
    try:
        value = ctypes.string_at(p.contents.blob, p.contents.size).decode('utf-8')
        if len(value) != 43:
            raise RuntimeError('Invalid local Bridge credential length')
        return value
    finally:
        api.CredFree(p)


def decode_response(raw, request_id):
    try:
        return json.loads(raw)
    except (ValueError, UnicodeDecodeError):
        for event in raw.decode('utf-8').replace('\r\n', '\n').split('\n\n'):
            payload = '\n'.join(line[5:].lstrip() for line in event.splitlines()
                                if line.startswith('data:'))
            if not payload.strip():
                continue
            obj = json.loads(payload)
            if obj.get('id') == request_id and ('result' in obj or 'error' in obj):
                return obj
        raise ValueError('No terminal JSON-RPC result in response')


def plain_result(obj, method, modern):
    result = obj.get('result')
    if not isinstance(result, dict):
        return obj
    if modern:
        result.setdefault('resultType', 'complete')
    if method in ('server/discover', 'initialize'):
        result.get('capabilities', {}).pop('resources', None)
    elif method == 'tools/list':
        # Optional file-transfer widget is excluded; regular tools remain.
        result['tools'] = [t for t in result.get('tools', [])
                           if t.get('name') != 'open_file_transfer']
        for tool in result['tools']:
            tool.pop('_meta', None)
    elif method == 'resources/list':
        result['resources'] = []
    return obj


class Adapter:
    def __init__(self, port, credential):
        self.port, self.credential = port, credential
        self.key = secrets.token_hex(32)
        self.path = '/' + self.key + '/mcp'

    def upstream(self, method, body, headers):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=310)
        safe = {'X-Codex-Bridge-Token': self.credential,
                'Content-Type': 'application/json',
                'Accept': 'application/json, text/event-stream'}
        for name in ('Mcp-Session-Id', 'Mcp-Protocol-Version', 'Mcp-Method', 'Mcp-Name'):
            if headers.get(name):
                safe[name] = headers[name]
        try:
            connection.request(method, '/mcp', body=body, headers=safe)
            response = connection.getresponse()
            raw = response.read(MAX_RESPONSE + 1)
            if len(raw) > MAX_RESPONSE:
                raise ValueError('Response exceeds supported size')
            returned = {name: response.getheader(name) for name in
                        ('Mcp-Session-Id', 'Mcp-Protocol-Version') if response.getheader(name)}
            return response.status, returned, raw
        finally:
            connection.close()

    def handler(self):
        adapter = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass

            def reply(self, status, body=b'', headers=None):
                self.send_response(status)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Cache-Control', 'no-store')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                if self.command != 'HEAD':
                    self.wfile.write(body)
                self.close_connection = True

            def authorized(self):
                return secrets.compare_digest(self.path, adapter.path)

            def do_GET(self):
                self.reply(405 if self.authorized() else 404,
                           headers={'Allow': 'POST, DELETE'})

            do_HEAD = do_GET

            def do_DELETE(self):
                self.handle_rpc()

            def do_POST(self):
                self.handle_rpc()

            def handle_rpc(self):
                if not self.authorized():
                    self.reply(404)
                    return
                if self.headers.get('Transfer-Encoding'):
                    self.reply(400)
                    return
                try:
                    length = int(self.headers.get('Content-Length', '0'))
                except ValueError:
                    self.reply(400)
                    return
                if not 0 <= length <= MAX_BODY:
                    self.reply(413)
                    return
                self.connection.settimeout(10)
                request_id = None
                try:
                    body = self.rfile.read(length)
                    if len(body) != length:
                        self.reply(400)
                        return
                    request = json.loads(body) if body else {}
                    if not isinstance(request, dict):
                        self.reply(400)
                        return
                    request_id = request.get('id')
                    status, headers, raw = adapter.upstream(self.command, body, self.headers)
                    if not raw or status in (202, 204):
                        self.reply(status, raw, headers)
                        return
                    obj = decode_response(raw, request_id)
                    modern = self.headers.get('Mcp-Protocol-Version') == '2026-07-28'
                    obj = plain_result(obj, request.get('method'), modern)
                    encoded = json.dumps(obj, ensure_ascii=False, separators=(',', ':')).encode()
                    self.reply(status, encoded, headers)
                except (ValueError, OSError, http.client.HTTPException):
                    # Never echo upstream URLs, headers, or arbitrary exception text.
                    error = {'jsonrpc': '2.0', 'id': request_id,
                             'error': {'code': -32603, 'message': 'Bridge adapter upstream request failed'}}
                    self.reply(502, json.dumps(error).encode())

        return Handler


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--ports', required=True)
    parser.add_argument('--ready-file', required=True)
    args = parser.parse_args()
    credential = local_credential()
    headers = {'Mcp-Protocol-Version': '2026-07-28', 'Mcp-Method': 'server/discover'}
    probe = json.dumps({'jsonrpc': '2.0', 'id': 'adapter-probe', 'method': 'server/discover',
                        'params': {'_meta': {'io.modelcontextprotocol/protocolVersion': '2026-07-28',
                                            'io.modelcontextprotocol/clientCapabilities': {},
                                            'io.modelcontextprotocol/clientInfo': {'name': 'Bridge HTTPS adapter', 'version': '1'}}}}).encode()
    adapter = None
    for port in args.ports.split(','):
        if not port.isdigit() or not 0 < int(port) <= 65535:
            continue
        candidate = Adapter(int(port), credential)
        try:
            status, _, body = candidate.upstream('POST', probe, headers)
            result = decode_response(body, 'adapter-probe')
            if status == 200 and result.get('result', {}).get('supportedVersions'):
                adapter = candidate
                break
        except (ValueError, OSError, http.client.HTTPException):
            pass
    if adapter is None:
        raise RuntimeError('No running Bridge MCP endpoint found. Keep Bridge running.')
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), adapter.handler())
    server.daemon_threads = True
    ready = {'port': server.server_port, 'path': adapter.path}
    file = Path(args.ready_file)
    temporary = file.with_suffix('.tmp')
    temporary.write_text(json.dumps(ready), encoding='utf-8')
    os.replace(temporary, file)
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
