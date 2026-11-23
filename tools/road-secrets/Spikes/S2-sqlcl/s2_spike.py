#!/usr/bin/env python3
"""Spike S2: re-saving SQLcl connections (spec section 12).

Works on roadkitdb only, through the saved connection roadkit_admin, with two
throwaway users RS_SPIKE and RS_SPIKE_TARGET. Passwords are generated here,
reach SQLcl only on standard input, and are masked in everything printed.

Usage: s2_spike.py setup|resave|bulk|discover|history|cleanup|all
"""
import os, re, secrets, subprocess, sys, time, pathlib, json

ADMIN_CONN = "roadkit_admin"
TNS_ALIAS = "roadkitdb_medium"
USER, TARGET = "RS_SPIKE", "RS_SPIKE_TARGET"
HOME = pathlib.Path.home()
STATE = pathlib.Path(os.environ.get("S2_STATE", "/private/tmp/rs_spike_state.json"))
SQL = os.environ.get("SQLCL_BIN", "sql")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
ADJ = ["Brave", "Quiet", "Amber", "Gentle", "Rapid", "Silver", "Humble", "Lively", "Mellow", "Sturdy"]
NOUN = ["Otter", "Harbor", "Lantern", "Meadow", "Pebble", "Falcon", "Garden", "Willow", "Canyon", "Thistle"]
SECRETS_SEEN: list[str] = []
LEAKS = {"raw_output_hits": 0}
ZIP = "/private/tmp/rs_spike_wallet/wallet.zip"  # roadkit_admin wallet, zipped (0600)
# feedback ON: with feedback off SQLcl hides a failed connect entirely (see visibility()).
PREFIX = "set echo off\nset feedback on\nset define off\n"


def gen() -> str:
    while True:
        p = f"{secrets.choice(ADJ)}.{secrets.choice(NOUN)}.{secrets.randbelow(1000):03d}"
        if "rs_spike" not in p.lower():
            SECRETS_SEEN.append(p)
            return p


def mask(text: str) -> str:
    for s in SECRETS_SEEN:
        text = text.replace(s, "********")
    return text


def wallet_dir() -> str:
    out = run(f"connmgr show {ADMIN_CONN}", check=False)[0]
    m = re.search(r"TNSNAMES\.ORA:\s*(\S+)/tnsnames\.ora", out)
    if not m:
        sys.exit("could not find roadkit_admin wallet directory")
    return m.group(1)


def run(body: str, check=True, tns_admin=None):
    env = dict(os.environ)
    if tns_admin:
        env["TNS_ADMIN"] = tns_admin
    script = PREFIX + body + "\nexit\n"
    t0 = time.monotonic()
    p = subprocess.run([SQL] + ([] if os.environ.get("S2_VERBOSE") else ["-S"]) + ["/nolog"], input=script, text=True, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd="/private/tmp")
    dt = time.monotonic() - t0
    raw = ANSI.sub("", p.stdout)
    LEAKS["raw_output_hits"] += sum(raw.count(x) for x in SECRETS_SEEN)
    out = mask(raw)
    failed = p.returncode != 0 or re.search(r"^(ORA-|SP2-)|\bORA-\d{5}", out, re.M)
    if check and failed:
        print(out)
        sys.exit(f"SQLcl step failed (exit {p.returncode})")
    return out, dt, p.returncode


def load():
    d = json.loads(STATE.read_text())
    SECRETS_SEEN.extend(d["seen"])
    return d


def save(d):
    d["seen"] = SECRETS_SEEN
    STATE.write_text(json.dumps(d))
    STATE.chmod(0o600)


def admin(sql: str):
    return run(f"conn -name {ADMIN_CONN}\n{sql}")


def setup():
    pw = gen()
    admin(f'''create user {USER} identified by "{pw}";
create user {TARGET} identified by "{gen()}";
grant create session to {USER};
grant create session to {TARGET};
alter user {TARGET} grant connect through {USER};''')
    w = wallet_dir()
    out, dt, _ = run(f'''conn -cloudconfig {ZIP} -save rs_spike -savepwd -replace {USER}/"{pw}"@{TNS_ALIAS}
conn -cloudconfig {ZIP} -save rs_spike_proxy -savepwd -replace {USER}[{TARGET}]/"{pw}"@{TNS_ALIAS}''')
    print(f"created users and saved rs_spike, rs_spike_proxy ({dt:.1f}s)")
    save({"pw": pw, "wallet": w, "t0": time.time()})


def whoami(name: str):
    out, _, _ = run(f"conn -name {name}\nselect user||'/'||nvl(sys_context('userenv','proxy_user'),'-') as who from dual;")
    return " ".join(l.strip() for l in out.splitlines() if "/" in l and "WHO" not in l)


def show(name: str):
    out, _, _ = run(f"connmgr show {name}")
    return next((l.split(":", 1)[1].strip() for l in out.splitlines() if l.startswith("User:")), "?")


