#!/usr/bin/env python3
"""
AML monitoring prototype: synthetic data generator.

Produces seven JSONL files matching data_contract.md, with four labelled
suspicious patterns injected into otherwise normal activity.

Usage:
    python generate_data.py --scale small     ~50k transactions
    python generate_data.py --scale medium    ~500k transactions
    python generate_data.py --scale full      ~2M transactions
    python generate_data.py --scale small --out ./data --seed 42

Output lands in --out (default ./data), one .jsonl file per entity.
Validation runs automatically and the script exits non-zero if it fails.
"""

import argparse
import gzip
import json
import random
import sys
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

# ---------------------------------------------------------------------
# Scale presets. Ratios roughly hold across all three.
# ---------------------------------------------------------------------
SCALES = {
    "tiny":   dict(customers=60,     accounts_per=1.2, devices=40,     ips=50,
                   sessions=300,     transactions=500),
    "small":  dict(customers=2_000,  accounts_per=1.8, devices=2_500,  ips=3_000,
                   sessions=20_000,  transactions=50_000),
    "medium": dict(customers=10_000, accounts_per=1.8, devices=12_000, ips=15_000,
                   sessions=100_000, transactions=500_000),
    "full":   dict(customers=20_000, accounts_per=1.8, devices=25_000, ips=30_000,
                   sessions=200_000, transactions=2_000_000),
}

SUSPICIOUS_RATE = 0.0075          # target share of transactions that are injected
BUSINESS_SHARE  = 0.15
TTR_THRESHOLD   = 10_000.00       # AUSTRAC threshold the structuring pattern evades

BASE = datetime(2026, 1, 1)
WINDOW_DAYS = 120

BRANCHES = [f"BRN-{i:04d}" for i in range(1, 51)]
FIRST = ["Alex", "Priya", "Wei", "Mia", "Omar", "Sofia", "Liam", "Aisha", "Noah",
         "Zara", "Hugo", "Lena", "Rohan", "Isla", "Kai", "Nina", "Tom", "Ava"]
LAST = ["Nguyen", "Smith", "Patel", "Chen", "Haddad", "Rossi", "Brown", "Khan",
        "Garcia", "Okafor", "Tran", "Walker", "Silva", "Kim", "Murphy"]
SUFFIX = ["Trading", "Logistics", "Holdings", "Imports", "Services", "Group"]
OCCUPATIONS = ["registered nurse", "software engineer", "teacher", "electrician",
               "accountant", "retail assistant", "driver", "chef", "plumber"]
ANZSIC = ["4712", "7000", "3011", "5621", "6920", "4521", "8401"]
STREETS = ["King", "Pitt", "Elizabeth", "George", "Castlereagh", "Sussex"]
CITIES = [("Sydney", "NSW", "2000"), ("Melbourne", "VIC", "3000"),
          ("Brisbane", "QLD", "4000"), ("Perth", "WA", "6000")]

DIGITAL_CHANNELS = ["netbank", "mobile", "payid", "osko"]
CASH_CHANNELS = ["branch", "atm"]


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%SZ")


def day(d):
    return d.strftime("%Y-%m-%d")


def rand_dt(rng, start_offset=0, span=WINDOW_DAYS):
    return BASE + timedelta(days=rng.randint(start_offset, span),
                            hours=rng.randint(0, 23),
                            minutes=rng.randint(0, 59),
                            seconds=rng.randint(0, 59))


# =====================================================================
# Entity builders. Generation order follows the foreign keys.
# =====================================================================

