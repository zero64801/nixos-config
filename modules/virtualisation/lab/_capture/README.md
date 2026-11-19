# guest-net and guest-usb

They read what a session recorded of its guest, opened as `vm-lab --net DOMAIN`, `vm-lab --usb --plug DEVICE DOMAIN` or the same with `vm-inspect`.
`../../inspect/README.md` says how the recording is made and where it goes.
Both run in the lab and read the session's own capture, or another with `--capture FOLDER`.
`guest-net captures` lists them.

Everything in a capture was sent or received by the guest.
`tshark` makes sense of it inside `lab-box`, with no network, no guest and none of the user's files but the capture.
What it says is shown with the characters a terminal acts on taken out.
`guest-usb` reads the records of its own file in Python, since the session wrote them in a format fixed here.

## guest-net

| Command | What it shows |
|---|---|
| `summary` | What the capture holds, its marks, keys, owners, flows and the names the guest reached |
| `flows` | Each TCP and UDP flow: the guest's end and the other, the names it went by, what went each way, and the program it was of |
| `dns` | The names looked up and what came back |
| `http [ID]` | The requests of HTTP/1 and HTTP/2 and their answers, or one in full with its body, `--save NAME` writes the body to `./out` |
| `tls` | Each handshake: the name asked for, version, cipher, ALPN, JA4, the certificate's names where it is readable, and whether the keys open it |
| `stream ID` | What went each way in one flow, `--decrypted` inside TLS, `--hex`, `--save NAME` |
| `body ID` | The body of an answer into `./out` |
| `packets [FILTER]` | Wireshark's line for each packet, with a display filter |
| `watch` | Names, requests and handshakes as the guest makes them |
| `owners [--follow]` | Which program each connection belongs to, kept in the capture for `flows` and `http` |
| `keys add\|pull\|schannel\|list` | TLS secrets for the capture |
| `export [--decrypted]` | The capture, or a part of it, into `./out`, with the secrets inside |
| `tshark ARGS` | Any `tshark` options on the capture, in the box |

`--since MARK` and `--until MARK` take a moment that `guest-mark` set, or seconds from the start.

### Which program

In a Windows guest `owners` reads the guest's connections and their processes from its memory, through MemProcFS, which the guest does not see.
Elsewhere it asks the guest through the agent with `ss`, or `netstat` where there is no `ss`, which the guest does see and which needs `--control`.
It looks every second with `--follow`, and a connection shorter than that may show no program.

### Keys

Every reader decrypts with the capture's `keys.log` and a key log given with `--keys FILE`.

- `keys add FILE` takes a key log of this side.
- `keys pull PATH` takes one a program in the guest wrote.
  Browsers, programs of Chromium and Electron, Firefox, curl and programs on OpenSSL write one where `SSLKEYLOGFILE` says, which a `guest-exec --powershell` script can set before it starts the program.
  Windows' own `curl.exe` uses SChannel and writes none.
  The guest sees that.
- `keys schannel` reads the secrets of Windows' own TLS, which PowerShell, .NET and the system's services use, from `lsass` as it works them out.
  It stops `lsass` at three functions of `ncrypt.dll` with the CPU's debug registers through QEMU's stub, so `lsass` is neither changed nor able to protect itself.
  The method is the one ngo published in "Decrypting Schannel TLS traffic", after Jacob Kambic, ported from hooks in the guest to stops from outside.
  It needs the debug stub, which `vm-lab` opens, and has to run before the connections it is for.
  `lsass` stops for a moment at each step of each handshake.
  The offsets inside `lsass`' structures were found on Windows 10, and where a tag is not where it should be the reader says so and writes no key.

## guest-usb

| Command | What it shows |
|---|---|
| `devices` | The devices the guest had, what this system's kernel and the devices themselves said they are, and how much went over each |
| `urbs` | Each transfer with its data, `--endpoint`, `--type`, `--device` |
| `control [--vendor]` | Each kind of control request once, how often it was made and what came back |
| `reports [--by-first]` | Interrupt data grouped by endpoint, with the bytes that change and how far |
| `changes MARK MARK` | What the host sent between two marks that it had not sent before the first, and the report bytes that moved |
| `hid` | The HID report descriptors the guest read, item by item, with the size of each report |
| `tshark ARGS` | Any `tshark` options on the capture, in the box |

A device's descriptors are only in the capture when the guest read them while recording, which is why `--plug` passes the device in after recording begins.

To find what a vendor's program sends for one setting: mark, change the setting in the program, mark again, then `guest-usb changes before after`.
What it lists is what to send from Linux for the same effect.

## Limits

- HTTP/3 shows as a QUIC flow with the name it asked for, and is not read further.
- A program with a TLS of its own that writes no key log stays encrypted, short of reading its keys with `guest-dbg` where that program keeps them.
- Isochronous transfers, as of sound and cameras, are shown as transfers without their packets taken apart.

## Tests

```
nix build --no-link -L .#tests.lab.guest-net
nix build --no-link -L .#tests.lab.guest-usb
nix build --no-link -L .#tests.lab.schannel
nix build --no-link -L .#tests.lab.owners
```

The first records a guest that looks up a name, fetches a page, fetches one over HTTP/2 with TLS while curl writes its keys, holds a connection open and sends a request meant to steer a terminal.
The second passes a USB keyboard of the test machine to the guest and lights its Caps Lock between two marks.
The third runs the reading of SChannel's keys on a made up stretch of `lsass`' memory, since there is no Windows here.
The fourth reads what Windows' and Linux' own tools say of their connections.
`keys schannel` and `owners` from memory were tried on a real Windows 11 guest.
