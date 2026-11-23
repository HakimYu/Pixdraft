"""Generate and sign Pixdraft's GitHub Release update manifest."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tag", help="GitHub Release tag, e.g. v1.1.0")
    parser.add_argument("notes", type=Path, help="UTF-8 release notes")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--signing-dir", type=Path, default=Path(__file__).resolve().parents[2] / "pixdraft-signing")
    extensions = {
        "android": (".apk",),
        "macos": (".dmg", ".pkg", ".zip"),
        "windows": (".exe", ".msi", ".zip"),
        "linux": (".deb", ".rpm", ".tar.gz", ".appimage"),
    }
    for platform in extensions:
        parser.add_argument(f"--{platform}", type=Path, action="append", default=[])
    args = parser.parse_args()
    if not re.fullmatch(r"v?(?:0|[1-9][0-9]{0,8})(?:\.(?:0|[1-9][0-9]{0,8})){2}", args.tag):
        parser.error("Use a stable Release tag such as v1.1.0.")
    assets = []
    names = set()
    for platform, suffixes in extensions.items():
        for path in getattr(args, platform):
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", path.name) or not path.name.lower().endswith(suffixes):
                parser.error(f"Invalid asset name for {platform}: {path.name}")
            if path.name in names or not path.is_file() or path.stat().st_size == 0:
                parser.error(f"Duplicate, empty or missing asset: {path}")
            with path.open("rb") as source:
                sha256 = hashlib.file_digest(source, "sha256").hexdigest()
                size = path.stat().st_size
            names.add(path.name)
            assets.append({"name": path.name, "platform": platform, "size": size, "sha256": sha256})
    if not assets:
        parser.error("Specify at least one platform asset.")
    manifest = json.dumps({
        "repository": "HakimYu/Pixdraft",
        "tag": args.tag,
        "notes": args.notes.read_text(encoding="utf-8"),
        "assets": assets,
    }, ensure_ascii=False, indent=2).encode("utf-8")
    if len(manifest) > 1024 * 1024:
        parser.error("Update manifest exceeds 1 MiB.")
    args.out.mkdir(parents=True, exist_ok=True)
    manifest_path = args.out / "pixdraft-update.json"
    signature_path = args.out / "pixdraft-update.json.sig"
    if manifest_path.exists() or signature_path.exists():
        parser.error("Choose an output directory without a previous update manifest.")
    with manifest_path.open("xb") as output:
        output.write(manifest)
    try:
        subprocess.run([
            "openssl", "pkeyutl", "-sign", "-rawin",
            "-inkey", args.signing_dir / "update-release.pem",
            "-passin", f"file:{args.signing_dir / 'update-release.pass'}",
            "-in", manifest_path, "-out", signature_path,
        ], check=True)
    except (OSError, subprocess.CalledProcessError):
        manifest_path.unlink()
        signature_path.unlink(missing_ok=True)
        raise
    print(manifest_path)
    print(signature_path)


if __name__ == "__main__":
    main()
