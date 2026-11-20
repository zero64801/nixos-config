"""A decoder of a made up protocol with crypto of its own, for the test of keys own: the client sends datagrams of a 16 byte
IV and JSON under AES-CBC with PKCS#7 padding, and the server answers each with a 12 byte nonce and JSON under
ChaCha20-Poly1305. Asked for tests it sets one for each way, asked to judge it keeps the keys that open every message of
their way, and otherwise it prints the messages with the keys keys own found."""
import base64
import json
import sys

from cryptography.exceptions import InvalidTag
from cryptography.hazmat.primitives import padding
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305

given = json.load(sys.stdin)
sent = [base64.b64decode(c["data"]) for c in given["chunks"] if c["sent"]]
got = [base64.b64decode(c["data"]) for c in given["chunks"] if not c["sent"]]


def opened(cipher, key, message):
    """What a message says under a key, or None."""
    try:
        if cipher.startswith("aes-"):
            decrypting = Cipher(algorithms.AES(key), modes.CBC(message[:16])).decryptor()
            unpadding = padding.PKCS7(128).unpadder()
            plain = unpadding.update(decrypting.update(message[16:]) + decrypting.finalize()) + unpadding.finalize()
        else:
            plain = ChaCha20Poly1305(key).decrypt(message[:12], message[12:], None)
        return json.loads(plain)
    except (ValueError, InvalidTag):
        return None


if given.get("ask") == "tests":
    tests = []
    if sent:
        tests.append({"cipher": "aes-cbc", "iv": sent[0][:16].hex(), "data": sent[0][16:].hex(), "padded": True, "known": {"bytes": b'{"'.hex()}})
    if got:
        tests.append({"cipher": "chacha20-poly1305", "iv": got[0][:12].hex(), "data": got[0][12:].hex()})
    print(json.dumps({"tests": tests}))
elif given.get("ask") == "judge":
    accepted = []
    for candidate in given["candidates"]:
        messages = sent if candidate["cipher"].startswith("aes-") else got
        if all(opened(candidate["cipher"], bytes.fromhex(candidate["key"]), m) is not None for m in messages):
            accepted.append(candidate["index"])
    print(json.dumps({"accepted": accepted}))
else:
    keys = {key["cipher"].startswith("aes-"): (key["cipher"], bytes.fromhex(key["key"])) for key in given["keys"]}
    for chunk in given["chunks"]:
        cipher, key = keys.get(chunk["sent"], ("", b""))
        said = opened(cipher, key, base64.b64decode(chunk["data"])) if key else None
        print("->" if chunk["sent"] else "<-", json.dumps(said) if said is not None else "(no key opens it)")
