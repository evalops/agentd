#!/usr/bin/env python3
# SPDX-License-Identifier: BUSL-1.1
"""Write and verify the agentd Sparkle appcast metadata."""

from __future__ import annotations

import argparse
import datetime as dt
import os
import plistlib
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)


def _sparkle(name: str) -> str:
    return f"{{{SPARKLE_NS}}}{name}"


def _read_versions(plist_path: Path) -> tuple[str, str]:
    with plist_path.open("rb") as fh:
        plist = plistlib.load(fh)
    version = str(plist.get("CFBundleVersion") or "")
    short_version = str(plist.get("CFBundleShortVersionString") or version)
    if not version:
        raise SystemExit(f"{plist_path} does not contain CFBundleVersion")
    return version, short_version


def _pubdate() -> str:
    source_date_epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if source_date_epoch:
        when = dt.datetime.fromtimestamp(int(source_date_epoch), tz=dt.timezone.utc)
    else:
        when = dt.datetime.now(tz=dt.timezone.utc)
    return when.strftime("%a, %d %b %Y %H:%M:%S %z")


def write_appcast(args: argparse.Namespace) -> None:
    archive = args.archive.resolve()
    if not archive.exists():
        raise SystemExit(f"archive does not exist: {archive}")
    signature = args.ed_signature.strip()
    if not signature:
        raise SystemExit("--ed-signature is required for Sparkle appcasts")

    version, short_version = _read_versions(args.info_plist)
    length = archive.stat().st_size

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = args.title
    ET.SubElement(channel, "description").text = "Signed EvalOps agentd updates"
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"Version {short_version}"
    if args.channel:
        ET.SubElement(item, _sparkle("channel")).text = args.channel
    ET.SubElement(item, _sparkle("version")).text = version
    ET.SubElement(item, _sparkle("shortVersionString")).text = short_version
    if args.minimum_autoupdate_version:
        ET.SubElement(item, _sparkle("minimumAutoupdateVersion")).text = (
            args.minimum_autoupdate_version
        )
    if args.phased_rollout_interval:
        ET.SubElement(item, _sparkle("phasedRolloutInterval")).text = str(
            args.phased_rollout_interval
        )
    if args.critical_update:
        ET.SubElement(item, _sparkle("criticalUpdate"))
    ET.SubElement(item, "pubDate").text = _pubdate()
    if args.release_notes_url:
        ET.SubElement(item, _sparkle("releaseNotesLink")).text = args.release_notes_url
    ET.SubElement(
        item,
        "enclosure",
        {
            "url": args.download_url,
            _sparkle("edSignature"): signature,
            "length": str(length),
            "type": "application/octet-stream",
        },
    )
    ET.SubElement(item, _sparkle("minimumSystemVersion")).text = args.minimum_system_version

    ET.indent(rss)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    tree = ET.ElementTree(rss)
    tree.write(args.output, encoding="utf-8", xml_declaration=True)
    print(f"Wrote Sparkle appcast {args.output}")


def _first_item(root: ET.Element) -> ET.Element:
    item = root.find("./channel/item")
    if item is None:
        raise SystemExit("appcast is missing channel/item")
    return item


