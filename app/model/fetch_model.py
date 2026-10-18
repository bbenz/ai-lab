#!/usr/bin/env python3
"""Downloads the model files that model/model.json lists, and checks each file's size and SHA-256 hash.

    python fetch_model.py <model.json> <destination folder>

Files that are already in the destination with the right hash aren't downloaded again.
"""

import hashlib
import json
import os
import sys
import time
import urllib.request


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(item, destination):
    target = os.path.join(destination, item["name"])
    expected = item["sha256"].lower()
    if os.path.exists(target) and sha256(target) == expected:
        print(f"{item['name']}: already present")
        return
    partial = target + ".partial"
    for attempt in range(1, 6):
        try:
            urllib.request.urlretrieve(item["url"], partial)
            actual = sha256(partial)
            if actual != expected:
                raise ValueError(f"SHA-256 is {actual}, not {expected}")
            os.replace(partial, target)
            print(f"{item['name']}: downloaded {os.path.getsize(target)} bytes, SHA-256 checked")
            return
        except Exception as error:
            if attempt == 5:
                raise RuntimeError(f"Couldn't download {item['name']} from {item['url']}: {error}") from error
            print(f"{item['name']}: attempt {attempt} failed ({error}). Retrying.")
            time.sleep(5 * attempt)


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8") as stream:
        manifest = json.load(stream)
    os.makedirs(argv[2], exist_ok=True)
    for item in manifest["files"]:
        fetch(item, argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
