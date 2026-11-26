"""Stub docs API + token endpoint for publish-docs tests (no network)."""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

STORE = {}  # (key, version) -> sha256 of the canonical document
LOG = sys.argv[2]
FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'fixtures')


def summary(document):
    """What the tests assert on about a published document (not the whole thing)."""
    out = {'keys': sorted(document)}
    if 'endpoint' in document:
        out['endpoint'] = document['endpoint']
    if isinstance(document.get('sdl'), str):
        out['sdlHead'] = document['sdl'].splitlines()[0]
    if isinstance(document.get('__schema'), dict):
        out['queryType'] = (document['__schema'].get('queryType') or {}).get('name')
    return out


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

    def graphql(self, raw):
        """A GraphQL server to introspect: /graphql answers, the others fail."""
        with open(LOG, 'a') as log:
            log.write(json.dumps({'path': self.path, 'graphql': json.loads(raw)}) + '\n')
        if self.path.startswith('/graphql-errors'):
            return self.reply(200, {'errors': [{'message': 'introspection is disabled'}]})
        if self.path.startswith('/graphql-down'):
            return self.reply(503, {'message': 'down'})
        query = json.loads(raw).get('query', '')
        if '__schema' not in query:
            return self.reply(400, {'errors': [{'message': 'not an introspection query'}]})
        with open(os.path.join(FIXTURES, 'introspection.json')) as f:
            return self.reply(200, json.load(f))

    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        raw = self.rfile.read(length)
        if self.path.startswith('/graphql') or self.path.startswith('/api/graphql'):
            return self.graphql(raw)
        form = raw.decode()
        ok = self.path == '/token' and 'grant_type=client_credentials' in form and 'scope=docs%3Apublish' in form or 'scope=docs:publish' in form
        self.reply(200 if ok else 400, {'access_token': 'fetched-token'} if ok else {'error': 'bad'})

    def do_PUT(self):
        length = int(self.headers.get('Content-Length', 0))
        body = json.loads(self.rfile.read(length))
        parts = self.path.strip('/').split('/')  # docs/v1/sources/<key>/versions/<v>
        with open(LOG, 'a') as log:
            log.write(json.dumps({'path': self.path, 'auth': self.headers.get('Authorization'), 'body': {k: v for k, v in body.items() if k != 'document'}, 'doc': summary(body['document'])}) + '\n')
        if self.headers.get('Authorization') not in ('Bearer good-token', 'Bearer fetched-token'):
            return self.reply(401, {'message': 'Invalid service token'})
        if any('BROKEN' in r.get('markdown', '') for r in body.get('recipes', [])):
            return self.reply(422, {'error': 'recipe diagnostics', 'details': {'diagnostics': [{'level': 'error', 'pointer': '/recipes/0/steps/0/operation', 'message': 'unknown operation'}]}})
        if parts[-3] == 'boom':
            return self.reply(500, {'message': 'boom'})
        key = (parts[-3], parts[-1])
        digest = hashlib.sha256(json.dumps(body['document'], sort_keys=True).encode()).hexdigest()
        if key in STORE:
            return self.reply(200, {'outcome': 'unchanged'}) if STORE[key] == digest else self.reply(409, {'message': 'different content'})
        STORE[key] = digest
        return self.reply(201, {'outcome': 'created'})


HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
