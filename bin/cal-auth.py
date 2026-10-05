#!/usr/bin/env python3
"""One-time Google Calendar consent for the weekly report.

Google issues a refresh token once, on the first consent, and only when the
request asks for offline access with prompt=consent. Everything after this runs
headless: weekly-report.sh trades that refresh token for an hour-long access
token each time it builds a report.

Needs a Desktop-app OAuth client (Google Cloud console -> APIs & Services ->
Credentials) in a project with the Calendar API enabled. Run this, follow the
printed URL, done.

    bin/cal-auth.py [--force]

Stdlib only, like the rest of the plugin - no google-auth to install.
"""
import http.server
import json
import os
import secrets
import sys
import urllib.parse
import urllib.request
import webbrowser

AUTH_ENDPOINT = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_ENDPOINT = "https://oauth2.googleapis.com/token"
# Read-only, and events only: this cannot list your calendars' settings, edit
# anything, or see a calendar you have not named in WORKLOG_CAL_IDS.
SCOPE = "https://www.googleapis.com/auth/calendar.events.readonly"

dest = os.environ.get("WORKLOG_CAL_AUTH_FILE") or os.path.expanduser(
    "~/.claude/time-logger/cal-auth")

if os.path.exists(dest) and "--force" not in sys.argv:
    sys.exit(f"{dest} already exists. Re-run with --force to replace it.")

client_id = input("OAuth client ID: ").strip()
client_secret = input("Client secret: ").strip()
if not client_id or not client_secret:
    sys.exit("Both are required.")

state = secrets.token_urlsafe(16)
received = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        query = urllib.parse.urlparse(self.path).query
        params = {k: v[0] for k, v in urllib.parse.parse_qs(query).items()}
        if "code" in params or "error" in params:
            received.update(params)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        done = "code" in received and received.get("state") == state
        self.wfile.write(
            b"Authorised. Back to the terminal." if done
            else b"Failed. Back to the terminal.")

    def log_message(self, *args):
        pass


# Port 0 lets the OS pick. A Desktop-app client accepts any port on the
# loopback address, so nothing needs registering in the console.
server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
redirect_uri = f"http://127.0.0.1:{server.server_port}"

url = AUTH_ENDPOINT + "?" + urllib.parse.urlencode({
    "client_id": client_id,
    "redirect_uri": redirect_uri,
    "response_type": "code",
    "scope": SCOPE,
    "access_type": "offline",   # without this there is no refresh token at all
    "prompt": "consent",        # and without this, none on a repeat consent
    "state": state,
})

print(f"\nOpen this and approve:\n\n{url}\n")
# The URL is printed first because it is the fallback: over ssh there is
# nothing to open it with. The return value is not worth branching on - a
# DISPLAY-less box still has xdg-open in /usr/bin and it exits 0 having done
# nothing - so the message promises an attempt, not a window.
try:
    webbrowser.open(url)
except Exception:
    pass
print("Trying to open that in your browser. If nothing appears, use the URL above.")
print("\nWaiting...")
# A browser also asks for /favicon.ico, so serve until the redirect lands
# rather than handling exactly one request.
while "code" not in received and "error" not in received:
    server.handle_request()

if received.get("error"):
    sys.exit(f"Google returned: {received['error']}")
if received.get("state") != state:
    sys.exit("State mismatch - discarded, nothing written.")

body = urllib.parse.urlencode({
    "code": received["code"],
    "client_id": client_id,
    "client_secret": client_secret,
    "redirect_uri": redirect_uri,
    "grant_type": "authorization_code",
}).encode()
with urllib.request.urlopen(
        urllib.request.Request(TOKEN_ENDPOINT, data=body), timeout=30) as response:
    token = json.load(response)

if "refresh_token" not in token:
    sys.exit("No refresh token in the response. Revoke this app at "
             "https://myaccount.google.com/permissions and run again.")

os.makedirs(os.path.dirname(dest), exist_ok=True)
# Written 600 before anything goes in: the secret and the refresh token
# together are standing read access to the calendar.
fd = os.open(dest, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as fh:
    json.dump({"client_id": client_id,
               "client_secret": client_secret,
               "refresh_token": token["refresh_token"]}, fh, indent=2)

print(f"\nWritten to {dest} (chmod 600).")
print("The next weekly report will carry a `Source 4 - calendar` section.")
