import argparse
import json
import os
import re
import socket
import sys
import time

SOCKET = "/run/touch-guard/pam.sock"
CONSOLE = re.compile(r"(/dev/)?tty[0-9]+")
CONNECT_WAIT = 5.0
ANSWER_WAIT = 30.0
DOWN = "touch-guard is not running, so root requests are refused outside a text console (Ctrl+Alt+F3)."
KEY_CUE = "Touch your security key to approve."


def ask(request, path):
    """The daemon's answer, None when it cannot be reached. A daemon that restarts gets a few seconds."""
    deadline = time.monotonic() + CONNECT_WAIT
    while True:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(ANSWER_WAIT)
        try:
            conn.connect(path)
            break
        except OSError:
            conn.close()
            if time.monotonic() >= deadline:
                return None
            time.sleep(0.2)
    with conn, conn.makefile("rwb") as stream:
        stream.write((json.dumps(request) + "\n").encode())
        stream.flush()
        answer = json.loads(stream.readline(65536))
    return answer if isinstance(answer, dict) else None


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", default=SOCKET)
    parser.add_argument("--describe", action="store_true",
                        help="also show the description through PAM, for dialogs that cover the notification")
    parser.add_argument("--key-cue", action="store_true",
                        help="end the description with the key's cue, for dialogs that show one PAM message at a time")
    args = parser.parse_args(argv)

    request = {key: os.environ.get("PAM_" + key.upper(), "") for key in ("service", "user", "ruser", "tty", "rhost")}
    # pam_exec runs this as a child of the program doing the authentication: sudo, su or polkit's helper.
    request["pid"] = os.getppid()
    try:
        answer = ask(request, args.socket)
    except (OSError, ValueError):
        answer = None
    # A text console stays usable whatever the daemon says, so a broken touch-guard can always be fixed from one.
    if CONSOLE.fullmatch(request["tty"]):
        print(answer.get("message", "") if answer else "touch-guard is not running")
        return 0
    if answer is None:
        print(DOWN)
        return 1
    if answer.get("allow") is not True:
        print(answer.get("message") or "touch-guard refused this request")
        return 1
    if args.describe:
        print("\n".join(text for text in (answer.get("message", ""), KEY_CUE if args.key_cue else "") if text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
