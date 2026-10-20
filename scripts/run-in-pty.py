#!/usr/bin/env python3
"""Runs a command under a pseudo-terminal and returns its exit status.

CI pipes the test run into a log. Piped, Swift Testing's output is block-buffered, and a process that dies
loses its last buffer, so the log stops at a block boundary that says nothing about where the process died.
Under a terminal the output is flushed line by line. If the command is killed by a signal this says so,
because the shell would otherwise report only a bare exit code.
"""
import os
import pty
import sys

if len(sys.argv) < 2:
    sys.exit("usage: run-in-pty.py command [arguments...]")

status = pty.spawn(sys.argv[1:])
code = os.waitstatus_to_exitcode(status)
if code < 0:
    print(f"\n*** {sys.argv[1]} was killed by signal {-code} ***", flush=True)
    sys.exit(128 - code)
sys.exit(code)