def build_customers(rng, n):
    """CUSTOMER. kyc_payload shape deliberately differs by customer_type."""
    rows = []
    n_business = int(n * BUSINESS_SHARE)
    for i in range(1, n + 1):
        cid = f"CUS-{i:06d}"
        business = i > (n - n_business)
        onboard = BASE - timedelta(days=rng.randint(15, 2200))
        city, state, pc = rng.choice(CITIES)

        if business:
            name = f"{rng.choice(LAST)} {rng.choice(SUFFIX)} Pty Ltd"
            payload = {
                "abn": str(rng.randint(10**10, 10**11 - 1)),
                "trading_name": name.replace(" Pty Ltd", ""),
                "entity_type": rng.choice(["pty_ltd", "sole_trader", "trust"]),
                "directors": [
                    {"name": f"{rng.choice(FIRST)} {rng.choice(LAST)}", "role": "director"}
                    for _ in range(rng.randint(1, 3))
                ],
                "registered_office": f"{rng.randint(1, 300)} {rng.choice(STREETS)} St, {city} {state} {pc}",
                "anzsic_code": rng.choice(ANZSIC),
                "expected_turnover_aud": rng.choice([250_000, 450_000, 1_200_000, 3_100_000]),
                "source_of_funds": "trading_revenue",
            }
        else:
            name = f"{rng.choice(FIRST)} {rng.choice(LAST)}"
            docs = [{"type": "passport", "country": "AU",
                     "expiry": f"{rng.randint(2029, 2035)}-{rng.randint(1,12):02d}-{rng.randint(1,28):02d}"}]
            if rng.random() > 0.4:
                docs.append({"type": "drivers_licence", "state": state})
            payload = {
                "identity_documents": docs,
                "source_of_funds": rng.choice(["salary", "savings", "investment"]),
                "employer": f"{rng.choice(LAST)} {rng.choice(SUFFIX)}",
                "pep_flag": rng.random() < 0.02,
            }

        rows.append({
            "customer_id": cid,
            "customer_type": "business" if business else "retail",
            "full_name": name,
            "date_of_birth": None if business
                             else day(BASE - timedelta(days=rng.randint(6600, 23000))),
            "nationality": rng.choice(["AU"] * 7 + ["NZ", "IN", "CN", "GB", "PH"]),
            "email": f"user{i}@example.com",
            "phone": f"04{rng.randint(10_000_000, 99_999_999)}",
            "address": f"{rng.randint(1, 300)} {rng.choice(STREETS)} St, {city} {state} {pc}",
            "occupation_or_industry": rng.choice(ANZSIC) if business
                                      else rng.choice(OCCUPATIONS),
            "declared_income_aud": round(rng.uniform(42_000, 210_000), 2),
            "kyc_status": rng.choice(["verified"] * 9 + ["pending"]),
            "risk_rating": rng.choice(["low"] * 7 + ["medium"] * 2 + ["high"]),
            "onboard_dt": day(onboard),
            "status": "active",
            "created_at": iso(onboard),
            "kyc_payload": payload,
        })
    return rows


def build_accounts(rng, customers, accounts_per):
    rows, seq = [], 0
    for c in customers:
        for _ in range(max(1, int(rng.gauss(accounts_per, 0.6)))):
            seq += 1
            opened = datetime.strptime(c["onboard_dt"], "%Y-%m-%d") + \
                     timedelta(days=rng.randint(0, 30))
            rows.append({
                "account_id": f"ACC-{seq:06d}",
                "customer_id": c["customer_id"],
                "account_number": f"0620{rng.randint(10,99)} {rng.randint(10_000_000, 99_999_999)}",
                "account_type": "business" if c["customer_type"] == "business"
                                else rng.choice(["transaction", "transaction", "savings", "offset"]),
                "currency": "AUD",
                "balance": round(rng.uniform(50, 180_000), 2),
                "status": "active",
                "open_date": day(opened),
                "branch_code": rng.choice(BRANCHES),
            })
    return rows


def build_devices(rng, n):
    return [{
        "device_id": f"DEV-{i:06d}",
        "device_fingerprint": "".join(rng.choice("0123456789abcdef") for _ in range(32)),
        "device_type": rng.choice(["mobile", "mobile", "mobile", "desktop", "tablet"]),
        "os": rng.choice(["iOS 18.2", "iOS 19.0", "Android 15", "Android 16",
                          "macOS 15.3", "Windows 11"]),
        "first_seen": iso(BASE - timedelta(days=rng.randint(30, 500))),
        "last_seen": iso(rand_dt(rng)),
    } for i in range(1, n + 1)]


