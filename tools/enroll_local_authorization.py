#!/usr/bin/env python3
"""One-time trusted USB enrollment, no third-party runtime dependencies.

Run after building probe_pairing_enrollment_service and enrollment_crypto.
Private material travels only over child-process pipes and an exclusive 0600
file in a 0700 directory, for immediate import into the app's protected Keychain.
This utility is never needed for a normal on-iPad launch.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import struct
import subprocess
import sys
import time
import uuid

from enrollment_srp import EnrollmentSRP


def tlv_encode(fields):
    result = bytearray()
    for kind, value in fields:
        if not value or len(value) > 16384:
            raise ValueError("Invalid TLV input")
        for offset in range(0, len(value), 255):
            chunk = value[offset:offset+255]
            result += bytes((kind, len(chunk)))+chunk
    return bytes(result)


def tlv_decode(data, state):
    fields, at, previous = {}, 0, None
    if not 0 < len(data) <= 16384:
        raise ValueError("Invalid TLV length")
    while at < len(data):
        if at+2 > len(data):
            raise ValueError("Short TLV")
        kind, size = data[at:at+2]
        at += 2
        if at+size > len(data) or (kind in fields and kind != previous):
            raise ValueError("Malformed TLV")
        fields[kind] = fields.get(kind, b"")+data[at:at+size]
        at += size
        previous = kind
    if 7 in fields:
        status = fields[7][0] if len(fields[7]) == 1 else -1
        raise ValueError("Pairing step rejected with protocol status %d" % status)
    if fields.get(6) != bytes((state,)):
        actual = fields[6][0] if len(fields.get(6, b"")) == 1 else -1
        raise ValueError("Pairing state mismatch: expected %d, received %d" % (state, actual))
    return fields


def exact(pipe, length, timeout=65):
    result = bytearray()
    deadline = time.monotonic()+timeout
    with selectors.DefaultSelector() as selector:
        selector.register(pipe, selectors.EVENT_READ)
        while len(result) < length:
            left = deadline-time.monotonic()
            if left <= 0 or not selector.select(left):
                raise TimeoutError("Enrollment response timed out")
            chunk = os.read(pipe.fileno(), length-len(result))
            if not chunk:
                raise EOFError("Enrollment channel closed")
            result += chunk
    return bytes(result)


class USBPairing:
    def __init__(self, bridge, device):
        self.child = subprocess.Popen([str(bridge), device, "--enroll-stdio"], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.sequence, self.peer_sequence = 0, -1

    def exchange(self, plain=None):
        data = b""
        if plain is not None:
            data = json.dumps({"message": {"plain": {"_0": plain}}, "originatedBy": "host",
                               "sequenceNumber": self.sequence}, separators=(",", ":")).encode()
            self.sequence += 1
        if len(data) > 16384:
            raise ValueError("Enrollment query too large")
        self.child.stdin.write(struct.pack("!I", len(data))+data)
        self.child.stdin.flush()
        length, = struct.unpack("!I", exact(self.child.stdout, 4))
        if not 0 < length <= 16384:
            raise ValueError("Enrollment response too large")
        response = json.loads(exact(self.child.stdout, length))
        number = response.get("sequenceNumber")
        if response.get("originatedBy") != "device" or type(number) is not int or number <= self.peer_sequence:
            raise ValueError("Invalid enrollment envelope")
        self.peer_sequence = number
        return response["message"]["plain"]["_0"]

    def pairing(self, data, start, state):
        response = self.exchange({"event": {"_0": {"pairingData": {"_0": {
            "data": base64.b64encode(data).decode(), "kind": "setupManualPairing",
            "sendingHost": "Tolkara", "startNewSession": start}}}}})
        event = response["event"]["_0"]
        if "awaitingUserConsent" in event:
            print("Waiting for the iPad's enrollment approval.", flush=True)
            event = self.exchange()["event"]["_0"]
        if "pairingRejectedWithError" in event:
            error = event["pairingRejectedWithError"]
            wrapped = error.get("wrappedError", {}) if isinstance(error, dict) else {}
            code = wrapped.get("code")
            print("Device rejected enrollment"+(" (code %d)" % code if type(code) is int else "")+".", file=sys.stderr)
            raise ValueError("Pairing rejected")
        text = event["pairingData"]["_0"]["data"]
        raw = base64.b64decode(text, validate=True)
        # A TLV error byte is a public protocol status, never key material.
        if len(raw) == 6 and raw[:2] == b"\x06\x01" and raw[3:5] == b"\x07\x01":
            print("Device returned pairing status %d." % raw[5], file=sys.stderr)
        return raw, tlv_decode(raw, state)

    def close(self):
        self.child.stdin.close()
        try:
            self.child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.child.terminate()
            self.child.wait(timeout=3)


def crypto_call(child, command):
    child.stdin.write(json.dumps(command).encode()+b"\n")
    child.stdin.flush()
    line = bytearray()
    while len(line) <= 65536:
        byte = exact(child.stdout, 1, timeout=10)
        if byte == b"\n":
            response = json.loads(line)
            if "error" in response:
                stage = response.get("stage")
                allowed = {"input", "message6-state", "message6-decryption", "device-proof-fields", "peer-identifier-binding", "device-signature"}
                raise ValueError("Enrollment cryptographic verification rejected: "+(stage if stage in allowed else "unknown"))
            return response
        line += byte
    raise ValueError("Crypto worker response too large")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    folder = args.output.parent
    folder.mkdir(mode=0o700, parents=True, exist_ok=True)
    if folder.is_symlink() or folder.stat().st_mode & 0o077 or args.output.exists():
        raise ValueError("Enrollment needs a private directory and a new output path")
    connection = USBPairing(root/"build/probe_pairing_enrollment_service", args.device)
    worker = subprocess.Popen([str(root/"build/enrollment_crypto")], stdin=subprocess.PIPE,
                              stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
    stage = "trusted USB handshake"
    try:
        hello = connection.exchange({"request": {"_0": {"handshake": {"_0": {
            "hostOptions": {"attemptPairVerify": False}, "wireProtocolVersion": 19}}}}})
        peer = hello["response"]["_1"]["handshake"]["_0"]["peerDeviceInfo"]["identifier"]
        if not isinstance(peer, str) or not 1 <= len(peer) <= 1024:
            raise ValueError("Missing trusted-channel peer identity")
        stage = "SRP challenge"
        _, challenge = connection.pairing(tlv_encode([(0, b"\0"), (6, b"\1")]), True, 2)
        srp = EnrollmentSRP(challenge[2], challenge[3])
        stage = "SRP server proof"
        _, proof = connection.pairing(tlv_encode([(6, b"\3"), (3, srp.public), (4, srp.proof)]), False, 4)
        key = srp.verify(proof[4])
        print("Trusted USB enrollment: SRP server proof verified.", flush=True)
        stage = "host identity construction"
        message = crypto_call(worker, {"key": base64.b64encode(key).decode(), "hostIdentifier": str(uuid.uuid4()).upper()})
        stage = "device enrollment reply"
        raw, _ = connection.pairing(base64.b64decode(message["message5"], validate=True), False, 6)
        stage = "device signature and identity binding"
        record = crypto_call(worker, {"message6": base64.b64encode(raw).decode(),
                                     "deviceIdentifier": args.device})
        data = base64.b64decode(record["enrollment"], validate=True)
        if len(data) > 16384:
            raise ValueError("Enrollment record too large")
        stage = "private record storage"
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, "wb") as file:
            file.write(data)
            file.flush()
            os.fsync(file.fileno())
        print("Enrollment verified and stored for immediate protected Keychain import.", flush=True)
        print("Public enrollment fingerprint: "+record["fingerprint"], flush=True)
    except Exception as error:
        print("Enrollment failed at "+stage+" ("+type(error).__name__+"); no identity accepted or exported.", file=sys.stderr)
        # Exact ValueError messages above are our own fixed classifications;
        # never print exception payloads from decoded peer objects or workers.
        if type(error) is ValueError:
            print(str(error), file=sys.stderr)
        return 1
    finally:
        connection.close()
        worker.stdin.close()
        try:
            worker.wait(timeout=3)
        except subprocess.TimeoutExpired:
            worker.terminate()
            worker.wait(timeout=3)
    return 0


if __name__ == "__main__":
    sys.exit(main())
