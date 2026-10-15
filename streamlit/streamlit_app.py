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

# ---------- look and feel ----------
FONT = "Inter, -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Roboto, sans-serif"
MUTED = "#8b95a7"
INDIGO, VIOLET, CYAN, ROSE, AMBER, EMERALD = "#6366f1", "#8b5cf6", "#22d3ee", "#f43f5e", "#f59e0b", "#10b981"

st.markdown(f"""
<style>
html, body, .stApp, .stApp p, .stApp li, .stApp label, .stApp button, .stApp input,
.stApp h1, .stApp h2, .stApp h3, .stApp h4 {{ font-family: {FONT} !important; }}
.block-container {{ padding-top: 2.2rem; max-width: 1450px; }}
.hero {{ padding: 24px 28px; border-radius: 18px; margin-bottom: 20px;
        background: linear-gradient(135deg, rgba(99,102,241,.28), rgba(139,92,246,.16) 45%, rgba(34,211,238,.10));
        border: 1px solid rgba(129,140,248,.30); }}
.hero h1 {{ margin: 0; padding: 0; font-size: 2rem; font-weight: 750; letter-spacing: -.02em; }}
.hero p {{ margin: 6px 0 0; color: {MUTED}; font-size: .95rem; }}
.pill {{ display: inline-block; padding: 3px 11px; margin: 12px 6px 0 0; border-radius: 999px;
        font-size: .74rem; font-weight: 650; background: rgba(129,140,248,.16); color: #a5b4fc; }}
.kpi {{ padding: 16px 18px; border-radius: 14px; background: rgba(139,149,167,.08);
       border: 1px solid rgba(139,149,167,.18); margin-bottom: 14px; }}
.kpi-label {{ font-size: .74rem; text-transform: uppercase; letter-spacing: .07em; color: {MUTED}; font-weight: 650; }}
.kpi-value {{ font-size: 2.05rem; font-weight: 750; line-height: 1.15; margin-top: 6px; letter-spacing: -.02em; }}
.kpi-sub {{ font-size: .8rem; color: {MUTED}; margin-top: 2px; }}
.card-title {{ font-size: 1.04rem; font-weight: 700; letter-spacing: -.01em; }}
.card-sub {{ font-size: .8rem; color: {MUTED}; margin: 2px 0 8px; }}
div[data-testid="stVerticalBlockBorderWrapper"]:has(> div > [data-testid="stVerticalBlock"] > [data-testid="element-container"] > [data-testid="stMarkdown"] .card-head),
div[data-testid="stVerticalBlock"]:has(> [data-testid="stElementContainer"] > [data-testid="stMarkdown"] .card-head) {{
    border-radius: 16px !important; background: rgba(139,149,167,.05); }}
.stTabs [role="tablist"] {{ gap: 10px; border-bottom: none; padding-bottom: 6px; flex-wrap: wrap; }}
.stTabs [role="tab"] {{ height: 46px; padding: 0 20px; border-radius: 12px;
        background: rgba(139,149,167,.10); border: 1px solid rgba(139,149,167,.20); }}
.stTabs [role="tab"] p {{ font-weight: 650; font-size: .92rem; }}
.stTabs [role="tab"]:hover {{ background: rgba(129,140,248,.18); }}
.stTabs [role="tab"][aria-selected="true"] {{ background: linear-gradient(135deg, {INDIGO}, {VIOLET}); border-color: transparent; }}
.stTabs [role="tab"][aria-selected="true"] p {{ color: #ffffff !important; }}
.stTabs [data-baseweb="tab-highlight"], .stTabs [data-baseweb="tab-border"] {{ display: none; }}
</style>
""", unsafe_allow_html=True)

# ---------- display names ----------
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
TIER_SCALE = alt.Scale(domain=["High", "Medium"], range=[ROSE, AMBER])
TYPE_SCALE = alt.Scale(domain=["Round-trip", "Layering chain"], range=[INDIGO, CYAN])
OUTCOME_SCALE = alt.Scale(domain=["Found", "Partial", "Missed"], range=[EMERALD, AMBER, ROSE])
TIER_COLOR = {"High": ROSE, "Medium": AMBER}


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


