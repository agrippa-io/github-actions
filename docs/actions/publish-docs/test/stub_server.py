"""Stub docs API + token endpoint for publish-docs tests (no network)."""
import hashlib
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STORE = {}  # (key, version) -> sha256 of the canonical document
LOG = sys.argv[2]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        form = self.rfile.read(length).decode()
        ok = self.path == '/token' and 'grant_type=client_credentials' in form and 'scope=docs%3Apublish' in form or 'scope=docs:publish' in form
        self.reply(200 if ok else 400, {'access_token': 'fetched-token'} if ok else {'error': 'bad'})

    def do_PUT(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length))
        parts = self.path.strip('/').split('/')  # docs/v1/sources/<key>/versions/<v>
        with open(LOG, 'a') as log:
            log.write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization'), 'body': {k: v for k, v in body.items() if k != 'document'}}) + '\n')
        if self.headers.get('Authorization') not in ('Bearer good-token', 'Bearer fetched-token'):
            return self.reply(401, {'message': 'Invalid service token'})
        if parts[-3] == 'boom':
            return self.reply(500, {'message': 'boom'})
        key = (parts[-3], parts[-1])
        digest = hashlib.sha256(json.dumps(body['document'], sort_keys=True).encode()).hexdigest()
        if key in STORE:
            return self.reply(200, {'outcome': 'unchanged'}) if STORE[key] == digest else self.reply(409, {'message': 'different content'})
        STORE[key] = digest
        return self.reply(201, {'outcome': 'created'})


HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
