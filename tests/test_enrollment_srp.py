import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/"tools"))
from enrollment_srp import EnrollmentSRP, N
from enroll_local_authorization import tlv_decode, tlv_encode

fixture = json.loads(Path(__file__).with_name("enrollment_srp_fixture.json").read_text())
values = {k: bytes.fromhex(v) for k, v in fixture.items() if k != "source"}
srp = EnrollmentSRP(values["salt"], values["peer_public"], private=values["private"])
for field in ("public", "key", "proof"):
    assert getattr(srp, field) == values[field], field
assert srp.verify(values["peer_proof"]) == values["key"]
for proof in (values["peer_proof"], b"\0"*64, b""):
    try:
        srp.verify(proof)
        raise AssertionError("Repeated/bad proof accepted")
    except ValueError:
        pass
for public in (b"", b"\0"*384, N.to_bytes(384,"big"), b"\xff"*385):
    try:
        EnrollmentSRP(values["salt"],public)
        raise AssertionError("Invalid peer value accepted")
    except ValueError:
        pass
data = bytes(range(256))*3
assert tlv_decode(tlv_encode([(6,b"\2"),(3,data)]),2)[3] == data
for malformed in (b"\6\1\2\3", b"\6\1\2\7\1\2", b"\6\1\2\3\1x\4\1y\3\1z"):
    try:
        tlv_decode(malformed,2)
        raise AssertionError("Malformed TLV accepted")
    except ValueError:
        pass
print("Enrollment SRP: independent reference vector, server proof, invalid peer and TLV fragmentation checks passed.")
