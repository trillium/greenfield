#!/usr/bin/env python3
"""A second, independent TPT1 sender for the daemon's pointer receiver (standard library only).

  assist_tpt1_probe.py --selftest [--kit DIR]   no network, no pointer: checks this encoder against the kit's recorded datagrams
                                                 (Tests/Fixtures/assist/tpt1/vectors.json) and the tag's known answer
  assist_tpt1_probe.py --live --http HOST:PORT   opens a pointer session over HTTP and sends a short, harmless motion

--live MOVES THE REAL CURSOR of the Mac it points at. It is only run by scripts/assist-live-pointer-test.sh, which is disabled until the
captain approves a safe test plan (scratch Mac or macOS VM). Nothing else calls it, and `make test` runs --selftest only.
"""
import argparse
import base64
import hashlib
import hmac
import json
import os
import socket
import struct
import sys
import time
import urllib.request

TAG_BYTES = 16
BUTTON = {"left": 1, "right": 2, "middle": 4}
DIRECTION = {"up": 0, "down": 1, "left": 2, "right": 3}


def tag(key, body):
    return hmac.new(key, body, hashlib.sha256).digest()[:TAG_BYTES]


def event(e):
    kind = e["kind"]
    if kind == "click":
        code, a, b = 1, BUTTON[e["button"]], e["count"]
    elif kind == "swipe":
        code, a, b = 2, e["fingers"], DIRECTION[e["direction"]]
    elif kind == "zoom":
        code, a, b = 3, e["steps"], 0
    elif kind == "scrollBegin":
        code, a, b = 6, 0, 0
    elif kind == "scrollEnd":
        code, a, b = 7, e["vx"], e["vy"]
    elif kind == "scrollCancel":
        code, a, b = 9, 0, 0
    elif kind == "releaseAll":
        code, a, b = 8, 0, 0
    else:
        raise ValueError("unknown event kind " + kind)
    return struct.pack(">HBBhh", e["id"], code, 1 if e.get("applyBefore") else 0, a, b)


def encode(packet, key=None):
    """One datagram from the kit's JSON form of a packet; with a key, the tag is appended."""
    kind = packet["type"]
    types = {"hello": 1, "helloAck": 2, "frame": 3, "ack": 4, "bye": 5}
    flags = 1 if kind == "frame" and packet["frame"].get("ackRequested") else 0
    out = b"TPT1" + struct.pack(">BBIII", types[kind], flags, packet["session"], packet["seq"], packet["timestamp"])
    if kind == "hello":
        out += struct.pack(">I", packet["nonce"])
    elif kind == "helloAck":
        out += struct.pack(">IH", packet["nonce"], packet["capabilities"])
    elif kind == "frame":
        f = packet["frame"]
        out += struct.pack(">iiiiBBB", f["moveX"], f["moveY"], f["scrollX"], f["scrollY"], f["buttons"], f["fingers"], len(f["events"]))
        out += b"".join(event(e) for e in f["events"])
    elif kind == "ack":
        out += struct.pack(">IH", packet["ack"]["seq"], packet["ack"]["eventId"])
    return out + tag(key, out) if key is not None else out


def selftest(kit):
    vectors = os.path.join(kit, "Tests", "Fixtures", "assist", "tpt1", "vectors.json")
    with open(vectors, encoding="utf-8") as handle:
        data = json.load(handle)
    for v in data["vectors"]:
        got = encode(v["packet"]).hex().upper()
        assert got == v["hex"], "%s: %s != %s" % (v["name"], got, v["hex"])
    key = bytes(range(32))
    known = encode({"type": "bye", "session": 0x01020304, "seq": 1, "timestamp": 0}, key)
    assert known[-TAG_BYTES:].hex() == "97b9dada3fe4445daeb8aee2ce65ff2d", known[-TAG_BYTES:].hex()
    print("assist_tpt1_probe selftest: %d kit datagrams re-encoded byte for byte, tag known answer ok" % len(data["vectors"]))


def live(http):
    host, _, port = http.partition(":")
    request = urllib.request.Request("http://%s:%s/assist/pointer/session" % (host, port), data=b"{}", method="POST")
    with urllib.request.urlopen(request, timeout=5) as response:
        offer = json.load(response)
    key = base64.b64decode(offer["key"])
    target = (offer["udp"]["address"], offer["udp"]["port"])
    session = offer["session"]
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(1.0)
    seq = [0]

    def send(body):
        seq[0] += 1
        packet = dict(body, session=session, seq=seq[0], timestamp=int(time.monotonic() * 1000) & 0xFFFFFFFF)
        sock.sendto(encode(packet, key), target)

    send({"type": "hello", "nonce": 7})
    reply = sock.recv(2048)
    assert reply[:4] == b"TPT1" and reply[4] == 2, "no helloAck"
    # a small square of motion in 1/16 point counters: 40 pt right, 40 pt down, 40 left, 40 up; no clicks, no scroll
    x = y = 0
    for dx, dy in [(40, 0), (0, 40), (-40, 0), (0, -40)]:
        for _ in range(8):
            x += dx * 16 // 8
            y += dy * 16 // 8
            send({"type": "frame", "frame": {"moveX": x, "moveY": y, "scrollX": 0, "scrollY": 0, "buttons": 0, "fingers": 1, "events": []}})
            time.sleep(0.016)
    send({"type": "bye"})
    print("sent a 40 point square of motion on session", session)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--selftest", action="store_true")
    parser.add_argument("--live", action="store_true")
    parser.add_argument("--http")
    parser.add_argument("--kit", default=os.environ.get("PARROT_KIT_DIR", ""))
    args = parser.parse_args()
    if args.selftest:
        selftest(args.kit)
    elif args.live and args.http:
        live(args.http)
    else:
        parser.error("choose --selftest, or --live --http HOST:PORT")


if __name__ == "__main__":
    sys.exit(main())
