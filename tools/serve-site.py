"""Serves site/ on this Mac the way nginx serves it online (site/nginx.conf): /privacy is privacy.html,
/terms goes to /privacy#terms.
Usage: python3 tools/serve-site.py [port]   (default 8765), then open http://127.0.0.1:8765"""
import http.server, os, sys

SITE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'site')

class Site(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k):
        super().__init__(*a, directory=SITE, **k)

    def send_head(self):
        path = self.path.split('?', 1)[0].split('#', 1)[0]
        if path == '/terms':
            self.send_response(301)
            self.send_header('Location', '/privacy#terms')
            self.end_headers()
            return None
        local = self.translate_path(path)
        if not os.path.exists(local) and os.path.exists(local + '.html'):
            self.path = path + '.html'
        return super().send_head()

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
print(f'http://127.0.0.1:{port}')
http.server.ThreadingHTTPServer(('127.0.0.1', port), Site).serve_forever()
