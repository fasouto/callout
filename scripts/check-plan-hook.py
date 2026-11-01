#!/usr/bin/env python3
"""Checks how the installed Claude Code treats a plan hook's decisions.

Callout's plan hook answers the PermissionRequest for ExitPlanMode. Whether
"allow" really skips Claude Code's own plan dialog has changed between
versions (anthropics/claude-code issues 15755 and 97656), so this script finds
out for the version on this machine.

It starts a real, short Claude Code session in a temporary folder, with a
stand-in hook that denies the first plan with a message and allows the second.
It uses your Claude account (one small Haiku conversation) and leaves that
session's transcript and plan file under ~/.claude like any other. Run it with:

    python3 scripts/check-plan-hook.py
"""

import json
import os
import pty
import select
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

PROMPT = (
    "Plan mode test. Write a plan with exactly one step: create a file named hello.txt containing "
    "the word hi. Do not ask me any questions and do not explore. Present the plan with ExitPlanMode "
    "right away. Once the plan is approved, create the file exactly as the approved plan says, then stop."
)

HOOK = """#!/bin/sh
dir="{root}"
n=$(cat "$dir/count" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "$dir/count"
cat > "$dir/input-$n.json"
if [ "$n" = 1 ]; then
  printf '%s' '{deny}'
else
  printf '%s' '{allow}'
fi
"""

DENY = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
    "behavior": "deny",
    "message": "The user reviewed this plan and wants one change: the file must be named hello2.txt "
               "instead of hello.txt. Revise the plan and present it again."}}}
ALLOW = {"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": {
    "behavior": "allow",
    "updatedPermissions": [{"type": "setMode", "mode": "acceptEdits", "destination": "session"}]}}}


def main():
    claude = shutil.which("claude") or os.path.expanduser("~/.claude/local/claude")
    if not os.path.exists(claude):
        sys.exit("claude was not found on PATH.")
    version = subprocess.run([claude, "--version"], capture_output=True, text=True).stdout.strip()

    root = tempfile.mkdtemp(prefix="callout-hook-check-")
    project = os.path.join(root, "project")
    os.mkdir(project)
    hook = os.path.join(root, "hook.sh")
    with open(hook, "w") as file:
        file.write(HOOK.format(root=root, deny=json.dumps(DENY), allow=json.dumps(ALLOW)))
    os.chmod(hook, os.stat(hook).st_mode | stat.S_IXUSR)
    settings = os.path.join(root, "settings.json")
    with open(settings, "w") as file:
        json.dump({"hooks": {"PermissionRequest": [{"matcher": "ExitPlanMode", "hooks": [
            {"type": "command", "command": hook, "timeout": 60}]}]}}, file)

    # A fresh session, not a child of the one this may be running in.
    environment = {k: v for k, v in os.environ.items() if k != "CLAUDECODE" and not k.startswith("CLAUDE_")}
    environment["TERM"] = "xterm-256color"
    # Only this script's hook may answer the plan: your own settings are left out,
    # so an installed Callout plugin does not open the test plan for review too.
    arguments = [
        claude, "--permission-mode", "plan", "--setting-sources", "project",
        "--settings", settings, "--model", "haiku",
    ]

    pid, terminal = pty.fork()
    if pid == 0:
        os.chdir(project)
        os.execvpe(arguments[0], arguments, environment)

    alive = True

    def drain(seconds):
        nonlocal alive
        end = time.time() + seconds
        while alive and time.time() < end:
            ready, _, _ = select.select([terminal], [], [], 0.5)
            if terminal in ready:
                try:
                    data = os.read(terminal, 65536)
                except OSError:
                    data = b""
                if not data:
                    alive = False

    def send(text):
        if alive:
            os.write(terminal, text.encode())

    def hook_calls():
        try:
            return int(open(os.path.join(root, "count")).read())
        except (OSError, ValueError):
            return 0

    print(f"{version}: running a short plan-mode session, this takes a minute or two...")
    drain(10)
    send("\x1b[B")  # the folder trust dialog starts on "No, exit"
    drain(1)
    send("\r")
    drain(5)
    send(PROMPT)
    drain(2)
    send("\r")

    created = None
    deadline = time.time() + 200
    while alive and time.time() < deadline and created is None:
        drain(2)
        for name in ("hello2.txt", "hello.txt"):
            if os.path.exists(os.path.join(project, name)):
                created = name
        # Once the second plan was allowed, a minute is plenty for the file to appear.
        if hook_calls() >= 2:
            deadline = min(deadline, time.time() + 60)
    drain(3)
    # Claude Code can take a moment to quit on its own; do not leave it behind.
    for sign in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.kill(pid, sign)
        except ProcessLookupError:
            break
        gone = False
        end = time.time() + 3
        while not gone and time.time() < end:
            try:
                gone = os.waitpid(pid, os.WNOHANG)[0] != 0
            except ChildProcessError:
                gone = True
            time.sleep(0.1)
        if gone:
            break

    calls = hook_calls()
    print(f"hook calls: {calls}")
    if calls == 0:
        print("The hook never ran. The session may not have reached a plan; nothing can be concluded.")
    elif calls == 1:
        print("deny: the plan was denied but Claude did not present a revised plan in time.")
    else:
        print("deny: works. Claude revised the plan after the hook's message.")
        if created:
            print(f"allow: works. Plan mode was left and {created} was created without a prompt.")
        else:
            print("allow: ignored. Claude Code still shows its own plan dialog after the hook allows.")
    shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
