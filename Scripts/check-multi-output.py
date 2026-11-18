#!/usr/bin/env python3
"""Opt-in device regression with an external watchdog for Core Audio hangs."""
import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("device", help="Exact multi-output device name")
parser.add_argument("--loopback", help="Exact loopback input name; plays short quiet test tones")
args = parser.parse_args()
os.chdir(Path(__file__).resolve().parent.parent)
subprocess.run(["swift", "build", "--build-tests", "-Xswiftc", "-warnings-as-errors"], check=True)
env = dict(os.environ, VC_MULTI_OUTPUT_CHECK=args.device)
if args.loopback:
    env["VC_LOOPBACK_CHECK"] = args.loopback
log = Path(".build/multi-output-check.log")
with log.open("w") as output:
    process = subprocess.Popen(
        ["swift", "test", "--skip-build", "--filter", "testSwitchingToMultiOutput|MultiOutputTimingTests"],
        env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        result = process.wait(timeout=35)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        result = 124
        print("FAIL: audio output did not complete within the 35-second watchdog.")
print(log.read_text())
sys.exit(result)
