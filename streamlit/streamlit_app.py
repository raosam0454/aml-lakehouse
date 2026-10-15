# streamlit_app.py : AML dashboards (Streamlit in Snowflake)
# Reads the SERVING views and CURATED.FRAUD_ALERT built by detection.sql + alerts.sql.

import altair as alt
import pandas as pd
import streamlit as st

try:
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
except Exception:
    session = st.connection("snowflake").session()

st.set_page_config(page_title="AML ring detection", layout="wide")
st.title("AML ring detection")
st.caption("Synthetic data · detections from detection.sql / alerts.sql")

# display names
PATTERNS = {
    "round_trip":               "Round-trip",
    "round_trip_shared_device": "Round-trip · shared device",
    "round_trip_phone_link":    "Round-trip · phone link",
    "round_trip_sub_threshold": "Round-trip · sub-threshold",
    "layering_chain":           "Layering chain",
    "mule_network":             "Mule network",
    "structuring":              "Structuring",
}
DETECTORS = {
    "round_trip (detector)":  "round_trip",
    "layering (detector)":    "layering_chain",
    "mule (detector)":        "mule_network",
    "structuring (detector)": "structuring",
}
CLOSED_BY = {"same_account": "Same account", "linked_phone": "Linked · phone",
             "linked_email": "Linked · email", "linked_device": "Linked · device"}
TIER_SCALE = alt.Scale(domain=["High", "Medium"], range=["#e05252", "#f2a93b"])
OUTCOME_SCALE = alt.Scale(domain=["Found", "Partial", "Missed"],
                          range=["#3fa66b", "#f2a93b", "#e05252"])


def name(x):
    return PATTERNS.get(x, str(x).replace("_", " ").capitalize())


def tier(x):
    return str(x).capitalize() if isinstance(x, str) and x else "—"


def q(sql: str) -> pd.DataFrame:
    """Run a query and return a pandas frame (Snowflake NUMBER -> float)."""
    df = session.sql(sql).to_pandas()
    for col in df.columns:
        if df[col].dtype == object:
            try:
                df[col] = pd.to_numeric(df[col])
            except (ValueError, TypeError):
                pass
    return df


def hbar(df, y, x, color=None, scale=None, order=None):
    """Horizontal bar chart, stacked by `color` if given."""
    enc = {
        "y": alt.Y(f"{y}:N", title=None, sort=order or "-x",
                   axis=alt.Axis(labelLimit=260)),
        "x": alt.X(f"sum({x}):Q", title=None, axis=alt.Axis(format="d", tickMinStep=1)),
        "tooltip": [alt.Tooltip(f"{c}:{'Q' if c == x else 'N'}") for c in df.columns],
    }
    if color:
        enc["color"] = alt.Color(f"{color}:N", scale=scale,
                                 legend=alt.Legend(orient="bottom", title=None))
    st.altair_chart(alt.Chart(df).mark_bar(size=22).encode(**enc).properties(height=alt.Step(36)),
                    use_container_width=True)


def table(df, money=(), pct=(), pct0=()):
    """Read-only table with thousands separators and no index."""
    fmt = {c: "{:,.0f}" for c in money}
    fmt.update({c: "{:.1f}%" for c in pct})
    fmt.update({c: "{:.0f}%" for c in pct0})
    st.dataframe(df.style.format(fmt, na_rep="—"), use_container_width=True, hide_index=True)


summary = q("SELECT alert_type, tier, alerts FROM AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY")
summary["Type"] = summary["ALERT_TYPE"].map(name)
summary["Tier"] = summary["TIER"].map(tier)
summary["Alerts"] = summary["ALERTS"].astype(int)

tab1, tab2, tab3, tab4 = st.tabs(
    ["1 · Money rings & layering (P1)", "2 · Shared identity & mule (P2)",
     "3 · Alert queue", "4 · Detection quality (evaluation)"])

