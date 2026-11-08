import argparse
import html
import json
import os
import pwd
import socket
import subprocess
import sys
import time

SOCKET = "/run/touch-guard/events.sock"
INTERFACE = ["org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications"]


def escape(text):
    return html.escape(text, quote=False)


def render(event, me):
    """Summary and body of a waiting event. Warnings lead, since they are the reason this exists."""
    requesters = event.get("requesters", [])
    warnings = list(event.get("warnings", []))
    for r in requesters:
        warnings.extend(r.get("warnings", []))
    if warnings:
        summary = "CHECK BEFORE TOUCHING"
    else:
        summary = "Touch for " + (requesters[0]["title"] if requesters else "an unknown request")
    # Plasma renders a small HTML subset in notification bodies and folds blank lines, so titles are bold
    # instead of set apart, and program arguments are escaped so they are never read as markup.
    body = [escape(w) for w in warnings]
    for r in requesters:
        if warnings:
            body.append(f"<b>{escape(r['title'])}</b>")
        body.extend(escape(line) for line in r["lines"])
        origin = f"from {r['chain'] or 'unknown'}, pid {r['pid']}"
        if r["user"] not in (me, "root"):
            origin += ", user " + r["user"]
        body.append(escape(origin))
        if r.get("cwd"):
            body.append(escape("in " + r["cwd"]))
    return summary, "\n".join(body)


class Notifications:
    """Plasma's notification server, reached at a fixed address so no environment variable can point elsewhere."""

    def __init__(self, busctl):
        self.command = [busctl, f"--address=unix:path=/run/user/{os.getuid()}/bus", "call", *INTERFACE]

    def notify(self, summary, body):
        result = subprocess.run(
            self.command + ["Notify", "susssasa{sv}i", "Touch Guard", "0", "", summary, body, "0", "1", "urgency", "y",
                            "2", "0"],
            capture_output=True, text=True, check=False)
        parts = result.stdout.split()
        if result.returncode != 0 or len(parts) != 2:
            print(f"notification failed: {result.stderr.strip() or result.stdout.strip()}", file=sys.stderr, flush=True)
            return None
        return int(parts[1])

    def close(self, notification_id):
        subprocess.run(self.command + ["CloseNotification", "u", str(notification_id)], capture_output=True,
                       check=False)


def run(path, notifications):
    me = pwd.getpwuid(os.getuid()).pw_name
    shown = {}
    while True:
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.connect(path)
        except OSError:
            conn.close()
            time.sleep(0.5)
            continue
        with conn, conn.makefile("r", encoding="utf-8") as stream:
            for line in stream:
                try:
                    event = json.loads(line)
                except ValueError:
                    continue
                if event.get("event") == "waiting":
                    notification_id = notifications.notify(*render(event, me))
                    if notification_id is not None:
                        shown[event["id"]] = notification_id
                    answer = {"event": "failed" if notification_id is None else "shown", "id": event["id"]}
                    try:
                        conn.sendall((json.dumps(answer) + "\n").encode())
                    except OSError:
                        break
                elif event.get("event") == "done" and event.get("id") in shown:
                    notifications.close(shown.pop(event["id"]))
        for notification_id in shown.values():
            notifications.close(notification_id)
        shown.clear()
        # The daemon refuses root requests while no notifier is connected, so reconnecting is quick.
        time.sleep(0.5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--busctl", default="busctl")
    parser.add_argument("--socket", default=SOCKET)
    args = parser.parse_args()
    sys.exit(run(args.socket, Notifications(args.busctl)))
