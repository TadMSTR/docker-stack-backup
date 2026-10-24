#!/usr/bin/env python3
"""ptrace-probe.py <pid> — exit 0 if the caller may ptrace <pid>, 1 if not.

Used by restore-drill.sh --probes. PTRACE_SEIZE, not PTRACE_ATTACH: it makes the same
access check (ptrace_may_access, PTRACE_MODE_ATTACH) but does not stop the target, and the
kernel detaches it when this process exits. PTRACE_ATTACH queues a SIGSTOP that outlives
the tracer: the 0.8.0 drill left its own probe target in state T, holding the transcript
pipe open, and the drill hung at teardown (#1218).
"""
import ctypes
import sys

PTRACE_SEIZE = 0x4206

pid = int(sys.argv[1])
libc = ctypes.CDLL(None, use_errno=True)
libc.ptrace.argtypes = [ctypes.c_long, ctypes.c_long, ctypes.c_void_p, ctypes.c_void_p]
libc.ptrace.restype = ctypes.c_long
sys.exit(0 if libc.ptrace(PTRACE_SEIZE, pid, None, None) == 0 else 1)
