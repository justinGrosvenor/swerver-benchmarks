#!/usr/bin/env python3
"""Test large request body uploads against the server.

Tests Content-Length bodies of various sizes, echo roundtrip integrity,
and edge cases around the 64KB buffer boundary.
"""

import sys
import os
import hashlib
import requests

BASE_URL = os.environ.get("TARGET_URL", "http://localhost:8080")
TIMEOUT = 10


def make_body(size: int) -> bytes:
    """Generate deterministic test body of given size."""
    # Repeating pattern so we can verify integrity
    pattern = b"ABCDEFGHIJKLMNOP"  # 16 bytes
    repeats = size // len(pattern) + 1
    return (pattern * repeats)[:size]


def test_post(label: str, size: int, *, echo_check: bool = False) -> bool:
    body = make_body(size)
    try:
        resp = requests.post(
            f"{BASE_URL}/echo",
            data=body,
            headers={"Content-Type": "application/octet-stream"},
            timeout=TIMEOUT,
        )
    except requests.exceptions.RequestException as e:
        print(f"  FAIL {label} ({size:>8,} bytes): {e}")
        return False

    ok = resp.status_code == 200
    detail = f"HTTP {resp.status_code}"

    if echo_check and ok:
        if resp.content == body:
            detail += ", echo MATCH"
        else:
            detail += f", echo MISMATCH (got {len(resp.content)} bytes, expected {size})"
            ok = False

    status = "  OK  " if ok else "  FAIL"
    print(f"{status} {label} ({size:>8,} bytes): {detail}")
    return ok


def test_get(label: str, path: str, expected_status: int = 200) -> bool:
    try:
        resp = requests.get(f"{BASE_URL}{path}", timeout=TIMEOUT)
    except requests.exceptions.RequestException as e:
        print(f"  FAIL {label}: {e}")
        return False

    ok = resp.status_code == expected_status
    status = "  OK  " if ok else "  FAIL"
    print(f"{status} {label}: HTTP {resp.status_code}")
    return ok


def main():
    print(f"Testing body uploads against {BASE_URL}\n")
    results = []

    # Health check
    results.append(test_get("Health check", "/health"))
    print()

    # Small bodies (fit in single buffer)
    print("--- Small bodies (< 64KB, single buffer) ---")
    for size in [0, 16, 1024, 8192, 32768, 60000]:
        results.append(test_post(f"{size}B POST", size))
    print()

    # Boundary bodies (around 64KB buffer edge)
    print("--- Buffer boundary (64KB = 65536) ---")
    for size in [64000, 65000, 65536, 66000, 70000, 71680]:
        results.append(test_post(f"{size}B POST", size))
    print()

    # Large bodies (multi-buffer accumulation)
    # Note: echo responses >2MB hit the 32-slot write queue limit (32 × 64KB = 2MB).
    # The server accepts the upload but can't fully echo back bodies >2MB.
    print("--- Large bodies (multi-buffer) ---")
    for size in [128 * 1024, 256 * 1024, 512 * 1024, 1024 * 1024, 1536 * 1024]:
        label = f"{size // 1024}KB POST"
        results.append(test_post(label, size))
    print()

    # Echo roundtrip integrity checks
    print("--- Echo roundtrip integrity ---")
    for size in [1024, 50000, 70000, 100000, 256 * 1024, 1024 * 1024]:
        label = f"{size // 1024}KB echo"
        results.append(test_post(label, size, echo_check=True))
    print()

    # Verify GET still works after all the POST tests
    print("--- GET endpoints still working ---")
    results.append(test_get("GET /health", "/health"))
    results.append(test_get("GET /echo", "/echo"))
    print()

    passed = sum(results)
    total = len(results)
    print(f"Results: {passed}/{total} passed")
    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