def verify_appcast(args: argparse.Namespace) -> None:
    root = ET.parse(args.appcast).getroot()
    item = _first_item(root)
    enclosure = item.find("enclosure")
    if enclosure is None:
        raise SystemExit("appcast item is missing enclosure")

    url = enclosure.attrib.get("url", "")
    signature = enclosure.attrib.get(_sparkle("edSignature"), "")
    length = enclosure.attrib.get("length", "")
    version = item.findtext(_sparkle("version"), "")
    short_version = item.findtext(_sparkle("shortVersionString"), "")
    channel = item.findtext(_sparkle("channel"), "")
    rollout = item.findtext(_sparkle("phasedRolloutInterval"), "")

    if args.require_https and not url.startswith("https://"):
        raise SystemExit(f"appcast enclosure URL must use https://, got {url!r}")
    if args.download_url and url != args.download_url:
        raise SystemExit(f"download URL mismatch: expected {args.download_url!r}, got {url!r}")
    if args.expected_version and version != args.expected_version:
        raise SystemExit(f"version mismatch: expected {args.expected_version!r}, got {version!r}")
    if args.expected_short_version and short_version != args.expected_short_version:
        raise SystemExit(
            "short version mismatch: "
            f"expected {args.expected_short_version!r}, got {short_version!r}"
        )
    if args.expected_channel and channel != args.expected_channel:
        raise SystemExit(f"channel mismatch: expected {args.expected_channel!r}, got {channel!r}")
    if args.expected_phased_rollout_interval:
        expected_rollout = str(args.expected_phased_rollout_interval)
        if rollout != expected_rollout:
            raise SystemExit(
                "phased rollout interval mismatch: "
                f"expected {expected_rollout!r}, got {rollout!r}"
            )
    if not signature.strip():
        raise SystemExit("appcast enclosure is missing sparkle:edSignature")
    if not length.isdigit() or int(length) <= 0:
        raise SystemExit(f"appcast enclosure has invalid length: {length!r}")
    if args.archive and int(length) != args.archive.stat().st_size:
        raise SystemExit(
            f"archive length mismatch: expected {args.archive.stat().st_size}, got {length}"
        )

    print(f"Verified Sparkle appcast {args.appcast}")


def self_test(_: argparse.Namespace) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        base = Path(tmp)
        archive = base / "agentd.zip"
        archive.write_bytes(b"agentd update archive")
        plist = base / "Info.plist"
        with plist.open("wb") as fh:
            plistlib.dump(
                {
                    "CFBundleVersion": "42",
                    "CFBundleShortVersionString": "1.2.3",
                },
                fh,
            )
        appcast = base / "appcast.xml"
        write_appcast(
            argparse.Namespace(
                archive=archive,
                info_plist=plist,
                output=appcast,
                download_url="https://updates.example.invalid/agentd.zip",
                ed_signature="fixture-signature",
                release_notes_url=None,
                title="EvalOps agentd Updates",
                minimum_system_version="14.0.0",
                channel="beta",
                phased_rollout_interval=86400,
                minimum_autoupdate_version=None,
                critical_update=False,
            )
        )
        verify_appcast(
            argparse.Namespace(
                appcast=appcast,
                archive=archive,
                download_url="https://updates.example.invalid/agentd.zip",
                expected_version="42",
                expected_short_version="1.2.3",
                expected_channel="beta",
                expected_phased_rollout_interval=86400,
                require_https=True,
            )
        )
    print("Sparkle appcast self-test passed")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    write_parser = subparsers.add_parser("write")
    write_parser.add_argument("--archive", required=True, type=Path)
    write_parser.add_argument("--info-plist", required=True, type=Path)
    write_parser.add_argument("--output", required=True, type=Path)
    write_parser.add_argument("--download-url", required=True)
    write_parser.add_argument("--ed-signature", required=True)
    write_parser.add_argument("--release-notes-url")
    write_parser.add_argument("--title", default="EvalOps agentd Updates")
    write_parser.add_argument("--minimum-system-version", default="14.0.0")
    write_parser.add_argument("--channel")
    write_parser.add_argument("--phased-rollout-interval", type=int)
    write_parser.add_argument("--minimum-autoupdate-version")
    write_parser.add_argument("--critical-update", action="store_true")
    write_parser.set_defaults(func=write_appcast)

    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--appcast", required=True, type=Path)
    verify_parser.add_argument("--archive", type=Path)
    verify_parser.add_argument("--download-url")
    verify_parser.add_argument("--expected-version")
    verify_parser.add_argument("--expected-short-version")
    verify_parser.add_argument("--expected-channel")
    verify_parser.add_argument("--expected-phased-rollout-interval", type=int)
    verify_parser.add_argument("--require-https", action="store_true")
    verify_parser.set_defaults(func=verify_appcast)

    self_test_parser = subparsers.add_parser("self-test")
    self_test_parser.set_defaults(func=self_test)

    args = parser.parse_args(argv)
    args.func(args)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
