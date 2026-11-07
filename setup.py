#!/usr/bin/env python3
"""First-start setup for Battle Fly Arena.

Downloads the MaleCNS v1.0 connectome tables (~1.2 GB total) into
connectome_data/malecns_v1/ if missing, then builds the cached CSR matrix
(malecns_csr_base.npz) and populations_mapped.json.

Safe to re-run: existing files are skipped (hash/size verified), and the
CSR build is skipped if the cache already exists.

Usage:
    python setup.py            # download data + build caches
    python setup.py --check    # verify downloads only, no build
"""
import argparse
import hashlib
import os
import sys
import urllib.request

PROJECT_ROOT = os.path.dirname(os.path.abspath(__file__))
MALECNS_DIR = os.path.join(PROJECT_ROOT, "connectome_data", "malecns_v1")

BASE = "https://storage.googleapis.com/flyem-male-cns/v1.0/connectome-data/flat-connectome"

# local name -> (remote name, expected size in bytes, sha256)
# Sizes/hashes verified against the public bucket listing (MaleCNS v1.0).
FILES = {
    "annotations.feather": (
        "body-annotations-male-cns-v1.0-minconf-0.5.feather",
        14483314,
        "2177e246113e4cfbf1e7772ec37c6da1955ff22e8063d0b1f833101f99a9a3b2",
    ),
    "neurotransmitters.feather": (
        "body-neurotransmitters-male-cns-v1.0.feather",
        43282834,
        None,
    ),
    "edges.feather": (
        "connectome-weights-male-cns-v1.0-minconf-0.5.feather",
        1051241946,
        None,
    ),
}

CHUNK = 4 * 1024 * 1024


def sha256_of(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def download(name, remote, expected_size, expected_hash):
    url = f"{BASE}/{remote}"
    dest = os.path.join(MALECNS_DIR, name)
    part = dest + ".part"

    if os.path.exists(dest):
        size = os.path.getsize(dest)
        if expected_size and size != expected_size:
            print(f"[setup] {name}: size mismatch ({size} != {expected_size}), re-downloading")
        elif expected_hash and sha256_of(dest) != expected_hash:
            print(f"[setup] {name}: hash mismatch, re-downloading")
        else:
            print(f"[setup] {name}: OK ({size/1e6:.1f} MB, verified)")
            return True

    print(f"[setup] Downloading {remote} -> {name}")
    print(f"[setup]   {url}")
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "flybrain-setup/1.0"})
        with urllib.request.urlopen(req, timeout=120) as r, open(part, "wb") as f:
            total = 0
            while True:
                chunk = r.read(CHUNK)
                if not chunk:
                    break
                f.write(chunk)
                total += len(chunk)
                mb = total / 1e6
                if expected_size:
                    pct = min(100.0, 100.0 * total / expected_size)
                    print(f"\r[setup]   {mb:,.0f} / {expected_size/1e6:,.0f} MB ({pct:.0f}%)", end="", flush=True)
                else:
                    print(f"\r[setup]   {mb:,.0f} MB", end="", flush=True)
        print()  # newline after progress
        os.replace(part, dest)
    except Exception as e:
        print(f"\n[setup] ERROR downloading {name}: {e}")
        if os.path.exists(part):
            os.remove(part)
        return False

    size = os.path.getsize(dest)
    if expected_size and size != expected_size:
        print(f"[setup] {name}: downloaded size mismatch ({size} != {expected_size})")
        return False
    if expected_hash:
        print(f"[setup] {name}: verifying sha256...")
        if sha256_of(dest) != expected_hash:
            print(f"[setup] {name}: HASH MISMATCH")
            return False
    print(f"[setup] {name}: OK ({size/1e6:.1f} MB)")
    return True


def main():
    ap = argparse.ArgumentParser(description="Battle Fly Arena first-start setup")
    ap.add_argument("--check", action="store_true",
                    help="only verify/download data, skip CSR build")
    args = ap.parse_args()

    os.makedirs(MALECNS_DIR, exist_ok=True)

    print("=" * 65)
    print("  Battle Fly Arena - first-start setup")
    print("  MaleCNS v1.0 connectome (Berg et al., Cell 2026, CC-BY)")
    print("=" * 65)

    ok = True
    for name, (remote, size, digest) in FILES.items():
        if not download(name, remote, size, digest):
            ok = False
    if not ok:
        print("\n[setup] FAILED: some downloads did not complete. Re-run setup.py.")
        sys.exit(1)

    print("\n[setup] All connectome tables present.")
    if args.check:
        print("[setup] --check given, skipping CSR build.")
        return

    # Build caches via the loader (same code path the server uses).
    sys.path.insert(0, os.path.join(PROJECT_ROOT, "brain_engine"))
    print("\n[setup] Building CSR cache + populations (first run only, a few minutes)...")
    from connectome_loader import load_or_build_csr, load_or_extract_populations
    load_or_extract_populations()
    load_or_build_csr()
    print("\n[setup] Done. Run launch_battle.py (or launch_battle.bat) to play.")


if __name__ == "__main__":
    main()
