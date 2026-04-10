import http.server, os, time, shutil

TRACKER_SRC = '/usr/local/share/tracker.html'
PORT = 8888

# Wait for dump1090 to create the JSON directory
JSON_DIR = None
while JSON_DIR is None:
    for d in ('/run/dump1090', '/run/dump1090-mutability'):
        if os.path.exists(d):
            JSON_DIR = d
            break
    if JSON_DIR is None:
        print('Waiting for dump1090 JSON directory...')
        time.sleep(2)

print(f'Using JSON directory: {JSON_DIR}')
os.chdir(JSON_DIR)

if os.path.exists(TRACKER_SRC):
    shutil.copy(TRACKER_SRC, os.path.join(JSON_DIR, 'tracker.html'))


class CORSHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

    def log_message(self, *a):
        pass


http.server.HTTPServer.allow_reuse_address = True
httpd = http.server.HTTPServer(('', PORT), CORSHandler)
print(f'Serving dump1090 JSON on http://localhost:{PORT}')
httpd.serve_forever()
