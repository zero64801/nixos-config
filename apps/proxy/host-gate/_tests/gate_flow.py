"""Sends requests through a door and a gate: the listed host is reached, by itself and through a proxy, nothing else is."""
import asyncio
import os
import sys
import tempfile

GATE = sys.argv[1]


async def echo(reader, writer):
    writer.write(b"host says " + await reader.read(100))
    await writer.drain()
    writer.close()


async def proxy(reader, writer):
    request = (await reader.readuntil(b"\r\n\r\n")).split(b"\r\n")[0]
    seen.append(request.decode())
    writer.write(b"HTTP/1.1 200 fine\r\n\r\nproxy says " if b"host.test" in request else b"HTTP/1.1 403 no\r\n\r\n")
    await writer.drain()
    if b"host.test" in request:
        writer.write(await reader.read(100))
        await writer.drain()
    writer.close()


async def asked(port, request, more=b""):
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    writer.write(request)
    await writer.drain()
    answer = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 10)
    if more and b" 200 " in answer:
        writer.write(more)
        await writer.drain()
        answer += await asyncio.wait_for(reader.read(), 10)
    writer.close()
    return answer.decode()


async def main():
    host = await asyncio.start_server(echo, "127.0.0.1", 0)
    behind = await asyncio.start_server(proxy, "127.0.0.1", 0)
    host_port, proxy_port = host.sockets[0].getsockname()[1], behind.sockets[0].getsockname()[1]
    folder = tempfile.mkdtemp()
    started = []
    for name, allowed, through, door in [("direct", f"127.0.0.1:{host_port}", [], 18071), ("through", "host.test:443", ["--through", f"127.0.0.1:{proxy_port}"], 18072)]:
        socket = os.path.join(folder, name)
        started.append(await asyncio.create_subprocess_exec(GATE, "gate", socket, allowed, *through, stderr=asyncio.subprocess.PIPE))
        started.append(await asyncio.create_subprocess_exec(GATE, "door", f"127.0.0.1:{door}", socket))
    for _ in range(100):
        if all(os.path.exists(os.path.join(folder, name)) for name in ("direct", "through")):
            break
        await asyncio.sleep(0.1)
    await asyncio.sleep(0.5)

    answer = await asked(18071, f"CONNECT 127.0.0.1:{host_port} HTTP/1.1\r\n\r\n".encode(), b"hello")
    assert " 200 " in answer and answer.endswith("host says hello"), answer
    for refused in [b"CONNECT 127.0.0.1:1 HTTP/1.1\r\n\r\n", b"CONNECT elsewhere.test:443 HTTP/1.1\r\n\r\n", f"CONNECT localhost:{host_port} HTTP/1.1\r\n\r\n".encode()]:
        assert " 403 " in await asked(18071, refused), refused
    assert " 405 " in await asked(18071, f"GET http://127.0.0.1:{host_port}/ HTTP/1.1\r\n\r\n".encode())
    try:
        answer = await asked(18071, b"CONNECT " + b"x" * 20000 + b" HTTP/1.1\r\n\r\n")
    except (asyncio.IncompleteReadError, ConnectionError):
        answer = ""
    assert " 200 " not in answer, "a request too long to be one was let through"

    answer = await asked(18072, b"CONNECT HOST.test:443 HTTP/1.1\r\n\r\n", b"hello")
    assert " 200 " in answer and answer.endswith("proxy says hello"), answer
    assert seen == ["CONNECT host.test:443 HTTP/1.1"], seen
    assert " 403 " in await asked(18072, b"CONNECT other.test:443 HTTP/1.1\r\n\r\n")
    assert len(seen) == 1, "the proxy behind the gate was asked for a host the gate does not lead to"

    refused = b""
    for process in started:
        process.terminate()
        refused += (await process.communicate())[1] or b""
    assert refused.count(b"refused the way to") == 4, refused
    print("the gate led to its hosts and nowhere else")


seen = []
asyncio.run(main())
