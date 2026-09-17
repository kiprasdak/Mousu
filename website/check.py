#!/usr/bin/env python3
"""Validate the static site and optionally stage only its public files. Python stdlib only."""

import argparse
from html.parser import HTMLParser
from pathlib import Path
import re
import shutil
import sys
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parent
PUBLIC_FILES = ("index.html", "styles.css", "script.js", "icons.js", "motion.js")
TEXT_EXTENSIONS = {".html", ".css", ".js", ".svg", ".json", ".txt", ".webmanifest"}
CSS_URL = re.compile(r"url\(\s*['\"]?([^)'\"]+)['\"]?\s*\)", re.IGNORECASE)
CREDENTIALS = {
    "private key": re.compile(r"-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"),
    "GitHub token": re.compile(r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{50,})\b"),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "API key": re.compile(r"\bsk-(?:proj-)?[A-Za-z0-9_-]{32,}\b"),
}


class Page(HTMLParser):
    def __init__(self, path, errors):
        super().__init__(convert_charrefs=True)
        self.path = path
        self.errors = errors
        self.ids = set()
        self.references = []
        self.anchor = None

    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        identifier = values.get("id")
        if identifier:
            if identifier in self.ids:
                self.errors.append(f"{self.path.name}: duplicate ID {identifier!r}")
            self.ids.add(identifier)
        for attribute in ("href", "src", "poster", "data-hdr-src"):
            if attribute in values:
                self.references.append((values[attribute] or "", tag != "a"))
        if "srcset" in values:
            for candidate in values["srcset"].split(","):
                parts = candidate.strip().split()
                if parts:
                    self.references.append((parts[0], True))
        for reference in CSS_URL.findall(values.get("style", "")):
            self.references.append((reference, True))
        if tag == "a":
            self.anchor = {"href": values.get("href", ""), "text": "", "download": "download" in values}

    def handle_data(self, data):
        if self.anchor is not None:
            self.anchor["text"] += data

    def handle_endtag(self, tag):
        if tag == "a" and self.anchor is not None:
            anchor = self.anchor
            if anchor["download"] or "download" in anchor["text"].lower():
                target = urlsplit(anchor["href"])
                if not target.path.lower().endswith((".dmg", ".zip", ".pkg")):
                    self.errors.append(f"{self.path.name}: download action must point to an actual release file URL")
            self.anchor = None


def published_files(root, errors):
    files = []
    for name in PUBLIC_FILES:
        path = root / name
        if not path.is_file() or path.is_symlink():
            errors.append(f"Missing regular website file: {name}")
        else:
            files.append(path)
    assets = root / "assets"
    if assets.is_symlink():
        errors.append("assets must not be a symlink")
    elif assets.is_dir():
        for path in sorted(assets.rglob("*")):
            if path.is_symlink() or any(part.startswith(".") for part in path.relative_to(assets).parts):
                errors.append(f"Unpublishable asset: {path.relative_to(root)}")
            elif path.is_file():
                files.append(path)
    return files


def validate(root):
    errors = []
    files = published_files(root, errors)
    available = {path.resolve() for path in files}
    pages = {}
    references = []
    for path in files:
        if path.suffix.lower() not in TEXT_EXTENSIONS:
            continue
        try:
            source = path.read_text(encoding="utf-8")
        except UnicodeError:
            errors.append(f"{path.relative_to(root)}: text must be UTF-8")
            continue
        for name, pattern in CREDENTIALS.items():
            if pattern.search(source):
                errors.append(f"{path.relative_to(root)}: possible {name}; inspect before publishing")
        if path.suffix == ".html":
            page = Page(path, errors)
            page.feed(source)
            pages[path.resolve()] = page
            references.extend((path, url, asset) for url, asset in page.references)
        if path.suffix in {".css", ".html", ".svg"}:
            references.extend((path, url, True) for url in CSS_URL.findall(source))

    for origin, raw_url, asset in references:
        url = raw_url.strip()
        if not url or url == "#":
            errors.append(f"{origin.name}: empty or placeholder link")
            continue
        parsed = urlsplit(url)
        if parsed.scheme == "data" and asset:
            continue
        if parsed.scheme in {"https", "mailto"} or parsed.netloc:
            if asset:
                errors.append(f"{origin.name}: runtime assets must be local: {url}")
            continue
        if parsed.scheme:
            errors.append(f"{origin.name}: unsupported URL scheme: {parsed.scheme}")
            continue
        if parsed.path.startswith("/"):
            errors.append(f"{origin.name}: use a relative URL for project Pages: {url}")
            continue
        target = (origin.parent / unquote(parsed.path)).resolve() if parsed.path else origin.resolve()
        if target.is_dir():
            target = target / "index.html"
        if target not in available:
            errors.append(f"{origin.name}: target is missing or not in the published files: {url}")
        elif parsed.fragment and target in pages and unquote(parsed.fragment) not in pages[target].ids:
            errors.append(f"{origin.name}: missing fragment target: {url}")
    return files, errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="Copy validated public files into an empty directory")
    args = parser.parse_args()
    files, errors = validate(ROOT)
    if errors:
        print("Website validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    if args.output:
        output = args.output.resolve()
        if output == ROOT or ROOT in output.parents:
            parser.error("the staging directory must be outside website/")
        if output.exists() and (not output.is_dir() or any(output.iterdir())):
            parser.error("the staging directory must be empty")
        output.mkdir(parents=True, exist_ok=True)
        for path in files:
            destination = output / path.relative_to(ROOT)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, destination)
        (output / ".nojekyll").touch()
    print(f"Website validation passed: {len(files)} public files, local links/assets/fragments checked.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
