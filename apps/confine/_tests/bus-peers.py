"""Two ends of a conversation on the session bus, to test what a filtering proxy lets through.

serve NAME READY  owns NAME, answers every call and then sends the caller a signal addressed to it alone
call NAME         calls the owner of NAME and waits for that signal: exit 0 with it, 3 with the answer alone
"""
import sys
import time

from jeepney import DBusAddress, HeaderFields, MessageType, new_method_call, new_method_return, new_signal
from jeepney.bus_messages import message_bus
from jeepney.io.blocking import open_dbus_connection

PATH = "/com/test/Peer"
IFACE = "com.test.Peer"


def ask_bus(conn, message):
    reply = conn.send_and_get_reply(message, timeout=10)
    if reply.header.message_type != MessageType.method_return:
        sys.exit(f"the bus refused: {reply.body}")
    return reply.body


def serve(name, ready):
    conn = open_dbus_connection(bus="SESSION")
    if ask_bus(conn, message_bus.RequestName(name))[0] != 1:
        sys.exit(f"{name} is taken")
    open(ready, "w").close()
    while True:
        message = conn.receive()
        if message.header.message_type != MessageType.method_call:
            continue
        conn.send(new_method_return(message))
        signal = new_signal(DBusAddress(PATH, interface=IFACE), "Done")
        signal.header.fields[HeaderFields.destination] = message.header.fields[HeaderFields.sender]
        conn.send(signal)


def call(name):
    conn = open_dbus_connection(bus="SESSION")
    owner = ask_bus(conn, message_bus.GetNameOwner(name))[0]
    ask_bus(conn, message_bus.AddMatch(f"type='signal',sender='{owner}',interface='{IFACE}'"))
    serial = next(conn.outgoing_serial)
    conn.send(new_method_call(DBusAddress(PATH, bus_name=owner, interface=IFACE), "Poke"), serial=serial)
    answered = False
    deadline = time.monotonic() + 10
    while True:
        try:
            message = conn.receive(timeout=max(deadline - time.monotonic(), 0))
        except TimeoutError:
            sys.exit(3 if answered else 4)
        kind = message.header.message_type
        if kind == MessageType.signal and message.header.fields.get(HeaderFields.member) == "Done":
            return
        if message.header.fields.get(HeaderFields.reply_serial) != serial:
            continue
        if kind != MessageType.method_return:
            sys.exit(f"the call failed: {message.body}")
        # The signal follows the answer at once when it is let through at all.
        answered = True
        deadline = time.monotonic() + 2


if __name__ == "__main__":
    if sys.argv[1:2] == ["serve"] and len(sys.argv) == 4:
        serve(sys.argv[2], sys.argv[3])
    elif sys.argv[1:2] == ["call"] and len(sys.argv) == 3:
        call(sys.argv[2])
    else:
        sys.exit(__doc__)
