"""Downloads numpy for one Python version / platform from PyPI and unpacks it into
<dest>/<python tag>/ (numpy, numpy.libs, dist-info; test folders are dropped).

    fetch_numpy.py <dest> <python tag> <platform>
    fetch_numpy.py autozhuyin/vendor cp38 win32
    fetch_numpy.py ~/.local/share/autozhuyin/vendor auto auto     (this Python, Linux)

The newest numpy release that has a wheel for that combination is used, and its
SHA-256 is checked against PyPI. Standard library only.
"""
import hashlib
import io
import json
import platform
import re
import shutil
import sys
import urllib.request
import zipfile
from pathlib import Path


def version_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", v))


def linux_platforms():
    machine = platform.machine().lower()
    arch = {"amd64": "x86_64", "arm64": "aarch64"}.get(machine, machine)
    return [f"manylinux_2_17_{arch}", f"manylinux2014_{arch}", f"manylinux_2_27_{arch}", f"manylinux_2_28_{arch}"]


def find_wheel(tag, platforms):
    with urllib.request.urlopen("https://pypi.org/pypi/numpy/json", timeout=60) as r:
        releases = json.load(r)["releases"]
    for version in sorted(releases, key=version_key, reverse=True):
        if re.search(r"[a-z]", version):          # skip pre-releases (rc, b, a, dev)
            continue
        for f in releases[version]:
            name = f["filename"]
            if not name.endswith(".whl") or f.get("yanked"):
                continue
            if f"-{tag}-{tag}-" not in name:        # also skips free-threaded "cp315t" builds
                continue
            plat = name[:-4].split("-")[-1]
            if any(p in plat.split(".") for p in platforms):
                return version, f
    return None, None


def main(dest, tag, plat):
    if tag == "auto":
        tag = "cp%d%d" % sys.version_info[:2]
    platforms = linux_platforms() if plat == "auto" else [plat]
    version, f = find_wheel(tag, platforms)
    if not f:
        sys.exit(f"no numpy wheel for {tag} {platforms}")
    print(f"numpy {version} for {tag}: {f['filename']} ({f['size'] / 1e6:.1f} MB)")
    with urllib.request.urlopen(f["url"], timeout=300) as r:
        data = r.read()
    if hashlib.sha256(data).hexdigest() != f["digests"]["sha256"]:
        sys.exit("checksum mismatch")
    out = Path(dest).expanduser() / tag
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        for info in z.infolist():
            parts = Path(info.filename).parts
            if "tests" in parts or parts[0].endswith(".data"):
                continue
            z.extract(info, out)
    print(f"unpacked to {out}")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(*sys.argv[1:])
