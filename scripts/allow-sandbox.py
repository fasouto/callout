#!/usr/bin/env python3
"""Lets Claude Code's sandboxed shell commands reach the Callout app.

    scripts/allow-sandbox.py            allow Callout's socket
    scripts/allow-sandbox.py --remove   take the entry out again

With the sandbox on, shell commands may not use Unix sockets, and the socket is
how `callout` talks to the app: /callout and document reviews then end
with exit status 77. This adds the socket to sandbox.network.allowUnixSockets
in your own Claude Code settings, which cover every project on this Mac. It
needs doing once per Mac, and only if you use the sandbox. The file as it was
is kept beside it.
"""
import json
import os
import shutil
import sys
import time

settings = os.path.join(os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude"), "settings.json")
socket = os.path.expanduser("~/Library/Application Support/Callout/callout.sock")
remove = "--remove" in sys.argv[1:]

try:
    with open(settings) as file:
        content = json.load(file)
except FileNotFoundError:
    content = {}
except ValueError:
    sys.exit(f"{settings} is not valid JSON, so it was left untouched.")
if not isinstance(content, dict):
    sys.exit(f"{settings} is not a settings object, so it was left untouched.")

network = content.get("sandbox", {}).get("network", {}) if isinstance(content.get("sandbox", {}), dict) else {}
allowed = network.get("allowUnixSockets", []) if isinstance(network, dict) else []
if (socket in allowed) != remove:
    print("Nothing to take out: the socket is not in" if remove else "Already allowed in", settings)
    sys.exit(0)

if os.path.exists(settings):
    backup = f"{settings}.before-callout-{time.strftime('%Y%m%d-%H%M%S')}"
    shutil.copy2(settings, backup)
else:
    backup = None
    os.makedirs(os.path.dirname(settings), exist_ok=True)

if remove:
    allowed.remove(socket)
    # Leave nothing behind that was only there for this entry.
    if not allowed:
        del network["allowUnixSockets"]
    if not network:
        del content["sandbox"]["network"]
    if not content["sandbox"]:
        del content["sandbox"]
else:
    content.setdefault("sandbox", {}).setdefault("network", {}).setdefault("allowUnixSockets", []).append(socket)

with open(settings, "w") as file:
    json.dump(content, file, indent=2, ensure_ascii=False)
    file.write("\n")

print(("Took Callout's socket out of " if remove else "Allowed Callout's socket in ") + settings)
if backup:
    print(f"The file as it was: {backup}")
print("Claude Code sessions started from now on use it.")
