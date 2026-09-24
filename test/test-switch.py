#!/usr/bin/python3
"""Exercise the credential move against a throwaway HOME.

Proves the part that cannot be tested against the real login: that a switch
moves a credential rather than copying it, carries the identity marker across,
preserves the rest of .claude.json, and leaves exactly one live copy.
"""
import json, os, shutil, subprocess, sys, tempfile
from pathlib import Path

HELPER = str(Path(__file__).resolve().parent.parent / "bin" / "omarchy-claude-account")
ALPHA = "zzt-alpha"
BETA = "zzt-beta"

root = Path(tempfile.mkdtemp(prefix="acctest-"))
home = root / "home"
(home / ".claude").mkdir(parents=True)

env = dict(os.environ, HOME=str(home),
           XDG_DATA_HOME=str(home / ".local/share"),
           XDG_CONFIG_HOME=str(home / ".config"))

creds = home / ".claude/.credentials.json"
creds.write_text(json.dumps({"claudeAiOauth": {"refreshToken": "ALPHA-TOKEN"}}))
os.chmod(creds, 0o600)
(home / ".claude.json").write_text(json.dumps({
    "projects": {"keep": "me"},
    "oauthAccount": {"accountUuid": "uuid-alpha", "emailAddress": "alpha@example.test",
                     "organizationName": "AlphaOrg"},
}))

def run(*args, **kw):
    return subprocess.run([HELPER, *args], env=env, text=True, capture_output=True, **kw)

def secret(*args, inp=None):
    return subprocess.run(["secret-tool", *args], input=inp, text=True, capture_output=True)

failures = []
def check(name, condition, detail=""):
    print(("  PASS  " if condition else "  FAIL  ") + name + (f"   {detail}" if detail and not condition else ""))
    if not condition:
        failures.append(name)

try:
    print(run("adopt", ALPHA).stdout.strip())
    run("add", BETA, "--no-login")
    secret("store", "--label=test", "omarchy-claude-account", BETA,
           inp=json.dumps({"claudeAiOauth": {"refreshToken": "BETA-TOKEN"}}))
    beta_dir = home / ".local/share/omarchy/claude-accounts" / BETA
    (beta_dir / ".claude.json").write_text(json.dumps({
        "oauthAccount": {"accountUuid": "uuid-beta", "emailAddress": "beta@example.test",
                         "organizationName": "BetaOrg"}}))

    print("\n--- dry run ---")
    out = run("switch", BETA, "--dry-run", "--json").stdout.strip()
    print(" ", out)
    check("dry run changes nothing", "ALPHA-TOKEN" in creds.read_text())

    print("\n--- switch alpha -> beta ---")
    result = run("switch", BETA, "--json")
    print(" ", result.stdout.strip() or result.stderr.strip())
    payload = json.loads(result.stdout)

    check("switch reported ok", payload.get("ok") is True)
    check("beta token is now live", "BETA-TOKEN" in creds.read_text())
    check("live credential is 0600", oct(creds.stat().st_mode & 0o777) == "0o600",
          oct(creds.stat().st_mode & 0o777))
    check("beta's keyring copy was removed (moved, not copied)",
          secret("lookup", "omarchy-claude-account", BETA).returncode != 0)
    check("alpha was captured into the keyring",
          "ALPHA-TOKEN" in secret("lookup", "omarchy-claude-account", ALPHA).stdout)

    identity = json.loads((home / ".claude.json").read_text())
    check("identity marker followed the switch",
          identity["oauthAccount"]["accountUuid"] == "uuid-beta")
    check("rest of .claude.json preserved", identity.get("projects") == {"keep": "me"})
    check("a rollback archive was written", bool(payload.get("backup")) and Path(payload["backup"]).exists())

    status = json.loads(run("status", "--json").stdout)
    check("status reports beta active", status["activeLabel"] == BETA)

    print("\n--- switch back beta -> alpha ---")
    back = json.loads(run("switch", ALPHA, "--json").stdout)
    check("switch back ok", back.get("ok") is True)
    check("alpha token live again", "ALPHA-TOKEN" in creds.read_text())
    check("beta captured back into the keyring",
          "BETA-TOKEN" in secret("lookup", "omarchy-claude-account", BETA).stdout)
    check("alpha's keyring copy removed again",
          secret("lookup", "omarchy-claude-account", ALPHA).returncode != 0)
    check("never two live copies of one lineage",
          "ALPHA-TOKEN" not in secret("lookup", "omarchy-claude-account", BETA).stdout)

    print("\n--- guards ---")
    unknown = run("switch", "nope", "--json")
    check("unknown label refused", unknown.returncode == 2)
finally:
    for label in (ALPHA, BETA):
        secret("clear", "omarchy-claude-account", label)
    shutil.rmtree(root, ignore_errors=True)

print("\n" + ("ALL PASS" if not failures else f"FAILURES: {failures}"))
sys.exit(1 if failures else 0)
