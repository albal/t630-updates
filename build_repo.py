#!/usr/bin/env python3
"""Build an iDRAC-ready firmware repository for end-of-life Dell PowerEdge models.

Dell's current catalogs no longer list 13th-generation (13G) servers, so this
script uses the last archived Lifecycle Controller catalog that does. It:

  1. downloads that catalog from downloads.dell.com,
  2. keeps the Windows x64 update packages (the ones iDRAC installs) for the
     chosen models, by default only the newest package for each device,
  3. downloads those packages and verifies their checksums, and
  4. writes a trimmed Catalog.xml with relative paths, so the output folder can
     be served by any web server and used with iDRAC's HTTP update.

Standard library only.
"""
import argparse
import concurrent.futures
import datetime
import gzip
import hashlib
import os
import re
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

# Last Lifecycle Controller catalog containing 13G servers (26.06.01, published
# 1 June 2026). From 26.06.08 onward 13G is gone. Found through
# https://downloads.dell.com/catalog/CatalogIndex.gz.
DEFAULT_CATALOG = "https://downloads.dell.com/FOLDER14611037M/1/Catalog.xml.gz"
DOWNLOAD_BASE = "https://downloads.dell.com/"
USER_AGENT = "dell-13g-repo/1.0 (+https://github.com)"


def log(msg):
    print(msg, flush=True)


