"""Holds a window open on $DISPLAY, dressed as Wine dresses Studio's or as another program's. SIGUSR1 minimizes it.

Usage: studio_window.py TITLE CLASS PID RRGGBB STATE_FILE
The state file gets the window's id and this process's pid once the window shows.
"""
import os
import signal
import sys
import time

from Xlib import X, Xatom, display
from Xlib.ext import composite

title, wm_class, pid, colour, state_file = sys.argv[1:]
d = display.Display()
screen = d.screen()
window = screen.root.create_window(
    0, 0, 320, 240, 0, screen.root_depth, X.InputOutput, X.CopyFromParent,
    background_pixel=int(colour, 16), override_redirect=True)
window.set_wm_name(title)
window.change_property(d.intern_atom("_NET_WM_NAME"), d.intern_atom("UTF8_STRING"), 8, title.encode())
window.set_wm_class(wm_class, wm_class)
window.change_property(d.intern_atom("_NET_WM_PID"), Xatom.CARDINAL, 32, [int(pid)])
window.composite_redirect_window(composite.RedirectAutomatic)
window.map()
d.sync()


def minimize(*_):
    window.unmap()
    d.sync()


signal.signal(signal.SIGUSR1, minimize)
with open(state_file + ".tmp", "w") as f:
    f.write(f"{window.id} {os.getpid()}")
os.rename(state_file + ".tmp", state_file)
while True:
    time.sleep(0.2)
