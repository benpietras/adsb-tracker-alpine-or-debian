import http.server, os, socket, time, shutil

JSON_DIR = '/run/dump1090'
TRACKER_SRC = '/usr/local/share/tracker.html'
PORT = 8888

# Wait for dump1090 to create the JSON directory
while not os.path.exists(JSON_DIR):
    print(f'Waiting for {JSON_DIR}...')
    time.sleep(2)

os.chdir(JSON_DIR)

# Copy tracker.html into the served directory
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
