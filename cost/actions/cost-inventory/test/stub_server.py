"""Stub Cost Planner for cost-inventory tests (no network): POST /<base>/webhooks/inventory-sync."""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = sys.argv[2]
TOKEN = 'good-token'
RUNNING = {'n': 0}


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

    def do_GET(self):
        self.reply(200, {'ok': True})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length') or 0)).decode() or '{}'
        auth = self.headers.get('Authorization', '')
        with open(LOG, 'a') as log:
            log.write(json.dumps({'path': self.path, 'auth': auth, 'body': json.loads(raw)}) + '\n')
        if not self.path.endswith('/webhooks/inventory-sync'):
            return self.reply(404, {'message': 'not found'})
        if self.path.startswith('/unconfigured/'):
            return self.reply(503, {'message': 'not configured'})
        if self.path.startswith('/boom/'):
            return self.reply(500, {'message': 'boom'})
        if auth != f'Bearer {TOKEN}':
            return self.reply(401, {'message': 'unauthorized'})
        RUNNING['n'] += 1
        return self.reply(202, {'status': 'accepted', 'joined': RUNNING['n'] > 1})


HTTPServer(('127.0.0.1', int(sys.argv[1])), Handler).serve_forever()
