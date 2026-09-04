#!/usr/bin/env python3
# Builds the signed update manifest for a GitHub Release.
#
# Used by .github/workflows/release.yml after the installers are uploaded:
#   python3 tools/build-update-manifest.py \
#       --tag v0.3.0 --repo spix3l/crazycut \
#       --dmg dist/CrazyCut-macOS/CrazyCut.dmg \
#       --zip dist/CrazyCut-Windows/CrazyCut-Windows.zip \
#       --out dist/manifest
#
# Inputs from the environment:
#   GH_TOKEN          GitHub token for reading the release metadata.
#   UPDATE_SIGNING_SK base64 Ed25519 seed. When absent, only CHECKSUMS.txt is
#                     written and the manifest is skipped (the in-app updater
#                     then reports "no signed manifest yet" and stays put).
#
# Outputs in --out:
#   latest.json       validated manifest (tag, version, urls, sha256, sizes).
#   latest.json.sig   base64 detached Ed25519 signature over latest.json bytes.
#   CHECKSUMS.txt     human readable sha256 list for manual verification.
#
# Exit codes: 0 ok (manifest or manifest-skipped), 2 programming error
# (bad tag, version mismatch, missing artifacts). Missing signing key is
# NOT an error: releases must keep working before the key ceremony runs.

import argparse
import base64
import hashlib
import json
import os
import re
import sys
import urllib.request

TAG_PATTERN = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
MAX_NOTES = 2000


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def api_get(url, token):
    request = urllib.request.Request(url)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("User-Agent", "CrazyCut-Release")
    if token:
        request.add_header("Authorization", "Bearer %s" % token)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--dmg", required=True)
    parser.add_argument("--zip", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    match = TAG_PATTERN.match(args.tag)
    if not match:
        sys.exit("error: tag must match vX.Y.Z, got %s" % args.tag)
    version = "%s.%s.%s" % match.groups()

    for path in (args.dmg, args.zip):
        if not os.path.isfile(path):
            sys.exit("error: artifact not found: %s" % path)

    token = os.environ.get("GH_TOKEN", "")
    try:
        meta = api_get(
            "https://api.github.com/repos/%s/releases/tags/%s"
            % (args.repo, args.tag),
            token,
        )
    except Exception as e:
        sys.exit("error: could not read release metadata: %s" % e)

    urls = {}
    for asset in meta.get("assets", []):
        name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        if name in ("CrazyCut.dmg", "CrazyCut-Windows.zip"):
            urls[name] = url
    if "CrazyCut.dmg" not in urls or "CrazyCut-Windows.zip" not in urls:
        sys.exit("error: installer assets are missing from the release")

    body = meta.get("body") or ""
    notes = body[:MAX_NOTES]
    manifest = {
        "tag": args.tag,
        "version": version,
        "published_at": meta.get("published_at", ""),
        "notes": notes,
        "release_page_url": meta.get("html_url", ""),
        "assets": {
            "macos": {
                "file": "CrazyCut.dmg",
                "url": urls["CrazyCut.dmg"],
                "sha256": sha256_of(args.dmg),
                "size": os.path.getsize(args.dmg),
            },
            "windows": {
                "file": "CrazyCut-Windows.zip",
                "url": urls["CrazyCut-Windows.zip"],
                "sha256": sha256_of(args.zip),
                "size": os.path.getsize(args.zip),
            },
        },
    }
    if not manifest["published_at"] or not manifest["release_page_url"]:
        sys.exit("error: release metadata is incomplete")

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "CHECKSUMS.txt"), "w") as f:
        f.write(
            "%s  CrazyCut.dmg\n%s  CrazyCut-Windows.zip\n"
            % (manifest["assets"]["macos"]["sha256"],
               manifest["assets"]["windows"]["sha256"])
        )

    seed_b64 = os.environ.get("UPDATE_SIGNING_SK", "").strip()
    if not seed_b64:
        print(
            "warning: UPDATE_SIGNING_SK is not set, skipping signed manifest "
            "(run tools/gen-update-keys.py and add the secret)")
        return 0
    try:
        from nacl.signing import SigningKey
    except ImportError:
        sys.exit("error: PyNaCl is required: pip install pynacl")
    try:
        signing = SigningKey(base64.b64decode(seed_b64))
    except Exception as e:
        sys.exit("error: UPDATE_SIGNING_SK is not a valid base64 seed: %s"
                 % e)

    manifest_path = os.path.join(args.out, "latest.json")
    with open(manifest_path, "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    with open(manifest_path, "rb") as f:
        signature = signing.sign(f.read()).signature
    with open(os.path.join(args.out, "latest.json.sig"), "w") as f:
        f.write(base64.b64encode(signature).decode() + "\n")
    print("wrote signed manifest for %s (%s)" % (args.tag, version))
    return 0


if __name__ == "__main__":
    sys.exit(main())