# ---------- layout helpers ----------
def kpis(items):
    """Row of KPI cards: (label, value, sub, accent colour)."""
    for col, (label, value, sub, accent) in zip(st.columns(len(items)), items):
        col.markdown(f'<div class="kpi" style="border-left: 4px solid {accent}"><div class="kpi-label">{label}</div>'
                     f'<div class="kpi-value">{value}</div><div class="kpi-sub">{sub}</div></div>',
                     unsafe_allow_html=True)


def card(title, sub=""):
    """Bordered card with a title; use as a context manager."""
    c = st.container(border=True)
    c.markdown(f'<div class="card-head"><div class="card-title">{title}</div>'
               f'<div class="card-sub">{sub}</div></div>', unsafe_allow_html=True)
    return c


def show(chart, height):
    """Shared chart styling: transparent background, muted axes, bottom legend."""
    chart = (chart.properties(height=height, background="transparent")
             .configure(font=FONT)
             .configure_view(strokeWidth=0)
             .configure_axis(labelColor=MUTED, titleColor=MUTED, gridColor="rgba(139,149,167,.16)",
                             domain=False, ticks=False, labelFontSize=12, titleFontSize=12, labelPadding=8)
             .configure_legend(labelColor=MUTED, labelFontSize=12, symbolType="circle",
                               orient="bottom", title=None))
    st.altair_chart(chart, use_container_width=True, theme=None)


def hbar(df, y, x, color=None, scale=None, order=None, rank=None, single=INDIGO):
    """Horizontal bars with value labels; stacked by `color` if given."""
    totals = df.groupby(y, as_index=False)[x].sum()
    order = order or totals.sort_values(x, ascending=False)[y].tolist()
    yenc = alt.Y(f"{y}:N", sort=order, title=None, axis=alt.Axis(labelLimit=260))
    xenc = alt.X(f"sum({x}):Q", title=None, stack="zero",
                 scale=alt.Scale(domainMax=float(totals[x].max()) * 1.12),
                 axis=alt.Axis(format="d", tickMinStep=1))
    base = alt.Chart(df).encode(y=yenc)
    total_lbl = alt.Chart(totals).mark_text(align="left", dx=6, fontWeight=700, fontSize=13,
                                            color=MUTED).encode(
        y=yenc, x=alt.X(f"{x}:Q"), text=alt.Text(f"{x}:Q", format="d"))
    if color:
        sort = alt.Order(f"{rank}:Q") if rank else alt.Order(f"{color}:N")
        bars = base.mark_bar(size=24, cornerRadius=5).encode(
            x=xenc, color=alt.Color(f"{color}:N", scale=scale), order=sort,
            tooltip=[alt.Tooltip(f"{y}:N"), alt.Tooltip(f"{color}:N"), alt.Tooltip(f"sum({x}):Q", title=x)])
        seg_lbl = base.mark_text(align="right", dx=-7, fontWeight=700, fontSize=12, color="white").encode(
            x=xenc, detail=f"{color}:N", order=sort, text=alt.Text(f"sum({x}):Q", format="d"))
        layers = bars + seg_lbl + total_lbl
    else:
        bars = base.mark_bar(size=24, cornerRadius=5, color=single).encode(
            x=xenc, tooltip=[alt.Tooltip(f"{y}:N"), alt.Tooltip(f"sum({x}):Q", title=x)])
        layers = bars + total_lbl
    show(layers, alt.Step(40))