# Dashboard 1: money rings and layering chains
with tab1:
    rings = q("""SELECT alert_id, tier, closed_by, hops, path,
                        first_amount, last_amount, decay_pct
                 FROM AML_PROTOTYPE.SERVING.V_DASH_RINGS""")
    rings["Type"] = rings["CLOSED_BY"].map(lambda c: "Round-trip" if isinstance(c, str) else "Layering chain")
    p1 = summary[summary["ALERT_TYPE"].isin(["round_trip", "layering_chain"])]

    c1, c2, c3 = st.columns(3)
    c1.metric("Round-trips", int(p1.loc[p1["ALERT_TYPE"] == "round_trip", "Alerts"].sum()))
    c2.metric("…of which high (P1+P2)",
              int(p1.loc[(p1["ALERT_TYPE"] == "round_trip") & (p1["Tier"] == "High"), "Alerts"].sum()))
    c3.metric("Layering chains", int(p1.loc[p1["ALERT_TYPE"] == "layering_chain", "Alerts"].sum()))

    left, right = st.columns(2)
    with left:
        st.subheader("Detections by type and tier")
        hbar(p1[["Type", "Tier", "Alerts"]], "Type", "Alerts", "Tier", TIER_SCALE)
    with right:
        st.subheader("Ring / chain length (hops)")
        hops = rings.groupby(["HOPS", "Type"]).size().reset_index(name="Count")
        st.altair_chart(
            alt.Chart(hops).mark_bar().encode(
                x=alt.X("HOPS:O", title="Hops", axis=alt.Axis(labelAngle=0)),
                y=alt.Y("Count:Q", title=None, axis=alt.Axis(format="d", tickMinStep=1)),
                color=alt.Color("Type:N", legend=alt.Legend(orient="bottom", title=None)),
                tooltip=["HOPS", "Type", "Count"]).properties(height=230),
            use_container_width=True)

    st.subheader("All rings and chains")
    view = pd.DataFrame({
        "Alert": rings["ALERT_ID"],
        "Type": rings["Type"],
        "Tier": rings["TIER"].map(tier),
        "Closed by": rings["CLOSED_BY"].map(lambda c: CLOSED_BY.get(c, c) if isinstance(c, str) else "Open chain"),
        "Hops": rings["HOPS"].astype(int),
        "Path": rings["PATH"].str.replace(" -> ", " → ", regex=False),
        "First amount (AUD)": rings["FIRST_AMOUNT"],
        "Last amount (AUD)": rings["LAST_AMOUNT"],
        "Decay": rings["DECAY_PCT"],
    }).sort_values(["Type", "Tier", "Hops"], ascending=[False, True, False])
    table(view, money=["First amount (AUD)", "Last amount (AUD)"], pct=["Decay"])

    # draw one ring: money edges + identity links
    st.subheader("Look at one ring")
    rt = view[view["Type"] == "Round-trip"].sort_values(["Tier", "Alert"])
    if len(rt):
        info = rt.set_index("Alert")
        chosen = st.selectbox(
            "Ring", rt["Alert"].tolist(),
            format_func=lambda a: f"{a} · {info.at[a, 'Tier']} · {info.at[a, 'Closed by']} · {info.at[a, 'Hops']} hops")
        edges = q(f"""
            SELECT e.src, e.dst, e.amount, TO_CHAR(e.txn_time, 'DD Mon HH24:MI') AS ts
            FROM   AML_PROTOTYPE.SERVING.P1_EDGE e
            JOIN  (SELECT f.value::VARCHAR AS txn
                   FROM AML_PROTOTYPE.CURATED.FRAUD_ALERT a,
                        LATERAL FLATTEN(input => a.trigger_detail:txn_ids) f
                   WHERE a.alert_id = '{chosen}') t ON t.txn = e.transaction_id
            ORDER BY e.txn_time""")
        links = q(f"""
            SELECT DISTINCT LEAST(l.a, l.b) AS a, GREATEST(l.a, l.b) AS b, l.via
            FROM   AML_PROTOTYPE.SERVING.ACC_LINK l,
                   AML_PROTOTYPE.CURATED.FRAUD_ALERT a
            WHERE  a.alert_id = '{chosen}'
              AND  ARRAY_CONTAINS(l.a::VARIANT, a.trigger_detail:path)
              AND  ARRAY_CONTAINS(l.b::VARIANT, a.trigger_detail:path)""")
        origin = edges["SRC"].iloc[0] if len(edges) else None
        dot = ["digraph G {", "rankdir=LR; bgcolor=transparent;",
               'node [shape=circle style=filled fillcolor="#dfb0cc" fontsize=10 fontname="Helvetica"];',
               'edge [fontname="Helvetica" fontcolor="#888888"];']
        if origin:
            dot.append(f'"{origin}" [fillcolor="#e05252" fontcolor=white];')
        for _, r in edges.iterrows():
            dot.append(f'"{r.SRC}" -> "{r.DST}" [label="{r.AMOUNT:,.0f}\\n{r.TS}" fontsize=9 color="#888888"];')
        for _, r in links.iterrows():
            dot.append(f'"{r.A}" -> "{r.B}" [dir=none style=dashed color="#1d6fa5" penwidth=2 '
                       f'label="same {r.VIA}" fontcolor="#1d6fa5" fontsize=9];')
        dot.append("}")
        st.graphviz_chart("\n".join(dot))
        st.caption("Red = origin account. Solid arrows = money (amount, time). "
                   "Dashed = shared phone / email / device (P2).")

