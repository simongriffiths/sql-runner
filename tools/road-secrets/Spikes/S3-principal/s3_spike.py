#!/usr/bin/env python3
"""Spike S3: pipe a new password into road-kit's bin/set-principal-password.sh.

Generates an Adjective.Noun.nnn password, sends it twice on standard input
(not a terminal), writes it into ROAD_TEST_PASSWORD in config/local.env, then
proves a login with bin/get-test-token.sh. Never prints the password.
"""
import os, re, secrets, subprocess, sys, pathlib, shlex

ROOT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/Users/simon/Projects/road-kit")
ENV_FILE = ROOT / "config/local.env"
ADJ = ["Brave", "Quiet", "Amber", "Gentle", "Rapid", "Silver", "Humble", "Lively", "Mellow", "Sturdy"]
NOUN = ["Otter", "Harbor", "Lantern", "Meadow", "Pebble", "Falcon", "Garden", "Willow", "Canyon", "Thistle"]


def env_value(text, key):
    m = re.search(rf"^(?:export\s+)?{key}=(.*)$", text, re.M)
    return shlex.split(m.group(1))[0] if m and m.group(1).strip() else None


text = ENV_FILE.read_text()
subject = env_value(text, "ROAD_TEST_USERNAME") or "ADMIN"
while True:
    pw = f"{secrets.choice(ADJ)}.{secrets.choice(NOUN)}.{secrets.randbelow(1000):03d}"
    if subject.lower() not in pw.lower():
        break
mask = lambda s: s.replace(pw, "********")

p = subprocess.run([str(ROOT / "bin/set-principal-password.sh"), "--env", "dev", "--subject", subject],
                   input=f"{pw}\n{pw}\n", text=True, cwd=ROOT,
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
print(f"set-principal-password.sh --env dev --subject {subject}: exit {p.returncode}")
print(mask(p.stdout).strip()[-1500:])
if p.returncode != 0:
    sys.exit("stopped: password not set, config/local.env unchanged")

lines = text.splitlines(keepends=True)
n = 0
for i, l in enumerate(lines):
    m = re.match(r"^(export\s+)?ROAD_TEST_PASSWORD=.*?(\r?\n)?$", l)
    if m:
        lines[i] = f"{m.group(1) or ''}ROAD_TEST_PASSWORD='{pw}'{m.group(2) or ''}"
        n += 1
if n != 1:
    sys.exit(f"stopped: found {n} ROAD_TEST_PASSWORD lines; password IS set, write it in by hand")
new = "".join(lines)
tmp = ENV_FILE.with_suffix(".env.tmp")
tmp.write_text(new)
os.chmod(tmp, ENV_FILE.stat().st_mode & 0o777)
os.replace(tmp, ENV_FILE)
changed = [i for i, (a, b) in enumerate(zip(text.splitlines(), new.splitlines())) if a != b]
print(f"config/local.env: lines changed {len(changed)} (line {changed[0] + 1}), line count "
      f"{len(text.splitlines())} -> {len(new.splitlines())}")

cmd = f"set -a; source {shlex.quote(str(ENV_FILE))}; set +a; exec bin/get-test-token.sh --env dev"
t = subprocess.run(["bash", "-c", cmd], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
tok = t.stdout.strip()
print(f"get-test-token.sh --env dev: exit {t.returncode}; token returned: "
      f"{'yes, ' + str(len(tok)) + ' chars, ' + str(tok.count('.')) + ' dots' if tok else 'no'}")
if t.stderr.strip():
    print("stderr:", mask(t.stderr).strip()[-800:])