def test(name: str):
    out, _, rc = run(f"connmgr test {name}", check=False)
    return ("ok" if rc == 0 and "ORA-" not in out and "fail" not in out.lower() else "FAIL"), out.strip()


def resave_once(name, user, pw, quoted, replace=True):
    lit = f'"{pw}"' if quoted else pw
    flag = " -replace" if replace else ""
    return run(f"conn -cloudconfig {ZIP} -save {name} -savepwd{flag} {user}/{lit}@{TNS_ALIAS}", check=False)


def resave():
    global d
    results = []
    # 0. Without -replace, does re-saving an existing name fail?
    out, _, rc = resave_once("rs_spike", USER, d["pw"], True, replace=False)
    results.append(("re-save existing name without -replace", rc, out.strip()[:200]))
    for quoted in (False, True):
        new = gen()
        admin(f'alter user {USER} identified by "{new}";')
        d["pw"] = new
        save(d)
        for name, user in (("rs_spike", USER), ("rs_spike_proxy", f"{USER}[{TARGET}]")):
            out, dt, rc = resave_once(name, user, new, quoted)
            t, tout = test(name)
            results.append((f"{name} {'quoted' if quoted else 'unquoted'}: resave rc={rc} {dt:.1f}s; "
                            f"connmgr test={t}; show User={show(name)}; who={whoami(name)}", rc, out.strip()[:200]))
    for r in results:
        print("-", r[0], "| rc", r[1], "|", r[2].replace("\n", " "))


def bulk():
    out, _, rc = resave_once("rs_spike", USER, d["pw"], True, replace=False)
    print(f"re-save an EXISTING name without -replace: rc={rc}: {' | '.join(l for l in out.splitlines() if l.strip())[:200]}")
    names = [f"rs_spike_p{i:02d}" for i in range(1, 18)]
    body = "\n".join(f'conn -cloudconfig {ZIP} -save {n} -savepwd {USER}[{TARGET}]/"{d["pw"]}"@{TNS_ALIAS}' for n in names)
    _, dt, _ = run(body)
    print(f"created 17 proxy connections in one session: {dt:.1f}s")
    new = gen()
    admin(f'alter user {USER} identified by "{new}";')
    d["pw"] = new
    save(d)
    body = "\n".join(f'conn -cloudconfig {ZIP} -save {n} -savepwd -replace {USER}[{TARGET}]/"{new}"@{TNS_ALIAS}' for n in names)
    out, dt, _ = run(body)
    print(f"re-saved 17 proxy connections in one session: {dt:.1f}s ({dt/17:.2f}s each); "
          f"estimate for 125: {dt/17*125:.0f}s")
    body = "\n".join(f"connmgr test {n}" for n in names)
    out, dt, rc = run(body, check=False)
    ok = len(re.findall(r"succe", out, re.I))
    print(f"connmgr test of 17 in one session: {dt:.1f}s, rc={rc}, success lines={ok}")
    users = {show(n) for n in names[:3]}
    print(f"sample show User values: {users}")


def discover():
    out, dt1, _ = run("connmgr list -flat")
    names = [l.strip() for l in out.splitlines() if l.strip() and not l.startswith(" ")]
    names = [n.lstrip("/") for n in names]
    body = "\n".join(f"connmgr show {n}" for n in names)
    out2, dt2, rc = run(body, check=False)
    blocks = out2.split("Name: ")[1:]
    parsed = {}
    for b in blocks:
        f = dict(l.split(":", 1) for l in ("Name:" + b).splitlines() if ":" in l)
        parsed[f["Name"].strip()] = {"user": f.get("User", "").strip(), "connect": f.get("Connect String", "").strip()}
    lh = [n for n, v in parsed.items() if v["user"].upper().startswith("LIVEHUB_DEPLOY")]
    print(f"connmgr list -flat: {dt1:.1f}s, {len(names)} names")
    print(f"connmgr show for all in one session: {dt2:.1f}s, rc={rc}, parsed {len(parsed)} blocks")
    print(f"LIVEHUB_DEPLOY connections found: {len(lh)}; by connect string: "
          f"{sorted({parsed[n]['connect'] for n in lh})}")
    from collections import Counter
    print("LIVEHUB_DEPLOY by database and kind:", dict(Counter(
        (parsed[n]["connect"], "proxy" if "[" in parsed[n]["user"] else "direct") for n in lh)))
    print("sample users:", sorted({parsed[n]["user"] for n in lh})[:4])
    missing = set(names) - set(parsed)
    print(f"names with no parsed block: {sorted(missing)[:10]}")


