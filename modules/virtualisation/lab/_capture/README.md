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
| `http [ID]` | The requests of HTTP/1, HTTP/2 and HTTP/3, their answers and how long each took, or one in full: the headers and bodies of both ways, undone of their encoding, JSON laid out, `--save NAME` writes them to `./out` |
| `ws [ID]` | The messages of each WebSocket both ways, text, binary, ping, pong and close, fragments put together and undone of permessage-deflate, or of one in full with its JSON laid out, `--save NAME` writes them to `./out` as JSON lines. Those of HTTP/1 by flow, those a CONNECT of HTTP/2 or HTTP/3 opened by request, without times of their own |
| `tls` | Each handshake: the name asked for, version, cipher, ALPN, JA4, the certificate's names where it is readable, and whether the keys open it |
| `stream ID` | What went each way in one flow, `--decrypted` inside TLS, `--hex`, `--save NAME` |
| `body ID` | The body of an answer into `./out`, or with `--request` the request's, undone of its encoding |
| `packets [FILTER]` | Wireshark's line for each packet, with a display filter |
| `watch` | Names, requests and handshakes as the guest makes them |
| `owners [--follow]` | Which program each connection belongs to, kept in the capture for `flows` and `http` |
| `keys add\|pull\|schannel\|scan\|list` | TLS secrets for the capture |
| `export [--decrypted]` | The capture, or a part of it, into `./out`, with the secrets inside |
| `tshark ARGS` | Any `tshark` options on the capture, in the box |

`--since MARK` and `--until MARK` take a moment that `guest-mark` set, or seconds from the start.

`summary`, `flows`, `dns`, `http`, `tls`, `packets`, `export` and `keys scan` keep to part of the traffic:

- `--process NAME|PID` keeps the flows of a program, by its name with or without `.exe`, or its number, more than once for several.
  A flow's program is what `owners` saw while the flow lasted, so flows whose program is not known are left out, and the reader says how many.
- `--children` adds the programs it started, and theirs, from the processes `owners` and `keys scan --follow` recorded of the guest.
- `--host NAME|ADDRESS|NETWORK` keeps flows to a name or a name under it, by the names a flow went by (the name TLS asked for, the HTTP host, the name looked up for its address), or to an address or a network such as `10.0.0.0/8`.
- Both together keep what both allow.
  A flow begun before `--since` still counts.
- `dns --process` shows the lookups of the names the program's flows went to and of the addresses they reached, since Windows looks names up in its DNS client service for every program.
- `keys scan --process` keeps flows whose program is not known as well and searches them in the program named, and `--follow` takes only new flows of the programs and hosts asked for, by the name the client asked for and the address.

Nothing is left out while recording, which costs little and keeps the lookups and the programs a sample starts.

### Which program

In a Windows guest `owners` reads the guest's connections and their processes from its memory, through MemProcFS, which the guest does not see.
Elsewhere it asks the guest through the agent with `ss`, or `netstat` where there is no `ss`, which the guest does see and which needs `--control`.
It looks every second with `--follow`, and a connection shorter than that may show no program.
Each look also keeps which process started which in the capture's `processes.jsonl`, for `--children`.

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
- `keys scan` finds the secrets of any program in its memory, which the guest does not see, so the program talks to the real server with no proxy, no certificate of this side and nothing in its way.
  See below.

### keys scan

A program keeps the secrets of a TLS connection in its memory while the connection lasts, since TLS 1.3 needs them to update its keys.
`keys scan` reads that memory from outside, tries every window that could be a secret against the flow's own encrypted records, and adds to the capture only what opens them, so a key it writes is always the right one.
The idea is that of X-Ray-TLS (Moriconi et al., 2024) and of DRAKVUF's tlsmon, here on MemProcFS and the session's RAM.

- One look: `keys scan` searches the program of each TLS flow of the capture that has no keys, as `owners` saw it or as the guest's memory shows it now, and the programs `--process` names for flows whose program is not known.
  It finds the connections that are still open.
  In a guest that is not Windows it reads the program through the guest's own `/proc/PID/pagemap`, by the agent, which needs `--control` and which the guest sees, and puts its pages together from the RAM in the program's order.
- `keys scan --follow` copies the memory of each new flow's program a few milliseconds after its handshake, and checks the copy as the flow's records come in.
  This is the mode for browsers, which close most connections within a second and wipe their secrets.
  `--pause` holds the whole guest still while it copies, which catches nearly every connection, and takes the debug stub, which `keys schannel` and `guest-gdb` then cannot use.
  The agent waits out each hold, so tools that ask the guest work meanwhile, a little later.
  A QUIC connection's socket is often missing from what MemProcFS lists, and such a flow is searched for in the program whose connection was seen last, a browser's network process, and taken only when its client random is there.
  Its secrets found there prove the program, which is then kept in the capture as the flow's owner, for `--process` and the readers' program column.
  A browser that comes back to a server sends its first requests as early data, under a secret it wipes once the handshake is done, so a QUIC connection whose client sends early data gets a copy of its own at once, from the client's hello alone, which the early data's packets check once the server has answered.
  With that secret tshark opens the early data too, and `http` reads the requests in it.