def vbar(df, x, y, color=None, scale=None, x_title="", single=INDIGO):
    """Vertical bars with a total label on top."""
    totals = df.groupby(x, as_index=False)[y].sum()
    xenc = alt.X(f"{x}:O", title=x_title, axis=alt.Axis(labelAngle=0))
    yenc = alt.Y(f"sum({y}):Q", title=None, scale=alt.Scale(domainMax=float(totals[y].max()) * 1.18),
                 axis=alt.Axis(format="d", tickMinStep=1))
    bar = alt.Chart(df).mark_bar(cornerRadiusTopLeft=6, cornerRadiusTopRight=6, size=46)
    bar = (bar.encode(x=xenc, y=yenc, color=alt.Color(f"{color}:N", scale=scale),
                      tooltip=list(df.columns)) if color else
           bar.encode(x=xenc, y=yenc, color=alt.value(single), tooltip=list(df.columns)))
    lbl = alt.Chart(totals).mark_text(dy=-9, fontWeight=700, fontSize=13, color=MUTED).encode(
        x=xenc, y=alt.Y(f"{y}:Q"), text=alt.Text(f"{y}:Q", format="d"))
    show(bar + lbl, 250)


def styler_map(styler, func, subset):
    """pandas >= 2.1 renamed Styler.applymap to Styler.map."""
    return (styler.map if hasattr(styler, "map") else styler.applymap)(func, subset=subset)


def table(df, money=(), pct=(), pct0=(), tiers=()):
    """Read-only table: thousands separators, coloured tiers, no index."""
    fmt = {c: "{:,.0f}" for c in money}
    fmt.update({c: "{:.1f}%" for c in pct})
    fmt.update({c: "{:.0f}%" for c in pct0})
    sty = df.style.format(fmt, na_rep="—")
    if tiers:
        sty = styler_map(sty, lambda v: f"color: {TIER_COLOR[v]}; font-weight: 700" if v in TIER_COLOR else "",
                         list(tiers))
    st.dataframe(sty, use_container_width=True, hide_index=True)


def graph(lines, stretch=True):
    """Render a Graphviz DOT body with the shared node/edge style."""
    head = ["digraph G {", "rankdir=LR; bgcolor=transparent; pad=0.3; nodesep=0.5; ranksep=0.9;",
            f'node [shape=circle style="filled" fillcolor="{INDIGO}" color="{INDIGO}" fontcolor=white '
            f'fontsize=10 fontname="Helvetica" width=0.9 fixedsize=true];',
            f'edge [fontname="Helvetica" fontsize=9 color="{MUTED}" fontcolor="{MUTED}" penwidth=1.4 arrowsize=0.7];']
    st.graphviz_chart("\n".join(head + lines + ["}"]), use_container_width=stretch)


# ---------- data shared by several tabs ----------
summary = q("SELECT alert_type, tier, alerts FROM AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY")
summary["Type"] = summary["ALERT_TYPE"].map(name)
summary["Tier"] = summary["TIER"].map(tier)
summary["Alerts"] = summary["ALERTS"].astype(int)

st.markdown(f"""
<div class="hero">
  <h1>AML ring detection</h1>
  <p>Money-flow rings, layering chains, mule networks and structuring on synthetic CBA data.</p>
  <span class="pill">Snowflake · AML_PROTOTYPE</span><span class="pill">{int(summary['Alerts'].sum())} alerts</span>
  <span class="pill">detection.sql → alerts.sql → benchmark.sql</span>
</div>""", unsafe_allow_html=True)

tab1, tab2, tab3, tab4 = st.tabs(
    ["Money rings & layering", "Shared identity & mule", "Alert queue", "Detection quality"])