def history():
    t0 = d["t0"]
    hits, scanned = [], 0
    roots = [HOME / ".sqlcl", HOME / ".dbtools", pathlib.Path("/private/tmp"),
             pathlib.Path(os.environ.get("TMPDIR", "/private/tmp")), HOME / "Library/Logs"]
    needles = [s.encode() for s in SECRETS_SEEN]
    for r in roots:
        if not r.exists():
            continue
        for p in r.rglob("*"):
            try:
                if not p.is_file() or p.stat().st_mtime < t0 - 5 or p.stat().st_size > 50_000_000 or p == STATE:
                    continue
                scanned += 1
                b = p.read_bytes()
                if any(n in b for n in needles):
                    hits.append(str(p))
            except (PermissionError, OSError):
                pass
    out, _, _ = run("history full", check=False)
    in_hist = any(s in out for s in SECRETS_SEEN)  # out is masked, so test unmasked count below
    raw = subprocess.run([SQL, "-S", "/nolog"], input="history full\nexit\n", text=True,
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd="/private/tmp").stdout
    print(f"files changed since start scanned: {scanned}; containing a spike password: {hits or 'none'}")
    print(f"SQLcl 'history full' contains a spike password: {any(s in raw for s in SECRETS_SEEN)}")


def cleanup():
    names = ["rs_spike", "rs_spike_proxy"] + [f"rs_spike_p{i:02d}" for i in range(1, 18)]
    run("\n".join(f"connmgr delete -conn {n}" for n in names), check=False)
    run(f"conn -name {ADMIN_CONN}\ndrop user {TARGET} cascade;\ndrop user {USER} cascade;", check=False)
    out, _, _ = run("connmgr list -flat")
    left = [l for l in out.splitlines() if "rs_spike" in l]
    out2, _, _ = run(f"conn -name {ADMIN_CONN}\nselect 'LEFT='||count(*) from dba_users where username like 'RS%SPIKE%';")
    print(f"connections left: {left or 'none'}; users left: {re.search(r'LEFT=(\d+)', out2).group(1)}")
    STATE.unlink(missing_ok=True)


def visibility():
    """Does a failed connect show up under the spec's prefix lines?"""
    global PREFIX
    bad = gen()
    for label, pre in [("echo off, feedback off (spec)", "set echo off\nset feedback off\nset define off\n"),
                       ("echo off, feedback on", "set echo off\nset feedback on\nset define off\n"),
                       ("echo on, feedback off", "set echo on\nset feedback off\nset define off\n")]:
        PREFIX = pre
        out, dt, rc = run(f'conn -cloudconfig {ZIP} {USER}/"{bad}"@{TNS_ALIAS}\nshow user', check=False)
        print(f"- wrong password, {label}: rc={rc}, output: {' | '.join(l for l in out.splitlines() if l.strip())[:220]}")
    PREFIX = "set echo off\nset feedback off\nset define off\n"


def probe():
    """Show SQLcl's full output for one save and one admin check."""
    out, dt, rc = run(f'conn -save rs_spike -savepwd {USER}/"{d["pw"]}"@{TNS_ALIAS}\nshow user\nconnmgr list -flat',
                      check=False, tns_admin=d["wallet"])
    print(f"--- save rc={rc} {dt:.1f}s\n{out}")
    out, dt, rc = run(f"conn -name {ADMIN_CONN}\nselect username, account_status from dba_users where username like 'RS%SPIKE%';\n"
                      f"select proxy, client from proxy_users where client like 'RS%';", check=False)
    print(f"--- admin rc={rc} {dt:.1f}s\n{out}")


def probe2():
    """Variants of a plain connect, to find why the save fails silently."""
    w = d["wallet"]
    zipf = "/private/tmp/rs_spike_wallet/wallet.zip"
    desc = ("(description=(retry_count=1)(retry_delay=1)(address=(protocol=tcps)(port=1522)(host=adb.uk-cardiff-1.oraclecloud.com))"
            "(connect_data=(service_name=geb0d0f36a9a4b0_roadkitdb_medium.adb.oraclecloud.com))"
            f"(security=(ssl_server_dn_match=yes)(my_wallet_directory={w})))")
    for label, body, tns in [
        ("cloudconfig zip", f'set echo on\nconn -cloudconfig {zipf} {USER}/"{d["pw"]}"@{TNS_ALIAS}\nshow user', None),
        ("descriptor with my_wallet_directory", f'set echo on\nconn {USER}/"{d["pw"]}"@"{desc}"\nshow user', None),
    ]:
        out, dt, rc = run(body, check=False, tns_admin=tns)
        print(f"--- {label}: rc={rc} {dt:.1f}s\n{out.strip()[:600]}")


if __name__ == "__main__":
    step = sys.argv[1] if len(sys.argv) > 1 else ""
    if step == "setup":
        setup()
    elif step in ("resave", "bulk", "discover", "history", "cleanup", "probe", "probe2", "visibility"):
        d = load()
        globals()[step]()
        print(f"password occurrences in raw SQLcl output this step: {LEAKS['raw_output_hits']}")
    else:
        sys.exit(__doc__)