def build_ips(rng, n):
    """Roughly 10 percent VPN. These are the decoys the shared-IP view filters out."""
    rows = []
    for i in range(1, n + 1):
        vpn = rng.random() < 0.10
        city, state, pc = rng.choice(CITIES)
        rows.append({
            "ip_id": f"IP-{i:06d}",
            "ip_address": f"{rng.choice([203, 198, 110, 60])}.{rng.randint(0,255)}."
                          f"{rng.randint(0,255)}.{rng.randint(1,254)}",
            "country": rng.choice(["AU"] * 8 + ["SG", "NZ", "US"]),
            "city": city,
            "is_vpn": vpn,
            "risk_score": round(rng.uniform(55, 95) if vpn else rng.uniform(0, 40), 2),
        })
    return rows


def build_sessions(rng, n, account_ids, devices, ips):
    """Devices and private IPs are OWNED, not assigned at random.

    Random assignment makes every device look shared by a dozen customers,
    which buries the mule-ring signal in noise. Here each account gets its
    own device and its own private IP. A small share of sessions crosses
    over (household sharing, public wifi), which is what gives the
    detection queries a realistic false positive rate to measure.
    """
    dev_ids = [d["device_id"] for d in devices]
    private_ips = [p["ip_id"] for p in ips if not p["is_vpn"]]
    shared_ips = [p["ip_id"] for p in ips if p["is_vpn"]] or private_ips[:1]

    # one primary device and one primary IP per account
    acct_device = {a: dev_ids[i % len(dev_ids)] for i, a in enumerate(account_ids)}
    acct_ip = {a: private_ips[i % len(private_ips)] for i, a in enumerate(account_ids)}

    rows = []
    for i in range(1, n + 1):
        acct = rng.choice(account_ids)
        roll = rng.random()
        if roll < 0.03:
            device = rng.choice(dev_ids)          # household or borrowed device
        else:
            device = acct_device[acct]
        roll = rng.random()
        if roll < 0.12:
            ip = rng.choice(shared_ips)           # VPN or carrier NAT, filtered by the view
        elif roll < 0.17:
            ip = rng.choice(private_ips)          # travelling, cafe wifi
        else:
            ip = acct_ip[acct]
        rows.append({
            "session_id": f"SES-{i:07d}",
            "account_id": acct,
            "device_id": device,
            "ip_id": ip,
            "session_time": iso(rand_dt(rng)),
            "channel": rng.choice(["app", "app", "netbank"]),
            "auth_method": rng.choice(["biometric", "password", "mfa"]),
        })
    return rows


# =====================================================================
# Transactions: noise first, then the four injected patterns.
# =====================================================================

class TxnWriter:
    """Accumulates transactions and their ground-truth labels in step."""

    def __init__(self):
        self.txns = []
        self.truth = []
        self.seq = 0

    def add(self, *, account_id, counterparty, amount, when, txn_type, channel,
            branch=None, session=None, label="normal", chain=None, hop=None,
            description="payment"):
        self.seq += 1
        tid = f"TRX-{self.seq:09d}"
        self.txns.append({
            "transaction_id": tid,
            "account_id": account_id,
            "counterparty_account_id": counterparty,
            "session_id": session,
            "txn_time": iso(when),
            "amount": round(amount, 2),
            "currency": "AUD",
            "txn_type": txn_type,
            "channel": channel,
            "branch_code": branch,
            "description": description,
            "status": "completed",
        })
        self.truth.append({
            "transaction_id": tid,
            "pattern_label": label,
            "chain_id": chain,
            "hop_index": hop,
        })
        return tid


def add_noise(rng, w, n, account_ids, session_ids):
    """Ordinary activity. Cash deposits stay well clear of the TTR threshold
    so that a structuring detector does not fire on normal behaviour."""
    for _ in range(n):
        when = rand_dt(rng)
        roll = rng.random()
        if roll < 0.15:
            w.add(account_id=None, counterparty=rng.choice(account_ids),
                  amount=rng.uniform(50, 4_500), when=when,
                  txn_type="cash_deposit", channel="branch",
                  branch=rng.choice(BRANCHES), description="deposit")
        elif roll < 0.27:
            w.add(account_id=rng.choice(account_ids), counterparty=None,
                  amount=rng.uniform(20, 1_200), when=when,
                  txn_type="cash_withdrawal", channel="atm",
                  branch=rng.choice(BRANCHES), description="withdrawal")
        elif roll < 0.36:
            a, b = rng.sample(account_ids, 2)
            w.add(account_id=a, counterparty=b, amount=rng.uniform(15, 2_000),
                  when=when, txn_type="direct_debit", channel="netbank",
                  session=rng.choice(session_ids), description="direct debit")
        else:
            a, b = rng.sample(account_ids, 2)
            w.add(account_id=a, counterparty=b, amount=rng.uniform(10, 9_000),
                  when=when, txn_type="transfer", channel=rng.choice(DIGITAL_CHANNELS),
                  session=rng.choice(session_ids), description="transfer")