# ---------- Dashboard 1: money rings and layering chains ----------
with tab1:
    rings = q("""SELECT alert_id, tier, closed_by, hops, path,
                        first_amount, last_amount, decay_pct
                 FROM AML_PROTOTYPE.SERVING.V_DASH_RINGS""")
    rings["Type"] = rings["CLOSED_BY"].map(lambda c: "Round-trip" if isinstance(c, str) else "Layering chain")
    p1 = summary[summary["ALERT_TYPE"].isin(["round_trip", "layering_chain"])]
    n_rt = int(p1.loc[p1["ALERT_TYPE"] == "round_trip", "Alerts"].sum())
    n_high = int(p1.loc[(p1["ALERT_TYPE"] == "round_trip") & (p1["Tier"] == "High"), "Alerts"].sum())

    kpis([("Round-trips", n_rt, "money returns to the origin or a linked account", INDIGO),
          ("High tier", n_high, "P1 cycle confirmed by a shared identity (P2)", ROSE),
          ("Medium tier", n_rt - n_high, "cycle only", AMBER),
          ("Layering chains", int(p1.loc[p1["ALERT_TYPE"] == "layering_chain", "Alerts"].sum()),
           "open chains of 4+ hops", CYAN)])

    left, right = st.columns(2)
    with left:
        with card("Detections by type and tier", "Each bar is split by risk tier"):
            hbar(p1[["Type", "Tier", "Alerts"]], "Type", "Alerts", "Tier", TIER_SCALE)
    with right:
        with card("Ring and chain length", "Number of hops per detection"):
            hops = rings.groupby(["HOPS", "Type"]).size().reset_index(name="Detections")
            hops["HOPS"] = hops["HOPS"].astype(int)
            vbar(hops, "HOPS", "Detections", "Type", TYPE_SCALE, x_title="Hops")

    with card("Look at one ring", "Red = origin account · solid arrows = money (amount, time) · "
                                  "dashed = shared phone / email / device (P2)"):
        rt = rings[rings["Type"] == "Round-trip"].copy()
        if len(rt):
            rt["label"] = (rt["ALERT_ID"] + "  ·  " + rt["TIER"].map(tier) + "  ·  "
                           + rt["CLOSED_BY"].map(lambda c: CLOSED_BY.get(c, c)) + "  ·  "
                           + rt["HOPS"].astype(int).astype(str) + " hops")
            rt = rt.sort_values(["TIER", "ALERT_ID"])
            labels = dict(zip(rt["ALERT_ID"], rt["label"]))
            chosen = st.selectbox("Ring", rt["ALERT_ID"].tolist(), format_func=labels.get,
                                  label_visibility="collapsed")
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
            lines = []
            if len(edges):
                lines.append(f'"{edges["SRC"].iloc[0]}" [fillcolor="{ROSE}" color="{ROSE}"];')
            for _, r in edges.iterrows():
                lines.append(f'"{r.SRC}" -> "{r.DST}" [label="{r.AMOUNT:,.0f}\\n{r.TS}"];')
            for _, r in links.iterrows():
                lines.append(f'"{r.A}" -> "{r.B}" [dir=none style=dashed color="{CYAN}" penwidth=2 '
                             f'label="same {r.VIA}" fontcolor="{CYAN}"];')
            graph(lines)

    with card("All rings and chains", "Sorted by type, tier and length"):
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
        table(view, money=["First amount (AUD)", "Last amount (AUD)"], pct=["Decay"], tiers=["Tier"])