def fetch(url, dest=None, retries=4):
    """Download url to dest (or return the bytes), retrying on errors."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                if dest is None:
                    return resp.read()
                tmp = dest + ".part"
                with open(tmp, "wb") as f:
                    while chunk := resp.read(1 << 20):
                        f.write(chunk)
                os.replace(tmp, dest)
                return None
        except Exception as e:  # noqa: BLE001 - retry on any network error
            if attempt == retries:
                raise
            log(f"  retry {attempt}/{retries - 1} for {url}: {e}")
            time.sleep(5 * attempt)


def load_catalog(url):
    raw = fetch(url)
    if raw[:2] == b"\x1f\x8b":
        raw = gzip.decompress(raw)
    # Dell catalogs are UTF-16 with a BOM; decode, then drop the XML declaration
    # so ElementTree doesn't object to its encoding attribute.
    text = raw.decode("utf-16") if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else raw.decode("utf-8-sig")
    text = re.sub(r"^\s*<\?xml[^>]*\?>", "", text)
    return ET.fromstring(text)


def system_ids_for(root, models):
    """Map model names like 'T630' to BIOS system IDs like '0602'."""
    wanted = {m.strip().upper().removeprefix("POWEREDGE ").strip() for m in models}
    found = {}
    for model in root.iter("Model"):
        name = (model.findtext("Display") or "").strip().upper()
        if name in wanted and model.get("systemID"):
            found.setdefault(name, set()).add(model.get("systemID"))
    missing = wanted - found.keys()
    if missing:
        sys.exit(f"Models not found in catalog: {', '.join(sorted(missing))}")
    return found


def supports(elem, ids):
    return any(m.get("systemID") in ids for m in elem.iter("Model"))


def recency(comp):
    """Sort key for "newer". Uses releaseDate, not dateTime: dateTime changes
    whenever Dell repackages an entry, so an older firmware can have a later
    dateTime (e.g. PERC H730 25.5.8 vs 25.5.9)."""
    try:
        released = datetime.datetime.strptime((comp.get("releaseDate") or "").strip(), "%B %d, %Y").date()
    except ValueError:
        released = datetime.date.min
    version = tuple(int(p) if p.isdigit() else 0 for p in re.split(r"[.\-]", comp.get("vendorVersion") or ""))
    return released, version, comp.get("dateTime") or ""


def select_components(root, ids, include_drivers, all_versions):
    candidates = []
    for c in root.findall("SoftwareComponent"):
        if not supports(c, ids):
            continue
        # iDRAC/Lifecycle Controller installs the Windows x64 update packages.
        if not c.get("path", "").upper().endswith(".EXE"):
            continue
        ctype = c.find("ComponentType")
        if ctype is not None and ctype.get("value") == "DRVR" and not include_drivers:
            continue
        candidates.append(c)
    if all_versions:
        return candidates

    # Keep, for every device, the newest package that supports it. Grouping by
    # whole package doesn't work because each version supports slightly
    # different devices.
    def device_key(d):
        pci = d.find("PCIInfo")
        return d.get("componentID") or "", tuple(sorted(pci.attrib.items())) if pci is not None else ()

    newest = {}
    no_device = []
    for c in candidates:
        devices = list(c.iter("Device"))
        if not devices:
            no_device.append(c)
            continue
        for d in devices:
            key = device_key(d)
            if key not in newest or recency(c) > recency(newest[key]):
                newest[key] = c

    # A package kept for one device may also list devices that have a newer
    # package. Remove those from its entry, or iDRAC can offer it as a
    # downgrade for them.
    keep = {id(c) for c in newest.values()} | {id(c) for c in no_device}
    for c in candidates:
        if id(c) not in keep:
            continue
        for parent in c.iter("SupportedDevices"):
            for d in list(parent):
                if d.tag == "Device" and newest.get(device_key(d)) is not c:
                    parent.remove(d)
    return [c for c in candidates if id(c) in keep]


def verify(path, comp):
    algo = (comp.get("hashAlgorithm") or "").lower().replace("-", "")
    expected = comp.get("hash") if algo in hashlib.algorithms_available and comp.get("hash") else None
    if not expected and comp.get("hashMD5"):
        algo, expected = "md5", comp.get("hashMD5")
    if not expected:
        return True
    h = hashlib.new(algo)
    with open(path, "rb") as f:
        while chunk := f.read(1 << 20):
            h.update(chunk)
    return h.hexdigest().lower() == expected.lower()


def download(comp, out_dir):
    rel = comp.get("path")
    dest = os.path.join(out_dir, rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and verify(dest, comp):
        return rel, "cached"
    fetch(DOWNLOAD_BASE + rel, dest)
    if not verify(dest, comp):
        os.remove(dest)
        raise RuntimeError(f"checksum mismatch: {rel}")
    return rel, "downloaded"


def build_catalog(root, ids, components):
    kept_files = {os.path.basename(c.get("path")) for c in components}
    manifest = ET.Element("Manifest", dict(root.attrib))
    # Paths become relative to wherever the repository is served from.
    manifest.set("baseLocation", "")
    manifest.attrib.pop("baseLocationAccessProtocols", None)

    for child in root:
        if child.tag in ("ReleaseNotes", "Prerequisites"):
            manifest.append(child)
    for c in components:
        manifest.append(c)
    # Keep the models' system bundles, listing only the packages we ship.
    for b in root.findall("SoftwareBundle"):
        if not supports(b, ids) or b.get("bundleType") != "BTW64":
            continue
        contents = b.find("Contents")
        if contents is not None:
            for pkg in list(contents):
                if os.path.basename(pkg.get("path", "")) not in kept_files:
                    contents.remove(pkg)
        b.set("size", str(sum(int(c.get("size") or 0) for c in components)))
        manifest.append(b)
    return manifest


def write_catalog(manifest, out_dir):
    ET.indent(manifest, space="  ")
    body = ET.tostring(manifest, encoding="unicode")
    xml = '<?xml version="1.0" encoding="utf-16"?>\n' + body
    # UTF-16 with BOM, matching what Dell and Repository Manager produce.
    with open(os.path.join(out_dir, "Catalog.xml"), "wb") as f:
        f.write(xml.encode("utf-16"))


def write_summary(components, models, catalog_url, out_dir):
    lines = [f"Firmware repository for PowerEdge {', '.join(models)}",
             f"Source catalog: {catalog_url}", ""]
    rows = sorted(((c.findtext("Name/Display") or "").strip(), c.get("vendorVersion") or "",
                   c.get("releaseDate") or "", c.get("path")) for c in components)
    for name, ver, date, path in rows:
        lines.append(f"{ver:20} {date:20} {name}")
        lines.append(f"{'':41} {path}")
    with open(os.path.join(out_dir, "versions.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--models", default="T630", help="comma-separated models, e.g. T630,R730 (default: T630)")
    p.add_argument("--catalog-url", default=DEFAULT_CATALOG, help="Dell catalog to build from")
    p.add_argument("--out", default="repo", help="output folder (default: ./repo)")
    p.add_argument("--all-versions", action="store_true", help="keep every version, not just the newest per device")
    p.add_argument("--include-drivers", action="store_true", help="also include OS driver packages")
    p.add_argument("--jobs", type=int, default=8, help="parallel downloads (default: 8)")
    p.add_argument("--dry-run", action="store_true", help="list what would be downloaded and exit")
    args = p.parse_args()

    models = [m.strip() for m in args.models.split(",") if m.strip()]
    log(f"Loading catalog {args.catalog_url}")
    root = load_catalog(args.catalog_url)
    log(f"Catalog version {root.get('version')} ({root.get('dateTime')})")

    by_model = system_ids_for(root, models)
    ids = set().union(*by_model.values())
    for name, sids in sorted(by_model.items()):
        log(f"  {name}: system ID {', '.join(sorted(sids))}")

    components = select_components(root, ids, args.include_drivers, args.all_versions)
    total = sum(int(c.get("size") or 0) for c in components)
    log(f"Selected {len(components)} packages, {total / 1e9:.2f} GB")
    if args.dry_run:
        for c in components:
            log(f"  {c.get('vendorVersion', ''):18} {c.get('path')}")
        return

    os.makedirs(args.out, exist_ok=True)
    failed = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(download, c, args.out): c for c in components}
        for i, fut in enumerate(concurrent.futures.as_completed(futures), 1):
            try:
                rel, status = fut.result()
                log(f"[{i}/{len(components)}] {status}: {rel}")
            except Exception as e:  # noqa: BLE001 - report all failures at the end
                failed.append(futures[fut].get("path"))
                log(f"[{i}/{len(components)}] FAILED: {futures[fut].get('path')}: {e}")
    if failed:
        sys.exit(f"{len(failed)} downloads failed")

    write_catalog(build_catalog(root, ids, components), args.out)
    write_summary(components, models, args.catalog_url, args.out)
    log(f"Done: {args.out}/Catalog.xml with {len(components)} packages")


if __name__ == "__main__":
    main()
