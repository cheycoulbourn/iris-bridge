#!/usr/bin/env python3
"""The app's side of the v3 stream, for scripts/smoke.sh. Python 3 standard library only.

Usage: v3_smoke_client.py --port P --fingerprint SHA256 --token DEVICE_TOKEN COMMAND [options]

  hello                         prints {"capabilities": [...], "health": {...}}
  push-snapshot FILE            sends snapshot.push with FILE's {"profileId", "revision", "snapshot"}
  turn --thread ID --provider claude|codex [--model M] --text TEXT
       [--cancel-after-first-delta] [--timeout SECONDS]
                                opens the thread, sends one message, answers every approval.request with deny
                                and every action.request with refused, and prints what happened as JSON:
                                {"end", "cause", "message", "text", "tools": [{"name", "ok"}], "approvals": [{"kind", "summary"}],
                                 "toolsOk", "toolsFailed", "approvalKinds"}

It connects to wss://127.0.0.1:PORT/v3/stream and trusts exactly the certificate whose SHA-256 is FINGERPRINT,
as the app does. Nothing here is shipped; it exists so a release can be checked against real CLIs.
"""
import argparse, base64, hashlib, json, os, socket, ssl, struct, sys, time, uuid


class Stream:
    def __init__(self, port, fingerprint):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        raw = socket.create_connection(("127.0.0.1", port), timeout=10)
        self.sock = context.wrap_socket(raw, server_hostname="127.0.0.1")
        if hashlib.sha256(self.sock.getpeercert(binary_form=True)).hexdigest() != fingerprint.lower():
            raise SystemExit("the helper's certificate is not the one on disk")
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(("GET /v3/stream HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % key).encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(1)
            if not chunk:
                raise SystemExit("the helper closed the connection during the upgrade")
            head += chunk
        if not head.startswith(b"HTTP/1.1 101"):
            raise SystemExit("upgrade refused: " + head.split(b"\r\n")[0].decode())
        self.buffer = b""

    def send(self, message):
        payload = json.dumps(message).encode()
        mask = os.urandom(4)
        header = bytes([0x81])
        if len(payload) < 126:
            header += bytes([0x80 | len(payload)])
        elif len(payload) < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", len(payload))
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", len(payload))
        self.sock.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def _read(self, count, deadline):
        while len(self.buffer) < count:
            self.sock.settimeout(max(0.1, deadline - time.time()))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise EOFError("closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:count], self.buffer[count:]
        return data

    def receive(self, timeout):
        """The next text message as JSON, None on timeout; answers pings; raises EOFError when closed."""
        deadline = time.time() + timeout
        try:
            while True:
                first, second = self._read(2, deadline)
                length = second & 0x7F
                if length == 126:
                    length = struct.unpack(">H", self._read(2, deadline))[0]
                elif length == 127:
                    length = struct.unpack(">Q", self._read(8, deadline))[0]
                payload = self._read(length, deadline)
                opcode = first & 0x0F
                if opcode == 0x9:
                    self.sock.sendall(bytes([0x8A, 0x80]) + os.urandom(4))
                elif opcode == 0x8:
                    raise EOFError("closed %s" % (struct.unpack(">H", payload[:2])[0] if len(payload) >= 2 else ""))
                elif opcode == 0x1:
                    return json.loads(payload.decode())
        except (socket.timeout, TimeoutError):
            return None


def connect(args, cursors=None):
    stream = Stream(args.port, args.fingerprint)
    stream.send({"type": "hello", "deviceToken": args.token, "appVersion": "smoke", "protocol": 3, "cursors": cursors or {}})
    hello = stream.receive(10)
    if not hello or hello.get("type") != "hello.ok":
        raise SystemExit("no hello.ok: %r" % (hello,))
    return stream, hello


def run_turn(args):
    stream, _ = connect(args)
    stream.send({"type": "thread.open", "threadId": args.thread, "provider": args.provider, "model": args.model})
    turn = "turn-" + uuid.uuid4().hex[:12]
    message = {"type": "thread.send", "threadId": args.thread, "turnId": turn, "provider": args.provider, "text": args.text}
    if args.model:
        message["model"] = args.model
    stream.send(message)
    out = {"end": None, "text": "", "tools": [], "approvals": []}
    cancelled = False
    deadline = time.time() + args.timeout
    while time.time() < deadline:
        event = stream.receive(deadline - time.time())
        if event is None:
            break
        kind = event.get("type")
        if kind == "approval.request":
            out["approvals"].append({"kind": event.get("kind"), "summary": event.get("summary")})
            stream.send({"type": "approval.answer", "approvalId": event["approvalId"], "decision": "deny"})
        elif kind == "action.request":
            stream.send({"type": "action.result", "actionId": event["actionId"], "result": {"status": "refused", "message": "The smoke test changes nothing."}})
        if event.get("turnId") != turn:
            continue
        if kind == "text.delta":
            out["text"] += event.get("text", "")
            if args.cancel_after_first_delta and not cancelled:
                stream.send({"type": "turn.cancel", "threadId": args.thread, "turnId": turn})
                cancelled = True
        elif kind == "tool.finished":
            out["tools"].append({"name": event.get("name"), "ok": event.get("ok")})
        elif kind in ("turn.completed", "turn.failed"):
            out["end"] = kind
            out["cause"] = event.get("cause")
            out["message"] = event.get("message")
            break
    # Flat lists as well, for the shell's one-field reader.
    out["toolsOk"] = [tool["name"] for tool in out["tools"] if tool["ok"]]
    out["toolsFailed"] = [tool["name"] for tool in out["tools"] if not tool["ok"]]
    out["approvalKinds"] = [approval["kind"] for approval in out["approvals"]]
    print(json.dumps(out))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--fingerprint", required=True)
    parser.add_argument("--token", required=True)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("hello")
    push = commands.add_parser("push-snapshot")
    push.add_argument("file")
    turn = commands.add_parser("turn")
    turn.add_argument("--thread", required=True)
    turn.add_argument("--provider", required=True)
    turn.add_argument("--model")
    turn.add_argument("--text", required=True)
    turn.add_argument("--cancel-after-first-delta", action="store_true")
    turn.add_argument("--timeout", type=float, default=240)
    args = parser.parse_args()
    if args.command == "hello":
        _, hello = connect(args)
        print(json.dumps({"capabilities": hello.get("capabilities"), "health": hello.get("health")}))
    elif args.command == "push-snapshot":
        stream, _ = connect(args)
        with open(args.file, encoding="utf-8") as handle:
            body = json.load(handle)
        stream.send({"type": "snapshot.push", "profileId": body["profileId"], "revision": body["revision"], "snapshot": body["snapshot"]})
        time.sleep(0.5)
        print(json.dumps({"sent": True}))
    else:
        run_turn(args)


if __name__ == "__main__":
    main()
