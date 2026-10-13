# =====================================================================
#  aml_dashboard.py  -  Streamlit in Snowflake app (AML prototype)
#
#  Implements: "Consumption / dashboards" box of the solution architecture.
#  Snowsight Dashboards are deprecated, so the 3 dashboards are built as one
#  Streamlit app with 3 tabs (+ an evaluation tab). Reads SERVING views and
#  CURATED.FRAUD_ALERT produced by detection.sql + alerts.sql.
#
#  Create in Snowsight: Projects -> Streamlit -> + Streamlit App,
#  location AML_PROTOTYPE.SERVING, warehouse AML_WH, paste this file, Run.
# =====================================================================
import pandas as pd
import streamlit as st

# Works on both Streamlit-in-Snowflake runtimes (warehouse and container)
try:
    from snowflake.snowpark.context import get_active_session
    session = get_active_session()
except Exception:
    session = st.connection("snowflake").session()

st.set_page_config(page_title="AML ring detection", layout="wide")
st.title("AML ring detection")
st.caption("Synthetic data · detections from detection.sql / alerts.sql")


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


summary = q("SELECT alert_type, tier, alerts FROM AML_PROTOTYPE.SERVING.V_DASH_ALERT_SUMMARY")

tab1, tab2, tab3, tab4 = st.tabs(
    ["1 · Money rings & layering (P1)", "2 · Shared identity & mule (P2)",
     "3 · Alert queue", "4 · Detection quality (evaluation)"])

# ---------------------------------------------------------------------
# Dashboard 1: money rings and layering chains (P1)
# ---------------------------------------------------------------------
with tab1:
    rings = q("""SELECT alert_id, tier, closed_by, hops, path,
                        first_amount, last_amount, decay_pct
                 FROM AML_PROTOTYPE.SERVING.V_DASH_RINGS""")
    p1 = summary[summary["ALERT_TYPE"].isin(["round_trip", "layering_chain"])]

    c1, c2, c3 = st.columns(3)
    c1.metric("Round-trips", int(p1.loc[p1["ALERT_TYPE"] == "round_trip", "ALERTS"].sum()))
    c2.metric("…of which high (P1+P2)",
              int(p1.loc[(p1["ALERT_TYPE"] == "round_trip") & (p1["TIER"] == "high"), "ALERTS"].sum()))
    c3.metric("Layering chains", int(p1.loc[p1["ALERT_TYPE"] == "layering_chain", "ALERTS"].sum()))

    left, right = st.columns(2)
    with left:
        st.subheader("Detections by type and tier")
        st.bar_chart(p1.pivot(index="ALERT_TYPE", columns="TIER", values="ALERTS").fillna(0))
    with right:
        st.subheader("Ring / chain length (hops)")
        st.bar_chart(rings.groupby("HOPS").size().rename("count"))

    st.subheader("All rings and chains")
    st.dataframe(rings.sort_values(["TIER", "HOPS"], ascending=[True, False]),
                 use_container_width=True, hide_index=True)

    # draw one ring as a graph: money edges + the identity link that closes / ties it
    st.subheader("Look at one ring")
    ring_ids = q("""SELECT alert_id FROM AML_PROTOTYPE.CURATED.FRAUD_ALERT
                    WHERE alert_type = 'round_trip' ORDER BY fraud_score DESC, alert_id""")["ALERT_ID"].tolist()
    if ring_ids:
        chosen = st.selectbox("Ring", ring_ids)          # value comes from our own alert list
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
        dot = ["digraph G {", "rankdir=LR;",
               'node [shape=circle style=filled fillcolor="#dfb0cc" fontsize=10];']
        for _, r in edges.iterrows():
            dot.append(f'"{r.SRC}" -> "{r.DST}" [label="{r.AMOUNT:,.0f}\\n{r.TS}" fontsize=9];')
        for _, r in links.iterrows():
            dot.append(f'"{r.A}" -> "{r.B}" [dir=none style=dashed color="#1d6fa5" '
                       f'label="same {r.VIA}" fontcolor="#1d6fa5" fontsize=9];')
        dot.append("}")
        st.graphviz_chart("\n".join(dot))
        st.caption("Solid arrows = money (amount, time). Dashed = shared phone / email / device (P2).")

