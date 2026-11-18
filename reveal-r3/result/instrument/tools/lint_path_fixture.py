#!/usr/bin/env python3
"""Create a warning fixture, detecting filesystems that reject invalid names."""
import errno
import os
import sys


def create_warning_file(path):
    raw = os.fsencode(path)
    try:
        raw.decode("utf-8")
        invalid_name = False
    except UnicodeDecodeError:
        invalid_name = True
    try:
        fixture = open(raw, "wb")
    except OSError as error:
        # APFS can reject these names at creation. Only a measured encoding
        # rejection changes the readable-file population: permissions, space,
        # missing directories, and failures on valid names must still fail.
        if invalid_name and error.errno in (errno.EILSEQ, errno.EINVAL):
            print("NOTE: filesystem rejected invalid UTF-8 filename %r "
                  "(errno %d); testing its missing-file diagnostics"
                  % (raw, error.errno), file=sys.stderr)
            return False
        raise
    with fixture:
        fixture.write(b"unused_local is 42\nprint of 1\n")
    return True


if __name__ == "__main__":
    print("present" if create_warning_file(sys.argv[1]) else "missing")