- `--physical` searches the guest's whole RAM instead of one program's memory, around each client random, without the agent, and is what `--follow` takes in a guest that is not Windows, since the agent cannot answer while the guest is held.
  `--deep` searches all of it, for secrets kept apart from the client random, as OpenSSL's of TLS 1.2 are.

It finds the secrets of OpenSSL, BoringSSL, GnuTLS, NSS, mbedTLS, Go's crypto/tls and rustls, whatever the program is written in, since it looks for the secrets and not for a library's structures.
The libraries most programs use keep the client random beside the secrets, OpenSSL and BoringSSL among them, and its places are searched first at every offset.
The rest is searched at every offset where it is up to 32 MiB and at every eighth beyond, which `--step` changes.
The search itself is in C, `tlsscan/tlsscan.c`, and tries some millions of windows a second.

It knows QUIC, versions 1 and 2, whose client random and suite it reads from the Initial packets by itself, TLS 1.3 with AES-GCM and ChaCha20-Poly1305, TLS 1.2 with AES-GCM, ChaCha20-Poly1305 and AES-CBC, and TLS 1.0 and 1.1 with AES-CBC, older programs and samples still using them, with or without encrypt-then-MAC.
Windows' own TLS keeps its secrets in `lsass`, which `keys schannel` reads.

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

- tshark reads QUIC's streams as HTTP/3 only with the handshake secrets, since it learns the protocol from the server's encrypted extensions, which only those open, and has no setting to name it instead.
  `http` reads HTTP/3 itself, from the stream frames tshark decrypts with the traffic secrets alone: `h3.py` takes apart its frames and its headers' compression, inside `lab-box`, since that is ls-qpack, a library of C, on the guest's bytes.
  A request a resumed connection sent as early data, before the handshake, needs the early data's secret as well.
  Without it the answer shows alone, as asked in early data, and so do the answers whose requests need table entries the client sent then.
- A secret that crosses a page boundary of the program's memory is in two places of the RAM, so `--physical` cannot find it, though the program's own memory, read through MemProcFS or the page map, can.
- A TLS 1.3 connection whose keys were updated holds the newer secrets, which open no record of the start, so `keys scan` finds none of it.
- A program with a TLS of its own that writes no key log stays encrypted, short of reading its keys with `guest-dbg` where that program keeps them.
- Isochronous transfers, as of sound and cameras, are shown as transfers without their packets taken apart.

## Tests

```
nix build --no-link -L .#tests.lab.guest-net
nix build --no-link -L .#tests.lab.guest-usb
nix build --no-link -L .#tests.lab.schannel
nix build --no-link -L .#tests.lab.owners
nix build --no-link -L .#tests.lab.bodies
nix build --no-link -L .#tests.lab.tlsscan
nix build --no-link -L .#tests.lab.tlsscan-libraries
nix build --no-link -L .#tests.lab.tlsscan-quic
nix build --no-link -L .#tests.lab.keys-scan
```

The first records a guest that looks up a name, fetches a page, fetches pages over HTTP/2 with TLS while curl writes its keys, one of them compressed, sends JSON and a form, holds a connection open and sends a request meant to steer a terminal.
The second passes a USB keyboard of the test machine to the guest and lights its Caps Lock between two marks.
The third runs the reading of SChannel's keys on a made up stretch of `lsass`' memory, since there is no Windows here.
The fourth reads what Windows' and Linux' own tools say of their connections.
The fifth undoes the encodings of bodies, gzip, deflate, brotli and zstd, alone and chained, stops at a limit for a body made to grow without end, and lays out JSON.
The sixth runs OpenSSL's client and server in every suite `keys scan` knows, hides the secrets of the client's own key log in made up memory, and has the search find each of them where it was put and nothing else.
The seventh has clients of OpenSSL, GnuTLS, NSS, mbedTLS, Go and rustls each connect with TLS 1.3 and 1.2 and wait, searches their live memory as `keys scan` searches a program of a guest, and checks what it finds against each client's own key log.
The eighth runs aioquic's client and server in every suite and both versions of QUIC, and curl's HTTP/3 on ngtcp2, reads the hellos from the Initial packets alone, also of a client that sends a token in them, splits datagrams sent in one batch, has a client come back with a ticket and send early data, and has the search find each secret where it was put, that of the early data among them.
The ninth has a guest hold two connections of OpenSSL open and connect with curl while the scan follows, and every secret found has to be one the client wrote, and reads curl's request of HTTP/3 and its answer with the secrets found.
The tenth has curl ask aioquic's server several things over one connection of HTTP/3, so that its headers use QPACK's table, and reads them with the traffic secrets alone, then has `h3.py` wait for table instructions that come late, put pieces together that come out of order or twice, read answers whose requests went as early data, and live through what a hostile guest sends.
The eleventh reads a WebSocket of HTTP/1 through tshark, with permessage-deflate both ways, a server that keeps its window between messages, a fragmented message with a ping between its parts, binary data and a close, then one of HTTP/3 from its stream's bytes, and frames that claim more than there is.
`keys schannel`, `owners` from memory and `keys scan` of a process were tried on a real Windows 11 guest, with Edge, Defender and Windows' own services.
