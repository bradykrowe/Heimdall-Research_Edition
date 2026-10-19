#!/usr/bin/env python3
"""Feedback rehearsal (M3d). Builds a temp vault from the bundle payload, plants
a file with a canary string, sends one report to the staging intake through the
shipped feedback.py with the doctor report attached, and checks that the reply
carries a report number while the printed payload carries neither the canary
nor the runner's user name. One post per run: the intake rate-limits.

    python feedback_check.py --bundle <unpacked bundle> --work <scratch> --tag <tag> --run-id <id>
"""
import argparse
import getpass
import json
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("--bundle", required=True)
ap.add_argument("--work", required=True)
ap.add_argument("--tag", required=True)
ap.add_argument("--run-id", required=True)
args = ap.parse_args()

bundle = Path(args.bundle)
work = Path(args.work)
vault = work / "feedback_vault"
if vault.exists():
    shutil.rmtree(vault)
shutil.copytree(bundle / "payload" / "vault", vault)

# a minimal install record so the report names the edition and tag
record = {"edition": "research", "tag": args.tag, "role": "ci", "vault": "~/ci_vault"}
(vault / "System" / "heimdall_install.json").write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")

canary = "CANARY-" + secrets.token_hex(6)
(vault / "Projects").mkdir(exist_ok=True)
(vault / "Projects" / "planted.md").write_text("private note " + canary + "\n", encoding="utf-8")

cfg = json.loads((vault / "System" / "feedback_intake.json").read_text(encoding="utf-8-sig"))
print("intake:", cfg.get("intake_url"), "channel:", cfg.get("channel"), "token present:", bool(cfg.get("token")))

note = "ci " + args.run_id + " " + args.tag
cmd = [sys.executable, str(vault / "System" / "bin" / "feedback.py"), "--vault", str(vault), "--doctor", "--yes", "--note", note]
run = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
out = run.stdout
print(out)
if run.stderr:
    print("stderr:", run.stderr)

fails = 0
def check(ok, pass_msg, fail_msg):
    global fails
    if ok:
        print("  [ OK ]", pass_msg)
    else:
        fails += 1
        print("  [FAIL]", fail_msg)

check(run.returncode == 0, "feedback.py exit 0", "feedback.py exit " + str(run.returncode))
check("Report number FB-" in out, "intake answered with a report number", "no 'Report number FB-' in the output (queued or refused)")
marker = "This is exactly what will be sent"
check(marker in out, "payload printed before the send", "payload marker missing")
payload_text = out.split(marker, 1)[1] if marker in out else out
check(canary not in payload_text, "canary string absent from the payload", "canary string leaked into the payload")
user = getpass.getuser()
check(user not in payload_text, "runner user name absent from the payload", "runner user name '" + user + "' appears in the payload")
check(str(vault) not in payload_text, "vault path absent from the payload", "vault path appears in the payload")
try:
    body = json.loads(payload_text.strip().split("\n}", 1)[0] + "\n}")
    allowed = {"note", "edition", "tag", "role", "os", "install_id", "doctor_report", "contact"}
    check(set(body) <= allowed, "payload keys within the fixed set", "unexpected payload keys: " + ", ".join(sorted(set(body) - allowed)))
    check(body.get("tag") == args.tag and body.get("edition") == "research", "payload names edition research and tag " + args.tag, "payload edition/tag: " + str(body.get("edition")) + "/" + str(body.get("tag")))
    check("doctor_report" in body, "doctor report attached", "doctor report missing")
except Exception as exc:
    check(False, "", "payload is not parseable JSON: " + type(exc).__name__)
check(not (vault / "System" / "feedback_outbox").exists() or not any((vault / "System" / "feedback_outbox").glob("*.json")), "nothing left in the outbox", "report queued in System/feedback_outbox/ instead of sent")

summary = os.environ.get("GITHUB_STEP_SUMMARY")
if summary:
    with open(summary, "a", encoding="utf-8") as fh:
        fh.write("Feedback rehearsal: " + ("all checks passed" if fails == 0 else str(fails) + " check(s) failed") + "\n")
print("feedback rehearsal:", "ok" if fails == 0 else str(fails) + " failed")
sys.exit(1 if fails else 0)
