#!/usr/bin/env python3
"""Self-test and workflow wiring check for the issue #2217 release guard."""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "tools/release_main_guard.sh"
REVIEW_GUARD = ROOT / "tools/release_review_guard.sh"
failures = 0
checks = 0


def check(ok: bool, message: str) -> None:
    global failures, checks
    checks += 1
    if ok:
        print(f"PASS: {message}")
    else:
        failures += 1
        print(f"FAIL: {message}")


def git(repo: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()


def guard(repo: Path, event: str, ref: str, sha: str, marker: Path | None = None,
          tag: str = ""):
    env = os.environ.copy()
    env.update(RELEASE_EVENT_NAME=event, RELEASE_REF=ref, RELEASE_SHA=sha,
               RELEASE_TAG=tag)
    command = ["sh", str(GUARD)]
    if marker is not None:
        command += ["&&", "touch", str(marker)]
        return subprocess.run(" ".join(command), cwd=repo, env=env, shell=True,
                              text=True, capture_output=True)
    return subprocess.run(command, cwd=repo, env=env, text=True, capture_output=True)


def review_guard(repo: Path, tag: str):
    env = os.environ.copy()
    env["TAG"] = tag
    return subprocess.run(["sh", str(REVIEW_GUARD)], cwd=repo, env=env,
                          text=True, capture_output=True)


def workflow_checks() -> None:
    release = (ROOT / ".github/workflows/release.yml").read_text()
    docker = (ROOT / ".github/workflows/docker.yml").read_text()
    release_guard = release.find("name: Require commit on main")
    create_tag = release.find("name: Create tag")
    check(release_guard >= 0 and release_guard < create_tag,
          "release ancestry guard runs before tag creation")
    docker_guard = docker.find("name: Require commit on main")
    login = docker.find("name: Log in to GitHub Container Registry")
    push = docker.find("name: Build and push")
    check(docker_guard >= 0 and docker_guard < login and docker_guard < push,
          "Docker ancestry guard runs before registry login and every push")
    for name, text in (("release", release), ("Docker", docker)):
        check("RELEASE_SHA: ${{ github.sha }}" in text and
              "RELEASE_REF: ${{ github.ref }}" in text and
              "RELEASE_EVENT_NAME: ${{ github.event_name }}" in text,
              f"{name} guard binds expressions through env")
    check("run: sh tools/release_review_guard.sh" in release,
          "release workflow runs the review ancestry guard")
    review = REVIEW_GUARD.read_text()
    check("git merge-base --is-ancestor \"$reviewed\" \"$release\"" in review,
          "release review Range candidate must precede the release commit")
    check(all(path in review for path in ("docs/release-reviews/**", "VERSION",
                                          "CHANGELOG.md")),
          "post-review allowlist is limited to documented release bookkeeping")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] != "--selftest":
        print(f"usage: {Path(sys.argv[0]).name} --selftest", file=sys.stderr)
        return 2
    workflow_checks()
    with tempfile.TemporaryDirectory(prefix="eigs-2217-") as tmp:
        root = Path(tmp)
        remote = root / "remote.git"
        work = root / "work"
        subprocess.run(["git", "init", "--bare", "-q", str(remote)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(work)], check=True)
        git(work, "config", "user.email", "plant@example.invalid")
        git(work, "config", "user.name", "Issue 2217 plant")
        (work / "base").write_text("reviewed\n")
        git(work, "add", "base")
        git(work, "commit", "-qm", "reviewed main tip")
        main_sha = git(work, "rev-parse", "HEAD")
        git(work, "remote", "add", "origin", str(remote))
        git(work, "push", "-q", "-u", "origin", "main")

        # Plant an older on-main tag, then advance main.  Actions checks out the
        # tip at depth one before an idempotent dispatch resolves that old tag.
        git(work, "tag", "-a", "v9.9.7", "-m", "older on-main tag", main_sha)
        git(work, "push", "-q", "origin", "refs/tags/v9.9.7")
        (work / "tip").write_text("newer main tip\n")
        git(work, "add", "tip")
        git(work, "commit", "-qm", "advance main")
        tip_sha = git(work, "rev-parse", "HEAD")
        git(work, "push", "-q", "origin", "main")
        shallow = root / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth=1", "--branch", "main",
                        remote.as_uri(), str(shallow)], check=True)
        check((shallow / ".git/shallow").is_file(),
              "existing-tag plant really uses a depth-one main checkout")
        old_on_main = guard(shallow, "workflow_dispatch", "refs/heads/main",
                            tip_sha, tag="v9.9.7")
        check(old_on_main.returncode == 0,
              "depth-one dispatch accepts an older existing on-main tag")

        clean = guard(work, "workflow_dispatch", "refs/heads/main", tip_sha)
        check(clean.returncode == 0,
              "clean control accepts main tip with exit 0")

        git(work, "checkout", "-qb", "plant")
        (work / "plant").write_text("unreviewed\n")
        git(work, "add", "plant")
        git(work, "commit", "-qm", "unreviewed plant")
        plant_sha = git(work, "rev-parse", "HEAD")
        marker = root / "pushed"
        planted = guard(work, "push", "refs/tags/v9.9.9", plant_sha, marker)
        check(planted.returncode == 1 and "::error::" in planted.stderr,
              "off-main tag plant exits 1 with ::error")
        check(not marker.exists(),
              "off-main Docker plant reaches no simulated push")

        git(work, "tag", "-a", "v9.9.8", "-m", "off-main tag")
        git(work, "push", "-q", "origin", "refs/tags/v9.9.8")
        git(work, "checkout", "-q", "main")
        existing = guard(work, "workflow_dispatch", "refs/heads/main", main_sha,
                         tag="v9.9.8")
        check(existing.returncode == 1 and "::error::" in existing.stderr,
              "existing off-main tag cannot bypass a dispatch from main")

        dispatched = guard(work, "workflow_dispatch", "refs/heads/plant", main_sha)
        check(dispatched.returncode == 1 and "::error::" in dispatched.stderr,
              "dispatch from a non-main ref exits 1 with ::error")

        # A review describes the candidate before its own record is committed.
        # Only the release procedure's documented bookkeeping may follow it.
        review_remote = root / "review-remote.git"
        review_work = root / "review-work"
        subprocess.run(["git", "init", "--bare", "-q", str(review_remote)], check=True)
        subprocess.run(["git", "init", "-q", "-b", "main", str(review_work)], check=True)
        git(review_work, "config", "user.email", "review@example.invalid")
        git(review_work, "config", "user.name", "Review plant")
        (review_work / "candidate").write_text("reviewed candidate\n")
        git(review_work, "add", "candidate")
        git(review_work, "commit", "-qm", "reviewed candidate")
        reviewed = git(review_work, "rev-parse", "HEAD")
        git(review_work, "tag", "-a", "v9.9.9", "-m", "previous release")
        git(review_work, "remote", "add", "origin", str(review_remote))
        git(review_work, "push", "-q", "origin", "main", "refs/tags/v9.9.9")
        record = review_work / "docs/release-reviews/v10.0.0.md"
        record.parent.mkdir(parents=True)
        record.write_text(f"Range: v9.9.9..{reviewed}\nVerdict: clean\n")
        git(review_work, "add", str(record.relative_to(review_work)))
        git(review_work, "commit", "-qm", "commit release review")
        review_commit = git(review_work, "rev-parse", "HEAD")
        recorded = review_guard(review_work, "v10.0.0")
        check(recorded.returncode == 0,
              "review record committed after its candidate passes")

        (review_work / "unreviewed-code.c").write_text("unreviewed\n")
        git(review_work, "add", "unreviewed-code.c")
        git(review_work, "commit", "-qm", "unreviewed code plant")
        unreviewed = review_guard(review_work, "v10.0.0")
        check(unreviewed.returncode == 1 and
              "unreviewed-code.c" in unreviewed.stderr,
              "unreviewed code after Range candidate fails by path name")

        git(review_work, "reset", "--hard", review_commit)
        (review_work / "VERSION").write_text("10.0.0\n")
        (review_work / "CHANGELOG.md").write_text("# v10.0.0\n")
        git(review_work, "add", "VERSION", "CHANGELOG.md")
        git(review_work, "commit", "-qm", "release bookkeeping")
        bookkeeping = review_guard(review_work, "v10.0.0")
        check(bookkeeping.returncode == 0,
              "documented VERSION and CHANGELOG bookkeeping passes")

    print(f"PLAN: {checks}")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