def inject_structuring(rng, w, account_ids, n_chains, chain_no):
    """Cash deposits held under the TTR threshold, spread across branches and days.
    Detected by: window aggregation plus COUNT(DISTINCT branch_code) >= 2."""
    for _ in range(n_chains):
        target = rng.choice(account_ids)
        deposits = rng.randint(6, 15)
        branches = rng.sample(BRANCHES, rng.randint(2, 4))
        start = rand_dt(rng, span=WINDOW_DAYS - 10)
        chain = f"CHN-{chain_no[0]:06d}"
        chain_no[0] += 1
        for i in range(deposits):
            w.add(account_id=None, counterparty=target,
                  amount=rng.uniform(TTR_THRESHOLD * 0.72, TTR_THRESHOLD * 0.98),
                  when=start + timedelta(days=i // 2, hours=rng.randint(9, 16)),
                  txn_type="cash_deposit", channel="branch",
                  branch=branches[i % len(branches)], description="deposit",
                  label="structuring", chain=chain, hop=i)


def inject_layering(rng, w, account_ids, session_ids, acct_owner, n_chains, chain_no):
    """A to B to C ... 4 to 8 hops, decaying amounts, short intervals.
    Detected by: recursive CTE. Hops use distinct customers so the
    own-account exclusion in the traversal does not filter the chain out."""
    for _ in range(n_chains):
        depth = rng.randint(4, 8)
        hops = pick_distinct_owner_chain(rng, account_ids, acct_owner, depth + 1)
        if not hops:
            continue
        chain = f"CHN-{chain_no[0]:06d}"
        chain_no[0] += 1
        amount = rng.uniform(60_000, 220_000)
        t = rand_dt(rng, span=WINDOW_DAYS - 5)
        for i in range(depth):
            w.add(account_id=hops[i], counterparty=hops[i + 1], amount=amount,
                  when=t, txn_type="transfer", channel=rng.choice(["osko", "payid"]),
                  session=rng.choice(session_ids), description="transfer",
                  label="layering_chain", chain=chain, hop=i)
            amount *= rng.uniform(0.86, 0.97)
            t += timedelta(hours=rng.randint(2, 20))


def inject_round_trip(rng, w, account_ids, session_ids, acct_owner, n_chains, chain_no):
    """Funds leave an account and return through intermediaries.
    Detected by: recursive CTE where the path returns to its origin."""
    for _ in range(n_chains):
        depth = rng.randint(3, 6)
        hops = pick_distinct_owner_chain(rng, account_ids, acct_owner, depth)
        if not hops:
            continue
        ring = hops + [hops[0]]
        chain = f"CHN-{chain_no[0]:06d}"
        chain_no[0] += 1
        amount = rng.uniform(40_000, 140_000)
        t = rand_dt(rng, span=WINDOW_DAYS - 8)
        for i in range(depth):
            w.add(account_id=ring[i], counterparty=ring[i + 1], amount=amount,
                  when=t, txn_type="transfer", channel="osko",
                  session=rng.choice(session_ids), description="transfer",
                  label="round_trip", chain=chain, hop=i)
            amount *= rng.uniform(0.95, 0.99)
            t += timedelta(hours=rng.randint(6, 36))


def inject_mule_network(rng, w, customers, accounts, sessions, devices, ips,
                        account_ids, n_rings, chain_no):
    """Recently onboarded customers sharing one device and one non-VPN IP,
    each showing rapid in-and-out. Detected by: V_SHARED_DEVICE_LINK joined
    to recent open_date, plus pass-through timing."""
    by_customer = {}
    for a in accounts:
        by_customer.setdefault(a["customer_id"], []).append(a)
    recent = [c for c in customers
              if c["customer_type"] == "retail"
              and datetime.strptime(c["onboard_dt"], "%Y-%m-%d") > BASE - timedelta(days=120)]
    clean_ips = [p["ip_id"] for p in ips if not p["is_vpn"]]
    if len(recent) < 3 or not clean_ips:
        return

    sess_seq = 9_000_000
    for _ in range(n_rings):
        size = rng.randint(3, 8)
        if len(recent) < size:
            break
        ring = rng.sample(recent, size)
        device = rng.choice(devices)["device_id"]
        ip = rng.choice(clean_ips)
        chain = f"CHN-{chain_no[0]:06d}"
        chain_no[0] += 1
        t0 = rand_dt(rng, span=WINDOW_DAYS - 3)

        for n, c in enumerate(ring):
            acct = by_customer[c["customer_id"]][0]["account_id"]
            sess_seq += 1
            sid = f"SES-{sess_seq:07d}"
            sessions.append({
                "session_id": sid,
                "account_id": acct,
                "device_id": device,
                "ip_id": ip,
                "session_time": iso(t0 + timedelta(hours=n)),
                "channel": "app",
                "auth_method": "password",
            })
            inflow = rng.uniform(12_000, 28_000)
            w.add(account_id=rng.choice(account_ids), counterparty=acct,
                  amount=inflow, when=t0 + timedelta(hours=n),
                  txn_type="transfer", channel="osko", session=sid,
                  description="transfer", label="mule_network", chain=chain, hop=0)
            w.add(account_id=acct, counterparty=None,
                  amount=inflow * rng.uniform(0.93, 0.99),
                  when=t0 + timedelta(hours=n + rng.randint(2, 10)),
                  txn_type="cash_withdrawal", channel="atm",
                  branch=rng.choice(BRANCHES), description="withdrawal",
                  label="mule_network", chain=chain, hop=1)


def pick_distinct_owner_chain(rng, account_ids, acct_owner, length, attempts=40):
    """Pick `length` accounts that all belong to different customers."""
    for _ in range(attempts):
        picks = rng.sample(account_ids, min(length * 2, len(account_ids)))
        seen, chain = set(), []
        for a in picks:
            owner = acct_owner[a]
            if owner in seen:
                continue
            seen.add(owner)
            chain.append(a)
            if len(chain) == length:
                return chain
    return None


# =====================================================================
# Validation
# =====================================================================

def validate(data):
    errors = []
    cus = {c["customer_id"] for c in data["customers"]}
    acc = {a["account_id"] for a in data["accounts"]}
    dev = {d["device_id"] for d in data["devices"]}
    ips = {p["ip_id"] for p in data["ip_addresses"]}
    ses = {s["session_id"] for s in data["sessions"]}

    for a in data["accounts"]:
        if a["customer_id"] not in cus:
            errors.append(f"ACCOUNT {a['account_id']} -> missing customer")
    for s in data["sessions"]:
        if s["account_id"] not in acc:
            errors.append(f"SESSION {s['session_id']} -> missing account")
        if s["device_id"] not in dev:
            errors.append(f"SESSION {s['session_id']} -> missing device")
        if s["ip_id"] not in ips:
            errors.append(f"SESSION {s['session_id']} -> missing ip")
    for t in data["transactions"]:
        for f in ("account_id", "counterparty_account_id"):
            if t[f] is not None and t[f] not in acc:
                errors.append(f"TRANSACTION {t['transaction_id']} -> missing {f}")
        if t["session_id"] is not None and t["session_id"] not in ses:
            errors.append(f"TRANSACTION {t['transaction_id']} -> missing session")

        # null rules from data_contract.md
        if t["txn_type"] == "cash_deposit" and t["account_id"] is not None:
            errors.append(f"{t['transaction_id']}: cash_deposit must have null account_id")
        if t["txn_type"] == "cash_withdrawal" and t["counterparty_account_id"] is not None:
            errors.append(f"{t['transaction_id']}: cash_withdrawal must have null counterparty")
        if t["channel"] in CASH_CHANNELS and t["branch_code"] is None:
            errors.append(f"{t['transaction_id']}: cash channel needs branch_code")
        if t["channel"] not in CASH_CHANNELS and t["branch_code"] is not None:
            errors.append(f"{t['transaction_id']}: digital channel must have null branch_code")

    tx = {t["transaction_id"] for t in data["transactions"]}
    gt = {g["transaction_id"] for g in data["ground_truth"]}
    if tx != gt:
        errors.append(f"ground truth mismatch: {len(tx - gt)} unlabelled, {len(gt - tx)} orphaned")

    # the document-model argument depends on these shapes actually differing
    retail = next((c["kyc_payload"] for c in data["customers"]
                   if c["customer_type"] == "retail"), None)
    business = next((c["kyc_payload"] for c in data["customers"]
                     if c["customer_type"] == "business"), None)
    if retail and business and set(retail) == set(business):
        errors.append("kyc_payload shapes are identical across customer types")

    return errors


# =====================================================================

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scale", choices=SCALES, default="small")
    ap.add_argument("--out", default="./data")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--gzip", action="store_true",
                    help="write .jsonl.gz instead of .jsonl; roughly 10x smaller "
                         "and COPY INTO reads it transparently")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cfg = SCALES[args.scale]
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    print(f"scale={args.scale} seed={args.seed} out={out}")

    customers = build_customers(rng, cfg["customers"])
    accounts = build_accounts(rng, customers, cfg["accounts_per"])
    devices = build_devices(rng, cfg["devices"])
    ip_rows = build_ips(rng, cfg["ips"])

    account_ids = [a["account_id"] for a in accounts]
    acct_owner = {a["account_id"]: a["customer_id"] for a in accounts}
    sessions = build_sessions(rng, cfg["sessions"], account_ids, devices, ip_rows)
    session_ids = [s["session_id"] for s in sessions]

    target = cfg["transactions"]
    suspicious_budget = int(target * SUSPICIOUS_RATE)

    # split the budget across the four patterns by typical transactions each emits
    n_structuring = max(1, suspicious_budget // 4 // 10)
    n_layering    = max(1, suspicious_budget // 4 // 6)
    n_roundtrip   = max(1, suspicious_budget // 4 // 4)
    n_mule        = max(1, suspicious_budget // 4 // 10)

    w = TxnWriter()
    chain_no = [1]

    add_noise(rng, w, target - suspicious_budget, account_ids, session_ids)
    inject_structuring(rng, w, account_ids, n_structuring, chain_no)
    inject_layering(rng, w, account_ids, session_ids, acct_owner, n_layering, chain_no)
    inject_round_trip(rng, w, account_ids, session_ids, acct_owner, n_roundtrip, chain_no)
    inject_mule_network(rng, w, customers, accounts, sessions, devices, ip_rows,
                        account_ids, n_mule, chain_no)

    # mule injection appends sessions, so refresh the id list before writing
    data = {
        "customers": customers,
        "accounts": accounts,
        "devices": devices,
        "ip_addresses": ip_rows,
        "sessions": sessions,
        "transactions": w.txns,
        "ground_truth": w.truth,
    }

    errors = validate(data)
    if errors:
        print(f"\nVALIDATION FAILED: {len(errors)} problems")
        for e in errors[:20]:
            print("  ", e)
        sys.exit(1)

    ext = ".jsonl.gz" if args.gzip else ".jsonl"
    opener = (lambda p: gzip.open(p, "wt")) if args.gzip else (lambda p: open(p, "w"))
    for name, rows in data.items():
        path = out / f"{name}{ext}"
        with opener(path) as f:
            for r in rows:
                f.write(json.dumps(r) + "\n")
        mb = path.stat().st_size / 1048576
        print(f"  {name + ext:28s} {len(rows):>10,}  {mb:7.1f} MB")

    labels = Counter(t["pattern_label"] for t in w.truth)
    total = len(w.truth)
    print("\ninjected patterns")
    for k, v in sorted(labels.items(), key=lambda x: -x[1]):
        print(f"  {k:18s} {v:>9,}  {v / total * 100:5.2f}%")
    chains = len({t['chain_id'] for t in w.truth if t['chain_id']})
    print(f"\n  distinct chains: {chains}")
    print("validation passed")


if __name__ == "__main__":
    main()
