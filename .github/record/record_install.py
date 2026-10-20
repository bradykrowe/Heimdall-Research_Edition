#!/usr/bin/env python3
"""Record an interactive install in a pseudo-terminal, answering the prompts
the way a person would, and write an asciicast v2 file.

Runs on a GitHub macOS runner with Apple's python3 (3.9), no extra packages.
The shell is started first, the install line is typed into it keystroke by
keystroke, and each question the installer asks is answered after a short
pause. Nothing is synthesized: the cast holds what the terminal printed.

    python3 record_install.py --out install.cast --cols 100 --rows 30 \
        --shell "bash --noprofile --norc -i" --prompt '~ % ' \
        --type 'curl -fsSL https://.../get.sh | bash'
"""
import argparse
import fcntl
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

# (regex on the tail of the output, keys to send, pause before sending)
ANSWERS = [
    (r"Continue\? \[Y/n\] $",                          "y\r", 1.6),
    (r"Install Homebrew now\? \[Y/n\] $",               "y\r", 1.4),
    (r"Press RETURN/ENTER to continue or any other key to abort:?\s*$", "\r", 1.2),
    (r"Vault path \[[^\]]*\]: $",                       "\r",  2.0),
    (r"Paste its path, or press Return to skip: $",     "\r",  1.4),
    (r"Open the vault in Obsidian now\? \[Y/n\] $",     "y\r", 1.6),
    (r"Start Claude in the vault now\? \[Y/n\] $",      "n\r", 1.6),
    (r"Press Return to close\.\s*$",                    "\r",  1.0),
    # Anything else with a yes default: say yes. A no default: take it.
    (r"\[Y/n\] $",                                      "y\r", 1.4),
    (r"\[y/N\] $",                                      "\r",  1.4),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--cols", type=int, default=100)
    ap.add_argument("--rows", type=int, default=30)
    ap.add_argument("--shell", default="bash --noprofile --norc -i")
    ap.add_argument("--prompt", default="~ % ", help="PS1 for the shell; also what we wait for")
    ap.add_argument("--type", required=True, help="the line to type at the first prompt")
    ap.add_argument("--idle-timeout", type=float, default=900.0)
    ap.add_argument("--keystroke", type=float, default=0.045)
    a = ap.parse_args()

    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env["PS1"] = a.prompt
    env["COLUMNS"] = str(a.cols)
    env["LINES"] = str(a.rows)
    env.pop("PROMPT_COMMAND", None)

    pid, fd = pty.fork()
    if pid == 0:
        argv = a.shell.split()
        os.execvpe(argv[0], argv, env)

    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", a.rows, a.cols, 0, 0))

    t0 = time.time()
    events = []
    tail = ""
    state = "await_prompt"
    prompt_re = re.compile(r"(^|\n|\r)" + re.escape(a.prompt) + r"$")
    last_output = time.time()
    exit_code = None

    def send(keys, pause):
        nonlocal tail
        time.sleep(pause)
        for ch in keys:
            os.write(fd, ch.encode())
            if ch != "\r":
                time.sleep(a.keystroke)
        tail = ""

    while True:
        r, _, _ = select.select([fd], [], [], 0.25)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            last_output = time.time()
            text = data.decode("utf-8", "replace")
            events.append([round(time.time() - t0, 4), "o", text])
            tail = (tail + text)[-4000:]
            plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", tail)
            if state == "await_prompt" and prompt_re.search(plain):
                state = "installing"
                send(a.type + "\r", 1.0)
                continue
            if state == "installing":
                answered = False
                for pat, keys, pause in ANSWERS:
                    if re.search(pat, plain):
                        print("answering %r" % pat, flush=True)
                        send(keys, pause)
                        answered = True
                        break
                if not answered and prompt_re.search(plain):
                    state = "done"
                    send("exit\r", 3.0)
        else:
            if state == "await_prompt" and time.time() - t0 > 30:
                print("no shell prompt after 30s; stopping", flush=True)
                os.kill(pid, signal.SIGTERM); exit_code = 125; break
            if time.time() - last_output > a.idle_timeout:
                print("no output for %.0fs; stopping" % a.idle_timeout, flush=True)
                os.kill(pid, signal.SIGTERM)
                exit_code = 124
                break

    try:
        _, status = os.waitpid(pid, 0)
        if exit_code is None:
            exit_code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128
    except ChildProcessError:
        pass

    header = {"version": 2, "width": a.cols, "height": a.rows, "timestamp": int(t0),
              "env": {"TERM": "xterm-256color", "SHELL": a.shell.split()[0]}}
    with open(a.out, "w", encoding="utf-8") as f:
        f.write(json.dumps(header) + "\n")
        for ev in events:
            f.write(json.dumps(ev, ensure_ascii=False) + "\n")
    print("wrote %s: %d events, %.0fs, shell exit %s, final state %s"
          % (a.out, len(events), events[-1][0] if events else 0, exit_code, state), flush=True)
    sys.exit(0 if state == "done" else 1)


if __name__ == "__main__":
    main()
