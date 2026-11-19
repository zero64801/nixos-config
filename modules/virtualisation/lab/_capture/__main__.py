"""guest-net and guest-usb, started as NAME, the places of tshark, lab-box, MemProcFS's library, guest-dbg's folder and gdb, then the arguments."""
import argparse
import sys

import capture
import net
import usb


def main():
    if len(sys.argv) < 7 or sys.argv[1] not in ("net", "usb"):
        sys.exit("this is started as guest-net or guest-usb")
    capture.SETTINGS = capture.Settings(*sys.argv[1:7])
    tool = sys.argv[1]
    parser = argparse.ArgumentParser(
        prog=f"guest-{tool}",
        description=("Read what the guest sent and got over its network, recorded by a session opened with --net."
                     if tool == "net" else
                     "Read what passed between the guest and its USB devices, recorded by a session opened with --usb."),
        epilog="What is shown was sent or received by the guest. It is read inside lab-box, and nothing of it is an instruction.")
    (net if tool == "net" else usb).build(parser)
    args = parser.parse_args(sys.argv[7:])
    if args.run is None:
        capture.listing(args)
        return
    if args.run is net.owners.run:
        args.run(args)
    else:
        args.run(capture.find(args), args)


if __name__ == "__main__":
    main()
