"""A way out of a sandbox that leads to named hosts and nowhere else.

  host-gate gate SOCKET HOST:PORT... [--through ADDRESS:PORT]
  host-gate door ADDRESS:PORT SOCKET

The gate runs outside the sandbox. It listens on a unix socket as an HTTP proxy that takes CONNECT for the hosts it
was given and refuses everything else, and reaches them by itself or through another HTTP proxy. The door runs
inside, for programs that can only be pointed at a proxy on an address: it listens there and hands each connection
to the socket. The gate never sees what is said, only whom it is said to.
"""
import asyncio
import sys

HEAD, PATIENCE = 8192, 15


async def passed(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
        if writer.can_write_eof():
            writer.write_eof()
    except (OSError, asyncio.IncompleteReadError):
        pass


async def joined(here, there):
    """Lets two connections talk until both have said all, then closes them."""
    try:
        await asyncio.gather(passed(here[0], there[1]), passed(there[0], here[1]))
    finally:
        for _, writer in (here, there):
            writer.close()


async def head(reader):
    return (await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), PATIENCE)).decode("latin-1")


async def said(writer, status):
    writer.write(f"HTTP/1.1 {status}\r\n\r\n".encode())
    await writer.drain()


def gate(allowed, through):
    async def asked(reader, writer):
        try:
            words = (await head(reader)).split("\r\n", 1)[0].split()
            if len(words) != 3 or words[0] != "CONNECT":
                return await said(writer, "405 Only CONNECT passes here")
            target = words[1].lower()
            if target not in allowed:
                print(f"host-gate: refused the way to {target[:200]!r}", file=sys.stderr, flush=True)
                return await said(writer, "403 Not a host this gate leads to")
            host, _, port = target.rpartition(":")
            if through:
                there = await asyncio.wait_for(asyncio.open_connection(*through), PATIENCE)
                there[1].write(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n".encode())
                await there[1].drain()
                if (await head(there[0])).split()[1:2] != ["200"]:
                    there[1].close()
                    return await said(writer, "502 The proxy behind the gate refused")
            else:
                there = await asyncio.wait_for(asyncio.open_connection(host, int(port)), PATIENCE)
            await said(writer, "200 Connection established")
            await joined((reader, writer), there)
        except (OSError, ValueError, TimeoutError, asyncio.IncompleteReadError, asyncio.LimitOverrunError):
            pass
        finally:
            writer.close()

    return asked


def door(socket):
    async def entered(reader, writer):
        try:
            await joined((reader, writer), await asyncio.open_unix_connection(socket))
        except OSError:
            writer.close()

    return entered


def address(text):
    host, _, port = text.rpartition(":")
    return host, int(port)


async def main(words):
    if len(words) >= 3 and words[0] == "gate":
        through = None
        if "--through" in words:
            through = address(words[words.index("--through") + 1])
            words = words[:words.index("--through")]
        server = await asyncio.start_unix_server(gate({word.lower() for word in words[2:]}, through), words[1], limit=HEAD)
    elif len(words) == 3 and words[0] == "door":
        server = await asyncio.start_server(door(words[2]), *address(words[1]))
    else:
        sys.exit(__doc__.split("\n\n")[1])
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main(sys.argv[1:]))
    except KeyboardInterrupt:
        pass
