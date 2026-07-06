#!/usr/bin/env python3
"""Sandbox test harness for the BYOC region.

Subcommands:
  create [--persist]    create a sandbox; --persist also stops it (backs up to S3). prints SANDBOX_ID=...
  exec <id> <cmd...>    run a single command (no shell features) in the sandbox
  start <id>            start (restore) a stopped sandbox
  state <id>            print state / backup / runner for one sandbox
  list                  list all sandboxes in the region
  check                 exit 1 if ANY sandbox is not in a clean terminal state (started/stopped/archived)
  delete <id>           delete a sandbox

Env: DAYTONA_API_URL, DAYTONA_API_KEY, REGION_NAME (source .state/prompts.env).
Run with the SDK venv, e.g.:  scripts/aws-setup/test/.venv/bin/python3 /tmp/sbx.py ...
"""
import os
import sys
import time

GOOD_STATES = {"started", "stopped", "archived"}


def client():
    from daytona import Daytona, DaytonaConfig
    return Daytona(DaytonaConfig(
        api_key=os.environ["DAYTONA_API_KEY"],
        api_url=os.environ["DAYTONA_API_URL"],
        target=os.environ["REGION_NAME"],
    ))


def getter(c):
    return getattr(c, "get", None) or getattr(c, "find_one", None)


def norm_state(s):
    return str(getattr(s, "state", "")).lower().split(".")[-1]


def row(s):
    return (f"{getattr(s,'id','?')}  state={getattr(s,'state',None)}  "
            f"runner={getattr(s,'runner_id',None)}  backup={getattr(s,'backup_state',None)}")


def do_stop(c, sb):
    stop = getattr(c, "stop", None)
    stop(sb) if stop else sb.stop()


def do_start(c, sb):
    start = getattr(c, "start", None)
    start(sb) if start else sb.start()


def cmd_create(args):
    from daytona import Image, CreateSandboxFromImageParams
    c = client()
    persist = "--persist" in args
    print("creating sandbox (alpine:3.21)...", flush=True)
    sb = c.create(CreateSandboxFromImageParams(image=Image.base("alpine:3.21")), timeout=300)
    print("created:", row(sb), flush=True)
    if persist:
        print("stopping to back up to S3...", flush=True)
        do_stop(c, sb)
        g = getter(c)
        for _ in range(120):
            s = g(sb.id)
            bc = getattr(s, "backup_created_at", None)
            bs = getattr(s, "backup_state", None)
            print(f"  state={getattr(s,'state',None)} backup_state={bs} backup_created_at={bc}", flush=True)
            if bc or (bs and str(bs).lower() in ("completed", "error")):
                print(f"backup terminal state: {bs}", flush=True)
                break
            time.sleep(5)
    print("SANDBOX_ID=" + sb.id, flush=True)


def cmd_exec(args):
    c = client()
    sid, cmd = args[0], " ".join(args[1:])
    sb = getter(c)(sid)
    r = sb.process.exec(cmd)
    print("exit:", getattr(r, "exit_code", None), "out:", repr(getattr(r, "result", "")), flush=True)


def cmd_start(args):
    c = client()
    sb = getter(c)(args[0])
    print("before:", row(sb), flush=True)
    do_start(c, sb)
    g = getter(c)
    for _ in range(120):
        s = g(args[0])
        print("  " + row(s), flush=True)
        if "start" in norm_state(s) or "run" in norm_state(s):
            break
        time.sleep(5)


def cmd_state(args):
    print(row(getter(client())(args[0])), flush=True)


def cmd_list(args):
    c = client()
    sbs = list(c.list())
    print(f"{len(sbs)} sandboxes:", flush=True)
    for s in sbs:
        print("  " + row(s), flush=True)


def cmd_check(args):
    c = client()
    sbs = list(c.list())
    bad = [s for s in sbs if norm_state(s) not in GOOD_STATES]
    print(f"total={len(sbs)}  bad={len(bad)}  (clean states: {sorted(GOOD_STATES)})", flush=True)
    for s in bad:
        print("  BAD: " + row(s), flush=True)
    if bad:
        print("RESULT: orphaned/error/stuck sandboxes present", flush=True)
        sys.exit(1)
    print("RESULT: all sandboxes clean ✓", flush=True)


def cmd_delete(args):
    c = client()
    c.delete(getter(c)(args[0]))
    print("deleted " + args[0], flush=True)


CMDS = {"create": cmd_create, "exec": cmd_exec, "start": cmd_start,
        "state": cmd_state, "list": cmd_list, "check": cmd_check, "delete": cmd_delete}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        print(__doc__)
        sys.exit(2)
    CMDS[sys.argv[1]](sys.argv[2:])
