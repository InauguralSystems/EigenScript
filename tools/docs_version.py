#!/usr/bin/env python3
"""Stamp/check built HTML with its source commit and latest release docs (#2500).

CI supplies DOCS_RELEASE_TAG from GitHub's latest published release. Standalone
builds use the nearest stable release tag from git describe; fetch tags first.
The check is read-only and must run after all HTML (including playground) is
staged, before the workflow's success receipt and upload.
"""
import argparse
from html.parser import HTMLParser
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = "https://github.com/InauguralSystems/EigenScript"
MARKER = "eigenscript-build-version"
NOTE = re.compile(r'<aside\b[^>]*\bid="' + MARKER + r'"[^>]*>.*?</aside>', re.S)


class PageBody(HTMLParser):
    """Find the real body element, ignoring examples in comments and scripts."""
    def __init__(self, content):
        super().__init__()
        self.offsets = [0]
        for line in content.splitlines(keepends=True):
            self.offsets.append(self.offsets[-1] + len(line))
        self.body_end = None
        self.notes = 0
        self.feed(content)

    def handle_starttag(self, tag, attrs):
        if tag == "body" and self.body_end is None:
            line, column = self.getpos()
            self.body_end = self.offsets[line - 1] + column + len(self.get_starttag_text())
        if tag == "aside" and dict(attrs).get("id") == MARKER:
            self.notes += 1


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def version_note(root, release_tag=None):
    commit = git(root, "rev-parse", "HEAD")
    release = release_tag or os.environ.get("DOCS_RELEASE_TAG") or git(
        root, "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "--exclude", "*-*")
    if not re.fullmatch(r"v\d+\.\d+\.\d+", release):
        raise ValueError(f"expected a stable release tag, got {release!r}")
    release_commit = git(root, "rev-parse", f"{release}^{{commit}}")
    if release_commit == commit:
        relation = "This build matches the latest release"
    elif subprocess.run(["git", "-C", str(root), "merge-base", "--is-ancestor",
                         release_commit, commit], check=False).returncode == 0:
        relation = "This build is newer than the latest release"
    else:
        # Old checkouts and PRs need an honest note too; never claim a newer
        # release is older merely because its SHA differs.
        relation = "This build differs from the latest release"
    return (
        f'<aside id="{MARKER}" aria-label="Documentation version" '
        'style="padding:12px 18px;background:#fff5cf;color:#302800;font:14px/1.5 sans-serif">'
        'These docs and the playground track <code>main</code>. '
        f'This build describes commit <a href="{REPO}/commit/{commit}">{commit[:12]}</a>. '
        f'{relation}, <a href="{REPO}/releases/tag/{release}">{release}</a>; '
        f'see <a href="{REPO}/tree/{release}/docs/">{release} release documentation</a> '
        'for the installed release.</aside>'
    )


def pages(directory):
    result = sorted(directory.rglob("*.html"))
    if not result:
        raise ValueError(f"no HTML pages in {directory}")
    return result


def stamp(directory, note, release_page=False):
    pages(directory)  # An absent/empty build must not pass via the generated link page.
    if release_page:
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "release-docs.html").write_text(
            '<!doctype html><html lang="en"><head><meta charset="utf-8">'
            '<title>Latest EigenScript release documentation</title></head><body>'
            '<h1>Latest release documentation</h1>'
            '<p>Use the release documentation linked above for an installed release. '
            'The rest of this site describes the development build.</p></body></html>\n')
    for page in pages(directory):
        content = page.read_text()
        # Re-stamping after staging playground is intentionally idempotent.
        content = NOTE.sub("", content)
        body = PageBody(content).body_end
        if body is None:
            raise ValueError(f"{page}: no body element for visible version note")
        page.write_text(content[:body] + "\n" + note + content[body:])


def check(directory, note):
    failures = []
    checked = pages(directory)
    for page in checked:
        content = page.read_text()
        parsed = PageBody(content)
        body = parsed.body_end
        # Require the real, current note in the visible document, not merely
        # the marker or stale generated metadata in a comment/head/script.
        if parsed.notes != 1 or body is None or not content[body:].lstrip().startswith(note):
            failures.append(str(page))
    if failures:
        raise ValueError("missing or stale build version note: " + ", ".join(failures))
    print(f"docs version: checked {len(checked)} HTML page(s); all carry the build commit and release docs")