# Dashboard 2: shared identity and mule rings
with tab2:
    links_by_type = q("""SELECT via, COUNT(*) / 2 AS pairs
                         FROM AML_PROTOTYPE.SERVING.ACC_LINK GROUP BY via""")
    links_by_type["Shared"] = links_by_type["VIA"].str.capitalize()
    links_by_type["Account pairs"] = links_by_type["PAIRS"].astype(int)
    mule = q("""SELECT alert_id, device_id, n_customers, accounts
                FROM AML_PROTOTYPE.SERVING.V_DASH_MULE""")
    n_accounts = mule["ACCOUNTS"].fillna("").map(lambda s: len([a for a in s.split(",") if a.strip()]))

    c1, c2, c3 = st.columns(3)
    c1.metric("Mule rings", len(mule))
    c2.metric("Customers in mule rings", int(mule["N_CUSTOMERS"].sum()) if len(mule) else 0)
    c3.metric("Accounts in mule rings", int(n_accounts.sum()) if len(mule) else 0)

    left, right = st.columns(2)
    with left:
        st.subheader("Shared-identity links by type")
        hbar(links_by_type[["Shared", "Account pairs"]], "Shared", "Account pairs")
    with right:
        st.subheader("Mule ring size (customers per device)")
        if len(mule):
            size = mule.groupby("N_CUSTOMERS").size().reset_index(name="Rings")
            st.altair_chart(
                alt.Chart(size).mark_bar().encode(
                    x=alt.X("N_CUSTOMERS:O", title="Customers on one device",
                            axis=alt.Axis(labelAngle=0)),
                    y=alt.Y("Rings:Q", title=None, axis=alt.Axis(format="d", tickMinStep=1)),
                    tooltip=["N_CUSTOMERS", "Rings"]).properties(height=230),
                use_container_width=True)

    st.subheader("Mule rings")
    table(pd.DataFrame({
        "Alert": mule["ALERT_ID"],
        "Device": mule["DEVICE_ID"],
        "Customers": mule["N_CUSTOMERS"].astype(int),
        "Accounts": n_accounts,
        "Account IDs": mule["ACCOUNTS"],
    }).sort_values("Customers", ascending=False))

# Dashboard 3: alert queue
with tab3:
    queue = q("""SELECT alert_id, alert_type, fraud_score, account_id,
                        trigger_detail:tier::VARCHAR      AS tier,
                        trigger_detail:closed_by::VARCHAR AS closed_by,
                        status, raised_at
                 FROM AML_PROTOTYPE.CURATED.FRAUD_ALERT""")
    queue["Tier"] = queue["TIER"].map(tier)

    c1, c2, c3 = st.columns(3)
    c1.metric("Open alerts", int((queue["STATUS"] == "open").sum()))
    c2.metric("High", int((queue["Tier"] == "High").sum()))
    c3.metric("Medium", int((queue["Tier"] == "Medium").sum()))

    st.subheader("Alerts by type and tier")
    hbar(summary[["Type", "Tier", "Alerts"]], "Type", "Alerts", "Tier", TIER_SCALE)

    st.subheader("Structuring: cash deposits split under the AUD 10,000 threshold")
    struct = q("""SELECT account_id, n_days, n_deposits, total_amount, n_branches, first_day, last_day
                    FROM AML_PROTOTYPE.SERVING.DET_STRUCTURING""")
    table(pd.DataFrame({
        "Account": struct["ACCOUNT_ID"],
        "Days flagged": struct["N_DAYS"].astype(int),
        "Deposits": struct["N_DEPOSITS"].astype(int),
        "Total (AUD)": struct["TOTAL_AMOUNT"],
        "Branches": struct["N_BRANCHES"].astype(int),
        "First day": pd.to_datetime(struct["FIRST_DAY"]).dt.strftime("%d %b %Y"),
        "Last day": pd.to_datetime(struct["LAST_DAY"]).dt.strftime("%d %b %Y"),
    }).sort_values("Total (AUD)", ascending=False), money=["Total (AUD)"])

    st.subheader("Alert queue (highest score first)")
    view = pd.DataFrame({
        "Alert": queue["ALERT_ID"],
        "Type": queue["ALERT_TYPE"].map(name),
        "Score": queue["FRAUD_SCORE"].astype(int),
        "Tier": queue["Tier"],
        "Closed by": queue["CLOSED_BY"].map(lambda c: CLOSED_BY.get(c, c) if isinstance(c, str) else "—"),
        "Account": queue["ACCOUNT_ID"],
        "Status": queue["STATUS"].str.capitalize(),
        "Raised": pd.to_datetime(queue["RAISED_AT"]).dt.strftime("%d %b %Y %H:%M"),
    })
    types = sorted(view["Type"].unique())
    chosen_types = st.multiselect("Type", types, default=types)
    table(view[view["Type"].isin(chosen_types)].sort_values(["Score", "Alert"], ascending=[False, True]))

