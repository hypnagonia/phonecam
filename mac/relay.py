#!/usr/bin/env python3
"""Forward http://localhost:4747 to PhoneCam on the iPhone.

Browsers on macOS 15 need "Local Network" permission to reach the phone directly;
localhost needs none. The phone is found over the USB link first, then Wi-Fi.
Usage: python3 relay.py [phone-ip]   (or set PHONECAM_HOST, e.g. My-iPhone.local)
"""
import asyncio
import os
import socket
import subprocess
import sys

LISTEN = ("127.0.0.1", 4747)
PHONE_PORT = 4747
FIXED = sys.argv[1] if len(sys.argv) > 1 else None


def candidates():
    if FIXED:
        return [FIXED]
    ips = []
    # USB link: the iPhone's link-local address in the ARP table (169.254.x.x).
    try:
        arp = subprocess.run(["arp", "-a"], capture_output=True, text=True, timeout=3).stdout
        for line in arp.splitlines():
            if "iphone" in line.lower() and "(" in line:
                ip = line.split("(")[1].split(")")[0]
                ips.append(ip)
    except Exception:
        pass
    ips.sort(key=lambda ip: not ip.startswith("169.254."))  # USB first
    host = os.environ.get("PHONECAM_HOST")
    if host:
        try:
            ips.append(socket.gethostbyname(host))
        except Exception:
            pass
    return list(dict.fromkeys(ips))


async def open_phone():
    for ip in candidates():
        try:
            return await asyncio.wait_for(asyncio.open_connection(ip, PHONE_PORT), 2)
        except Exception:
            continue
    return None


async def pipe(r, w):
    try:
        while data := await r.read(262144):
            w.write(data)
            await w.drain()
    except Exception:
        pass
    finally:
        try:
            w.close()
        except Exception:
            pass


async def handle(cr, cw):
    phone = await open_phone()
    if not phone:
        body = b"PhoneCam not reachable: is the app open on the iPhone?"
        cw.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(body), body))
        await cw.drain()
        cw.close()
        return
    pr, pw = phone
    for w in (cw, pw):  # no Nagle delay on either leg
        sock = w.get_extra_info("socket")
        if sock is not None:
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    await asyncio.gather(pipe(cr, pw), pipe(pr, cw))


async def main():
    server = await asyncio.start_server(handle, *LISTEN)
    print(f"PhoneCam relay: http://localhost:{LISTEN[1]}  (OBS: http://localhost:{LISTEN[1]}/obs)", flush=True)
    async with server:
        await server.serve_forever()


asyncio.run(main())
