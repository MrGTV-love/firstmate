#!/usr/bin/env python3
"""The engine behind fm-home-write.sh; see that script's header for the contract.

Usage: fm-home-write.py --home DIR [--replace] TARGET < CONTENT

Exit: 0 written, 2 usage error, 3 refused, 4 refused because the deciding
source (the home's git index or ignore rules) could not be read.
Nothing is written on any nonzero exit, apart from data/ directories created
on the way to a target that is then refused for an existing-file reason.
"""
import argparse
import errno
import os
import stat
import subprocess
import sys
import unicodedata

ALLOWED_ROOT = "data"


class Refusal(Exception):
    def __init__(self, message, code=3):
        super().__init__(message)
        self.code = code


def fold(name):
    return unicodedata.normalize("NFD", name).casefold()


def split_target(home_spellings, raw):
    if not raw or "\0" in raw:
        raise Refusal("the target path is empty or contains a NUL byte")
    if not raw.startswith("/"):
        raw = home_spellings[0] + "/" + raw
    for home in home_spellings:
        if raw.startswith(home + "/"):
            rel = raw[len(home) + 1:]
            break
    else:
        raise Refusal(f"{raw} is outside this home ({home_spellings[0]}); only {ALLOWED_ROOT}/ inside FM_HOME is writable here")
    parts = rel.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise Refusal(f"{raw} has an empty, '.' or '..' segment; pass the plain path")
    if parts[0] != ALLOWED_ROOT or len(parts) < 2:
        raise Refusal(f"{rel} is not under {ALLOWED_ROOT}/; tracked material, projects/, state/, config/ and .env are not home-state records this route may write")
    return parts


def git(home, *args):
    return subprocess.run(["git", "-C", home, *args], capture_output=True, text=True,
                          env=dict(os.environ, LC_ALL="C", GIT_OPTIONAL_LOCKS="0"))


def reject_links(home, parts):
    # A readable early verdict; open_dirs re-checks with O_NOFOLLOW at write time.
    path = home
    for part in parts:
        path = os.path.join(path, part)
        try:
            mode = os.lstat(path).st_mode
        except FileNotFoundError:
            return
        if stat.S_ISLNK(mode):
            raise Refusal(f"{path[len(home) + 1:]} is a symbolic link; this route never follows links")


def git_failure(result, what):
    detail = (result.stderr.strip().splitlines() or [""])[0]
    return f"{what} (exit {result.returncode}{': ' + detail if detail else ''})"


def check_git(home, rel):
    top = git(home, "rev-parse", "--show-toplevel")
    if top.returncode or os.path.realpath(top.stdout.strip()) != home:
        raise Refusal(f"{home} is not the root of a git working tree, so tracked and ignored status cannot be proven", 4)
    tracked = git(home, "ls-files", "--error-unmatch", "--", rel)
    if tracked.returncode == 0:
        raise Refusal(f"{rel} is tracked by git; tracked files change only through a task worktree, never in place")
    ignored = git(home, "check-ignore", "-q", "--no-index", "--", rel)
    if ignored.returncode == 1:
        raise Refusal(f"{rel} is not gitignored, so it would become tracked material; only ignored home-state records are writable here")
    if ignored.returncode != 0:
        raise Refusal(git_failure(ignored, f"git check-ignore failed for {rel}"), 4)


def reject_case_variant(dir_fd, name, shown):
    wanted = fold(name)
    for entry in os.listdir(dir_fd):
        if entry != name and fold(entry) == wanted:
            raise Refusal(f"{shown} differs only in case or Unicode form from existing {entry}; use the exact existing name")


def open_dirs(home, parts):
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY)
    shown = ""
    try:
        for part in parts:
            shown = f"{shown}/{part}" if shown else part
            reject_case_variant(fd, part, shown)
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
            try:
                child = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                os.mkdir(part, 0o777, dir_fd=fd)
                child = os.open(part, flags, dir_fd=fd)
            except OSError as exc:
                if exc.errno in (errno.ELOOP, errno.ENOTDIR):
                    raise Refusal(f"{shown} is a symbolic link or not a directory; this route never follows links") from exc
                raise
            os.close(fd)
            fd = child
        return fd
    except BaseException:
        os.close(fd)
        raise


def write(home, parts, replace, data):
    fd = open_dirs(home, parts[:-1])
    name, rel = parts[-1], "/".join(parts)
    try:
        reject_case_variant(fd, name, rel)
        try:
            existing = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if stat.S_ISLNK(existing.st_mode):
                raise Refusal(f"{rel} is a symbolic link; this route never follows links")
            if not stat.S_ISREG(existing.st_mode):
                raise Refusal(f"{rel} exists and is not a regular file")
            if not replace:
                raise Refusal(f"{rel} already exists; pass --replace to overwrite it")
        tmp = f".{name}.fm-home-write.{os.getpid()}.tmp"
        out = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o666, dir_fd=fd)
        try:
            with os.fdopen(out, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            if existing is not None:
                os.chmod(tmp, stat.S_IMODE(existing.st_mode), dir_fd=fd)
            if replace:
                os.replace(tmp, name, src_dir_fd=fd, dst_dir_fd=fd)
            else:
                try:
                    os.link(tmp, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                except FileExistsError as exc:
                    raise Refusal(f"{rel} appeared while writing; pass --replace to overwrite it") from exc
        finally:
            try:
                os.unlink(tmp, dir_fd=fd)
            except FileNotFoundError:
                pass
    finally:
        os.close(fd)
    return rel


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--home", required=True)
    parser.add_argument("--replace", action="store_true")
    parser.add_argument("target")
    try:
        args = parser.parse_args()
    except SystemExit as exc:
        return 2 if exc.code else 0
    try:
        if not args.home.startswith("/") or not os.path.isdir(args.home):
            raise Refusal(f"FM_HOME={args.home} is not an absolute directory", 4)
        home = os.path.realpath(args.home)
        lexical = os.path.normpath(args.home)
        spellings = [home] + ([lexical] if lexical != home else [])
        parts = split_target(spellings, args.target)
        reject_links(home, parts)
        check_git(home, "/".join(parts))
        rel = write(home, parts, args.replace, sys.stdin.buffer.read())
    except Refusal as exc:
        print(f"fm-home-write: refused: {exc}", file=sys.stderr)
        return exc.code
    except OSError as exc:
        print(f"fm-home-write: refused: {exc}", file=sys.stderr)
        return 4
    print(f"fm-home-write: wrote {rel}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
