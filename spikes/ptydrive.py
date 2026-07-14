#!/usr/bin/env python3
"""PTY expect-harness for driving TUI agents (claude / codex) headlessly.

Usage: ptydrive.py scenario.json outdir

Scenario format:
{
  "command": ["claude"],
  "cwd": "/tmp/somewhere",
  "env": {"FOO": "1"},
  "cols": 120, "rows": 40,
  "timeout": 120,
  "steps": [
    {"label": "trust", "wait_for": "Do you trust", "timeout": 30, "optional": true},
    {"label": "accept", "send": "\r", "settle": 1.0},
    {"label": "picker", "send": "/model\r", "wait_for": "Select model", "snapshot": true}
  ]
}

Each step may have: wait_for (regex matched against the rendered screen),
send (bytes to write, after wait_for matches), settle (seconds to wait after
send), snapshot (dump rendered screen to screens/<n>-<label>.txt), optional
(if wait_for times out, continue instead of abort), timeout (per-step).

Outputs: events.jsonl (timestamped base64 chunks), raw.bin, screens/*.txt,
final-screen.txt, result.json.
"""
import base64
import json
import os
import pty
import re
import select
import signal
import struct
import sys
import termios
import time


def render(screen):
    return "\n".join(screen.display)


def main():
    scenario = json.load(open(sys.argv[1]))
    outdir = sys.argv[2]
    os.makedirs(os.path.join(outdir, "screens"), exist_ok=True)

    import pyte
    cols, rows = scenario.get("cols", 120), scenario.get("rows", 40)
    screen = pyte.Screen(cols, rows)
    stream = pyte.ByteStream(screen)

    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env.update(scenario.get("env", {}))

    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(scenario.get("cwd", "/tmp"))
        os.execvpe(scenario["command"][0], scenario["command"], env)

    struct_ws = struct.pack("HHHH", rows, cols, 0, 0)
    import fcntl
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct_ws)

    events = open(os.path.join(outdir, "events.jsonl"), "w")
    rawf = open(os.path.join(outdir, "raw.bin"), "wb")
    t0 = time.time()
    deadline = t0 + scenario.get("timeout", 120)

    def pump(until=None, quiet_after=None):
        """Read PTY output until `until` timestamp or quiet_after secs of silence."""
        last_data = time.time()
        while True:
            now = time.time()
            if now > deadline:
                return "deadline"
            if until is not None and now >= until:
                return "until"
            if quiet_after is not None and now - last_data >= quiet_after:
                return "quiet"
            r, _, _ = select.select([fd], [], [], 0.05)
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return "eof"
                if not data:
                    return "eof"
                last_data = time.time()
                rawf.write(data)
                events.write(json.dumps({"t": round(last_data - t0, 4),
                                         "data": base64.b64encode(data).decode()}) + "\n")
                events.flush()
                stream.feed(data)

    result = {"steps": [], "aborted": False}
    snap_n = 0
    for step in scenario.get("steps", []):
        label = step.get("label", "?")
        entry = {"label": label, "t_start": round(time.time() - t0, 3)}
        if "wait_for" in step:
            pat = re.compile(step["wait_for"], re.S)
            step_deadline = time.time() + step.get("timeout", 20)
            matched = False
            while time.time() < step_deadline:
                status = pump(until=time.time() + 0.15)
                if status in ("eof", "deadline"):
                    entry["pty"] = status
                    break
                if pat.search(render(screen)):
                    matched = True
                    break
            entry["matched"] = matched
            entry["t_matched"] = round(time.time() - t0, 3)
            if not matched and not step.get("optional"):
                entry["error"] = "wait_for timeout"
                result["steps"].append(entry)
                result["aborted"] = True
                break
        if "send" in step and not (step.get("skip_if_unmatched") and not entry.get("matched", True)):
            os.write(fd, step["send"].encode())
            entry["sent"] = repr(step["send"])
        if "settle" in step:
            pump(until=time.time() + step["settle"])
        if step.get("snapshot"):
            snap_n += 1
            p = os.path.join(outdir, "screens", f"{snap_n:02d}-{label}.txt")
            with open(p, "w") as f:
                f.write(render(screen))
            entry["snapshot"] = p
        result["steps"].append(entry)

    pump(until=time.time() + scenario.get("final_settle", 1.5))
    with open(os.path.join(outdir, "final-screen.txt"), "w") as f:
        f.write(render(screen))

    try:
        os.kill(pid, signal.SIGHUP)
        time.sleep(0.3)
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(pid, os.WNOHANG)

    result["duration"] = round(time.time() - t0, 2)
    json.dump(result, open(os.path.join(outdir, "result.json"), "w"), indent=1)
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