# ---------- Dashboard 2: shared identity and mule rings ----------
with tab2:
    links_by_type = q("""SELECT via, COUNT(*) / 2 AS pairs
                         FROM AML_PROTOTYPE.SERVING.ACC_LINK GROUP BY via""")
    links_by_type["Shared"] = links_by_type["VIA"].str.capitalize()
    links_by_type["Account pairs"] = links_by_type["PAIRS"].astype(int)
    mule = q("""SELECT alert_id, device_id, n_customers, accounts
                FROM AML_PROTOTYPE.SERVING.V_DASH_MULE""")
    n_accounts = mule["ACCOUNTS"].fillna("").map(lambda s: len([a for a in s.split(",") if a.strip()]))

    kpis([("Mule rings", len(mule), "devices shared by 3+ customers", AMBER),
          ("Customers in mule rings", int(mule["N_CUSTOMERS"].sum()) if len(mule) else 0,
           "distinct owners", VIOLET),
          ("Accounts in mule rings", int(n_accounts.sum()) if len(mule) else 0,
           "new accounts passing money through", INDIGO),
          ("Identity links", int(links_by_type["Account pairs"].sum()),
           "account pairs sharing phone / email / device", CYAN)])

    left, right = st.columns(2)
    with left:
        with card("Shared-identity links by type", "Account pairs of different customers"):
            hbar(links_by_type[["Shared", "Account pairs"]], "Shared", "Account pairs", single=CYAN)
    with right:
        with card("Mule ring size", "Customers per shared device"):
            if len(mule):
                size = mule.groupby("N_CUSTOMERS").size().reset_index(name="Rings")
                size["N_CUSTOMERS"] = size["N_CUSTOMERS"].astype(int)
                vbar(size, "N_CUSTOMERS", "Rings", x_title="Customers on one device", single=AMBER)

    with card("Look at one mule ring", "Customer → account → shared device · accounts were opened recently "
                                       "and pass ≥ 90% of incoming money out within 24h"):
        if len(mule):
            mule_labels = dict(zip(mule["ALERT_ID"], mule["ALERT_ID"] + "  ·  " + mule["DEVICE_ID"] + "  ·  "
                                   + mule["N_CUSTOMERS"].astype(int).astype(str) + " customers"))
            chosen_m = st.selectbox("Mule ring", mule.sort_values("N_CUSTOMERS", ascending=False)["ALERT_ID"].tolist(),
                                    format_func=mule_labels.get, label_visibility="collapsed")
            members = q(f"""
                SELECT a.account_id, a.customer_id, TO_CHAR(a.open_date, 'DD Mon YYYY') AS opened,
                       f.trigger_detail:device_id::VARCHAR AS device_id
                FROM   AML_PROTOTYPE.CURATED.FRAUD_ALERT f,
                       LATERAL FLATTEN(input => f.trigger_detail:accounts) x,
                       AML_PROTOTYPE.CURATED.ACCOUNT a
                WHERE  f.alert_id = '{chosen_m}'
                  AND  a.account_id = x.value::VARCHAR""")
            if len(members):
                dev = members["DEVICE_ID"].iloc[0]
                lines = ["ranksep=1.3; nodesep=0.35;",
                         f'"{dev}" [shape=hexagon fillcolor="{AMBER}" color="{AMBER}" width=1.3 fontsize=11];']
                for cust in members["CUSTOMER_ID"].unique():
                    lines.append(f'"{cust}" [shape=box style="rounded,filled" fillcolor="{VIOLET}" '
                                 f'color="{VIOLET}" width=1.2 height=0.5];')
                for _, r in members.iterrows():
                    lines.append(f'"{r.ACCOUNT_ID}" [label="{r.ACCOUNT_ID}\\nopened {r.OPENED}" shape=box '
                                 f'style="rounded,filled" width=1.9 height=0.55 fontsize=9];')
                    lines.append(f'"{r.CUSTOMER_ID}" -> "{r.ACCOUNT_ID}" [label="owns" dir=none];')
                    lines.append(f'"{r.ACCOUNT_ID}" -> "{dev}" [label="logs in" dir=none style=dashed '
                                 f'color="{AMBER}" fontcolor="{AMBER}" penwidth=1.8];')
                graph(lines, stretch=False)

    with card("All mule rings"):
        table(pd.DataFrame({
            "Alert": mule["ALERT_ID"],
            "Device": mule["DEVICE_ID"],
            "Customers": mule["N_CUSTOMERS"].astype(int),
            "Accounts": n_accounts,
            "Account IDs": mule["ACCOUNTS"],
        }).sort_values("Customers", ascending=False))

# ---------- Dashboard 3: alert queue ----------
with tab3:
    queue = q("""SELECT alert_id, alert_type, fraud_score, account_id,
                        trigger_detail:tier::VARCHAR      AS tier,
                        trigger_detail:closed_by::VARCHAR AS closed_by,
                        status, raised_at
                 FROM AML_PROTOTYPE.CURATED.FRAUD_ALERT""")
    queue["Tier"] = queue["TIER"].map(tier)

    kpis([("Open alerts", int((queue["STATUS"] == "open").sum()), "awaiting review", INDIGO),
          ("High", int((queue["Tier"] == "High").sum()), "fraud score 90", ROSE),
          ("Medium", int((queue["Tier"] == "Medium").sum()), "fraud score 60", AMBER),
          ("Alert types", queue["ALERT_TYPE"].nunique(), "detectors feeding the queue", CYAN)])

    with card("Alerts by type and tier", "All detectors write into CURATED.FRAUD_ALERT"):
        hbar(summary[["Type", "Tier", "Alerts"]], "Type", "Alerts", "Tier", TIER_SCALE)

    with card("Alert queue", "Highest score first · filter by type"):
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
        chosen_types = st.multiselect("Type", types, default=types, label_visibility="collapsed")
        table(view[view["Type"].isin(chosen_types)].sort_values(["Score", "Alert"], ascending=[False, True]),
              tiers=["Tier"])

    with card("Structuring", "Cash deposits split under the AUD 10,000 reporting threshold"):
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