def selftest():
    """Exercise the CLI with a real temporary git history and HTML tree."""
    os.environ.pop("DOCS_RELEASE_TAG", None)
    script = Path(__file__).resolve()
    with tempfile.TemporaryDirectory(prefix="docs-version-") as temp:
        root = Path(temp)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        def commit(message):
            subprocess.run(["git", "-C", str(root), "-c", "user.name=Docs test",
                            "-c", "user.email=docs@example.invalid", "commit", "-qm",
                            message, "--allow-empty"], check=True)
        commit("release")
        subprocess.run(["git", "-C", str(root), "tag", "v1.0.0"], check=True)
        commit("main")
        site = root / "site"
        (site / "playground").mkdir(parents=True)
        for path in [site / "index.html", site / "playground/index.html"]:
            path.write_text('<!doctype html><html><body><h1>Page</h1></body></html>')
        env = os.environ.copy()
        env.pop("DOCS_RELEASE_TAG", None)
        def run(command, expected=0):
            result = subprocess.run([sys.executable, str(script), command, str(site),
                                     "--root", str(root)], env=env, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert result.returncode == expected, result.stdout
            return result.stdout
        assert "missing or stale" in run("check", 1)
        print("PASS: unmodified pages are red before stamping")
        run("stamp")
        run("check")
        note = version_note(root)
        assert "newer than the latest release" in note and "v1.0.0/docs/" in note
        print("PASS: main commit and older release docs appear on docs and playground")
        for relative in ["index.html", "playground/index.html"]:
            path = site / relative
            original = path.read_text()
            path.write_text(NOTE.sub("", original))
            assert str(path) in run("check", 1)
            path.write_text(original)
            print(f"PASS: missing-note plant caught on {relative}")
        run("stamp")
        run("check")
        print("PASS: re-stamping produces exactly one note")
        path = site / "index.html"
        original = path.read_text()
        path.write_text('<!-- example: <body>' + note + '</body> -->' + NOTE.sub("", original))
        assert str(path) in run("check", 1)
        run("stamp")
        run("check")
        assert PageBody(path.read_text()).notes == 1
        print("PASS: a body and note inside an HTML comment cannot satisfy the check")
        subprocess.run(["git", "-C", str(root), "tag", "v1.1.0"], check=True)
        assert "missing or stale" in run("check", 1)
        run("stamp")
        run("check")
        assert "matches the latest release" in version_note(root)
        assert "v1.1.0/docs/" in (site / "index.html").read_text()
        print("PASS: next release updates the tag link and equality wording without edits")
        commit("development")
        subprocess.run(["git", "-C", str(root), "tag", "v1.2.0-rc1"], check=True)
        run("stamp")
        run("check")
        assert "v1.1.0/docs/" in (site / "index.html").read_text()
        print("PASS: prerelease tags do not replace the stable release")
        stamp(site, version_note(root), release_page=True)
        run("check")
        assert "v1.1.0/docs/" in (site / "release-docs.html").read_text()
        print("PASS: README release-docs destination is generated and checked")
    print("DOCS_VERSION_SELFTEST: 9 passed, 0 failed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", nargs="?", choices=["stamp", "check"])
    parser.add_argument("directory", nargs="?", type=Path)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--release-tag")
    parser.add_argument("--release-page", action="store_true")
    parser.add_argument("--selftest", action="store_true")
    args = parser.parse_args()
    try:
        if args.selftest:
            selftest()
        else:
            if not args.action or not args.directory:
                parser.error("action and directory are required")
            note = version_note(args.root, args.release_tag)
            if args.action == "stamp":
                stamp(args.directory, note, args.release_page)
            else:
                check(args.directory, note)
    except (ValueError, OSError, subprocess.CalledProcessError, AssertionError) as exc:
        print(f"FAIL: docs version: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
