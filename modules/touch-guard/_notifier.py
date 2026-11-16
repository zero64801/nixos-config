import argparse
import html
import json
import os
import pwd
import socket
import subprocess
import sys
import threading
import time

SOCKET = "/run/touch-guard/events.sock"
INTERFACE = ["org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications"]
CLOSED = "type='signal',interface='org.freedesktop.Notifications',member='NotificationClosed'"
BY_THE_USER = 2


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


def dismissed_id(line, server):
    """The notification this bus message reports as closed by the user, None for any other message.

    Every program on the bus can send such a signal, a sandboxed one included, so only the server's own counts.
    A notification the notifier closes itself comes back with another reason.
    """
    try:
        message = json.loads(line)
        notification_id, reason = message["payload"]["data"]
    except (ValueError, TypeError, KeyError):
        return None
    if message.get("member") != "NotificationClosed" or reason != BY_THE_USER or type(notification_id) is not int:
        return None
    owner = server()
    return notification_id if owner and message.get("sender") == owner else None


class Notifications:
    """Plasma's notification server, reached at a fixed address so no environment variable can point elsewhere."""

    def __init__(self, busctl):
        self.busctl = [busctl, f"--address=unix:path=/run/user/{os.getuid()}/bus"]
        self.command = self.busctl + ["call", *INTERFACE]

    def notify(self, summary, body):
        # A resident notification can be put aside in Plasma without closing it, which would cancel the request.
        result = subprocess.run(
            self.command + ["Notify", "susssasa{sv}i", "Touch Guard", "0", "", summary, body, "0",
                            "2", "urgency", "y", "2", "resident", "b", "true", "0"],
            capture_output=True, text=True, check=False)
        parts = result.stdout.split()
        if result.returncode != 0 or len(parts) != 2:
            print(f"notification failed: {result.stderr.strip() or result.stdout.strip()}", file=sys.stderr, flush=True)
            return None
        return int(parts[1])

    def close(self, notification_id):
        subprocess.run(self.command + ["CloseNotification", "u", str(notification_id)], capture_output=True,
                       check=False)

    def server(self):
        result = subprocess.run(
            self.busctl + ["call", "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                           "GetNameOwner", "s", INTERFACE[0]],
            capture_output=True, text=True, check=False)
        parts = result.stdout.split()
        return parts[1].strip('"') if result.returncode == 0 and len(parts) == 2 else None

    def dismissed(self):
        """Ids of notifications as the user closes them, for as long as the bus can be watched."""
        with subprocess.Popen(self.busctl + ["monitor", "--json=short", "--match=" + CLOSED],
                              stdout=subprocess.PIPE, text=True) as monitor:
            for line in monitor.stdout:
                notification_id = dismissed_id(line, self.server)
                if notification_id is not None:
                    yield notification_id


def run(path, notifications):
    me = pwd.getpwuid(os.getuid()).pw_name
    shown = {}
    conn = None
    lock = threading.Lock()

    def tell(message):
        """False when the daemon did not get it."""
        with lock:
            try:
                conn.sendall((json.dumps(message) + "\n").encode())
            except (OSError, AttributeError):
                return False
            return True

    def cancel_dismissed():
        while True:
            for notification_id in notifications.dismissed():
                with lock:
                    event_id = next((e for e, shown_id in shown.items() if shown_id == notification_id), None)
                if event_id is not None:
                    tell({"event": "cancel", "id": event_id})
            time.sleep(5)

    threading.Thread(target=cancel_dismissed, daemon=True).start()
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
                        with lock:
                            shown[event["id"]] = notification_id
                    if not tell({"event": "failed" if notification_id is None else "shown", "id": event["id"]}):
                        break
                elif event.get("event") == "done" and event.get("id") in shown:
                    with lock:
                        notification_id = shown.pop(event["id"])
                    notifications.close(notification_id)
        with lock:
            closing = list(shown.values())
            shown.clear()
        for notification_id in closing:
            notifications.close(notification_id)
        # The daemon refuses root requests while no notifier is connected, so reconnecting is quick.
        time.sleep(0.5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--busctl", default="busctl")
    parser.add_argument("--socket", default=SOCKET)
    args = parser.parse_args()
    sys.exit(run(args.socket, Notifications(args.busctl)))