# ---------- Evaluation: detections vs ground truth ----------
with tab4:
    bench = q("""SELECT pattern_label, chains, found_full, found_partial, missed, tiers, false_positives
                 FROM AML_PROTOTYPE.EVALUATION.V_BENCHMARK ORDER BY pattern_label""")
    order = [name(p) for p in PATTERNS]

    rec = bench[bench["CHAINS"].notna()].copy()
    rec["Pattern"] = rec["PATTERN_LABEL"].map(name)
    for c in ["CHAINS", "FOUND_FULL", "FOUND_PARTIAL", "MISSED"]:
        rec[c] = rec[c].astype(int)
    fp = bench[bench["FALSE_POSITIVES"].notna()].copy()

    found, injected = int(rec["FOUND_FULL"].sum()), int(rec["CHAINS"].sum())
    kpis([("Found in full", f"{found} / {injected}", "injected cases covered by one detection", EMERALD),
          ("Recall", f"{100 * found / injected:.0f}%", "found in full ÷ injected", INDIGO),
          ("Partial / missed", f"{int(rec['FOUND_PARTIAL'].sum())} / {int(rec['MISSED'].sum())}",
           "all in round-trip · sub-threshold", AMBER),
          ("False positives", int(fp["FALSE_POSITIVES"].sum()), "detections touching no injected case", ROSE)])

    with card("Injected cases: found / partial / missed",
              "Compared with EVALUATION.GROUND_TRUTH, which detection queries never read"):
        long = rec.melt(id_vars="Pattern", value_vars=["FOUND_FULL", "FOUND_PARTIAL", "MISSED"],
                        var_name="Outcome", value_name="Cases")
        long["Outcome"] = long["Outcome"].map(
            {"FOUND_FULL": "Found", "FOUND_PARTIAL": "Partial", "MISSED": "Missed"})
        long["rank"] = long["Outcome"].map({"Found": 0, "Partial": 1, "Missed": 2})
        hbar(long[long["Cases"] > 0], "Pattern", "Cases", "Outcome", OUTCOME_SCALE, order=order, rank="rank")

    left, right = st.columns([3, 2])
    with left:
        with card("Recall by pattern"):
            rv = pd.DataFrame({
                "Pattern": rec["Pattern"],
                "Injected": rec["CHAINS"],
                "Found": rec["FOUND_FULL"],
                "Partial": rec["FOUND_PARTIAL"],
                "Missed": rec["MISSED"],
                "Recall": 100 * rec["FOUND_FULL"] / rec["CHAINS"],
                "Tier": rec["TIERS"].map(lambda t: ", ".join(tier(x) for x in t.split(","))
                                         if isinstance(t, str) and t else "—"),
            })
            rv["_o"] = rv["Pattern"].map(order.index)
            table(rv.sort_values("_o").drop(columns="_o"), pct0=["Recall"], tiers=["Tier"])
    with right:
        with card("False positives by detector"):
            alerts_by_type = summary.groupby("ALERT_TYPE")["Alerts"].sum()
            table(pd.DataFrame({
                "Detector": fp["PATTERN_LABEL"].map(lambda d: name(DETECTORS.get(d, d))),
                "Alerts": fp["PATTERN_LABEL"].map(lambda d: int(alerts_by_type.get(DETECTORS.get(d, d), 0))),
                "False positives": fp["FALSE_POSITIVES"].astype(int),
            }))
    st.caption("Round-trip · sub-threshold: the generator redraws the amount on every hop, so "
               "these chains do not decay and fall outside the 80–100% hop rule (data limitation).")