# Evaluation: detections vs ground truth
with tab4:
    st.caption("Compares detections with the generator's labels (EVALUATION.GROUND_TRUTH). "
               "Detection queries never read this table.")
    bench = q("""SELECT pattern_label, chains, found_full, found_partial, missed, tiers, false_positives
                 FROM AML_PROTOTYPE.EVALUATION.V_BENCHMARK ORDER BY pattern_label""")
    order = [name(p) for p in PATTERNS]

    rec = bench[bench["CHAINS"].notna()].copy()
    rec["Pattern"] = rec["PATTERN_LABEL"].map(name)
    for c in ["CHAINS", "FOUND_FULL", "FOUND_PARTIAL", "MISSED"]:
        rec[c] = rec[c].astype(int)

    found = int(rec["FOUND_FULL"].sum())
    injected = int(rec["CHAINS"].sum())
    fp = bench[bench["FALSE_POSITIVES"].notna()].copy()
    c1, c2, c3 = st.columns(3)
    c1.metric("Injected cases found in full", f"{found} / {injected}")
    c2.metric("Recall", f"{100 * found / injected:.0f}%")
    c3.metric("False positives (all detectors)", int(fp["FALSE_POSITIVES"].sum()))

    st.subheader("Injected cases: found / partial / missed")
    long = rec.melt(id_vars="Pattern", value_vars=["FOUND_FULL", "FOUND_PARTIAL", "MISSED"],
                    var_name="Outcome", value_name="Cases")
    long["Outcome"] = long["Outcome"].map(
        {"FOUND_FULL": "Found", "FOUND_PARTIAL": "Partial", "MISSED": "Missed"})
    long = long[long["Cases"] > 0]
    hbar(long, "Pattern", "Cases", "Outcome", OUTCOME_SCALE, order=order)

    left, right = st.columns([3, 2])
    with left:
        st.subheader("Recall by pattern")
        rv = pd.DataFrame({
            "Pattern": rec["Pattern"],
            "Injected": rec["CHAINS"],
            "Found": rec["FOUND_FULL"],
            "Partial": rec["FOUND_PARTIAL"],
            "Missed": rec["MISSED"],
            "Recall": 100 * rec["FOUND_FULL"] / rec["CHAINS"],
            "Tier": rec["TIERS"].map(lambda t: ", ".join(tier(x) for x in t.split(",")) if isinstance(t, str) and t else "—"),
        })
        rv["_o"] = rv["Pattern"].map(order.index)
        table(rv.sort_values("_o").drop(columns="_o"), pct0=["Recall"])
    with right:
        st.subheader("False positives by detector")
        alerts_by_type = summary.groupby("ALERT_TYPE")["Alerts"].sum()
        table(pd.DataFrame({
            "Detector": fp["PATTERN_LABEL"].map(lambda d: name(DETECTORS.get(d, d))),
            "Alerts": fp["PATTERN_LABEL"].map(lambda d: int(alerts_by_type.get(DETECTORS.get(d, d), 0))),
            "False positives": fp["FALSE_POSITIVES"].astype(int),
        }))
    st.caption("Round-trip · sub-threshold: the generator redraws the amount on every hop, so "
               "these chains do not decay and fall outside the 80–100% hop rule (data limitation).")