# ---------------------------------------------------------------------
# Dashboard 2: shared identity and mule rings (P2)
# ---------------------------------------------------------------------
with tab2:
    links_by_type = q("""SELECT via, COUNT(*) / 2 AS pairs
                         FROM AML_PROTOTYPE.SERVING.ACC_LINK GROUP BY via""")
    mule = q("""SELECT alert_id, device_id, n_customers, accounts
                FROM AML_PROTOTYPE.SERVING.V_DASH_MULE""")

    c1, c2 = st.columns(2)
    c1.metric("Mule rings", len(mule))
    c2.metric("Accounts in mule rings", int(mule["N_CUSTOMERS"].sum()) if len(mule) else 0)

    left, right = st.columns(2)
    with left:
        st.subheader("Shared-identity links by type (account pairs)")
        st.bar_chart(links_by_type.set_index("VIA")["PAIRS"])
    with right:
        st.subheader("Mule ring size (customers per device)")
        if len(mule):
            st.bar_chart(mule.groupby("N_CUSTOMERS").size().rename("rings"))

    st.subheader("Mule rings")
    st.dataframe(mule.sort_values("N_CUSTOMERS", ascending=False),
                 use_container_width=True, hide_index=True)

# ---------------------------------------------------------------------
# Dashboard 3: alert queue for investigators
# ---------------------------------------------------------------------
with tab3:
    queue = q("""SELECT alert_id, alert_type, fraud_score, account_id,
                        trigger_detail:tier::VARCHAR      AS tier,
                        trigger_detail:closed_by::VARCHAR AS closed_by,
                        status, raised_at
                 FROM AML_PROTOTYPE.CURATED.FRAUD_ALERT""")

    c1, c2, c3 = st.columns(3)
    c1.metric("Open alerts", int((queue["STATUS"] == "open").sum()))
    c2.metric("High", int((queue["TIER"] == "high").sum()))
    c3.metric("Medium", int((queue["TIER"] == "medium").sum()))

    st.subheader("Alerts by type and tier")
    st.bar_chart(summary.pivot(index="ALERT_TYPE", columns="TIER", values="ALERTS").fillna(0))

    st.subheader("Alert queue (highest score first)")
    types = st.multiselect("Type", sorted(queue["ALERT_TYPE"].unique()),
                           default=sorted(queue["ALERT_TYPE"].unique()))
    st.dataframe(queue[queue["ALERT_TYPE"].isin(types)]
                 .sort_values(["FRAUD_SCORE", "ALERT_ID"], ascending=[False, True]),
                 use_container_width=True, hide_index=True)

# ---------------------------------------------------------------------
# Evaluation (reads EVALUATION.V_BENCHMARK, i.e. the ground truth).
# Kept in its own tab: this is test evidence, not part of the AML solution.
# ---------------------------------------------------------------------
with tab4:
    st.caption("Compares detections with the generator's labels (EVALUATION.GROUND_TRUTH). "
               "Detection queries never read this table.")
    bench = q("""SELECT pattern_label, chains, found_full, found_partial, missed, tiers, false_positives
                 FROM AML_PROTOTYPE.EVALUATION.V_BENCHMARK ORDER BY pattern_label""")
    recall = bench[bench["CHAINS"].notna()].set_index("PATTERN_LABEL")
    st.subheader("Injected chains: found / partial / missed")
    st.bar_chart(recall[["FOUND_FULL", "FOUND_PARTIAL", "MISSED"]])
    st.dataframe(bench, use_container_width=True, hide_index=True)
