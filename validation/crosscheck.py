"""Independent Python re-implementation of the SAS programs in ../sas.

Purpose: a second, separate implementation of every step (import, quality
checks, order-level roll-up, logistic models, Firth fit, holdout scoring,
monthly monitoring) so the SAS listing can be checked number by number.

Usage:
    pip install pandas numpy scipy statsmodels scikit-learn
    python validation/crosscheck.py data/DataCoSupplyChainDataset.csv
"""
import sys
import warnings

import numpy as np
import pandas as pd
import statsmodels.api as sm
from sklearn.metrics import brier_score_loss, roc_auc_score

warnings.filterwarnings("ignore")
pd.set_option("display.width", 200)

REFS = {"ship_mode": "Standard Class", "market": "USCA", "segment": "Consumer",
        "pay_type": "DEBIT", "order_qtr": 1}
CANDIDATES = ["ship_mode", "market", "segment", "pay_type", "order_qtr",
              "weekend", "n_items", "order_total_100"]
AUC_TOLERANCE = 0.03
GAP_TOLERANCE = 0.03


def section(title):
    print("\n" + "=" * 72 + "\n" + title + "\n" + "=" * 72)


def design(data, effects, interaction=None):
    """Reference-coded design matrix (same coding as PARAM=REF in SAS)."""
    cols, groups = {}, {}
    for e in effects:
        if e in REFS:
            groups[e] = []
            for level in sorted(data[e].unique()):
                if level != REFS[e]:
                    name = f"{e}={level}"
                    cols[name] = (data[e] == level).astype(float)
                    groups[e].append(name)
        else:
            cols[e] = data[e].astype(float)
            groups[e] = [e]
    X = pd.DataFrame(cols, index=data.index)
    if interaction:
        a, b = interaction
        key = f"{a}*{b}"
        groups[key] = []
        for ca in groups[a]:
            for cb in groups[b]:
                X[f"{ca}*{cb}"] = X[ca] * X[cb]
                groups[key].append(f"{ca}*{cb}")
    return sm.add_constant(X), groups


def type3(result, groups):
    """Joint Wald chi-square per effect (SAS 'Type 3 Analysis of Effects')."""
    names = list(result.params.index)
    out = {}
    for effect, members in groups.items():
        R = np.zeros((len(members), len(names)))
        for i, m in enumerate(members):
            R[i, names.index(m)] = 1
        w = result.wald_test(R, scalar=True)
        out[effect] = (float(w.statistic), len(members), float(w.pvalue))
    return out


def firth_logit(X, y, max_iter=200, tol=1e-10):
    """Firth penalized-likelihood logistic regression (MODEL ... / FIRTH)."""
    X = np.asarray(X, float)
    y = np.asarray(y, float)
    beta = np.zeros(X.shape[1])
    for _ in range(max_iter):
        p = 1 / (1 + np.exp(-X @ beta))
        w = p * (1 - p)
        info_inv = np.linalg.inv(X.T @ (X * w[:, None]))
        hat = w * np.einsum("ij,jk,ik->i", X, info_inv, X)
        step = info_inv @ (X.T @ (y - p + hat * (0.5 - p)))
        biggest = np.abs(step).max()
        if biggest > 5:
            step *= 5 / biggest
        beta += step
        if biggest < tol:
            break
    return beta


def main(path):
    # ------------------------------------------------------------ 01 import + QC
    section("01  IMPORT AND QUALITY CHECKS")
    items = pd.read_csv(path, encoding="latin-1")
    print(f"line items: {len(items):,}   columns: {items.shape[1]}")
    print(f"orders: {items['Order Id'].nunique():,}")
    print(f"duplicate Order Item Id: {int(items['Order Item Id'].duplicated().sum())}")
    print(f"missing Order Zipcode: {int(items['Order Zipcode'].isna().sum()):,} "
          f"({items['Order Zipcode'].isna().mean():.1%})")
    print(f"missing Product Description: {int(items['Product Description'].isna().sum()):,}")

    items["order_date"] = pd.to_datetime(items["order date (DateOrders)"],
                                         format="%m/%d/%Y %H:%M").dt.normalize()
    items["ship_date"] = pd.to_datetime(items["shipping date (DateOrders)"],
                                        format="%m/%d/%Y %H:%M").dt.normalize()
    print(f"order dates: {items.order_date.min().date()} to {items.order_date.max().date()}")

    by_order = items.groupby("Order Id")
    shipping_cols = ["Shipping Mode", "Late_delivery_risk", "Delivery Status",
                     "Days for shipping (real)", "Days for shipment (scheduled)",
                     "Market", "Customer Segment", "Type", "order_date", "ship_date"]
    inconsistent = (by_order[shipping_cols].nunique() > 1).any(axis=1).sum()
    print(f"orders whose shipping attributes differ across line items: {int(inconsistent)}")

    orders = by_order.agg(
        order_date=("order_date", "first"), ship_date=("ship_date", "first"),
        days_real=("Days for shipping (real)", "first"),
        days_sched=("Days for shipment (scheduled)", "first"),
        late_flag=("Late_delivery_risk", "first"),
        delivery_status=("Delivery Status", "first"),
        ship_mode=("Shipping Mode", "first"), market=("Market", "first"),
        segment=("Customer Segment", "first"), pay_type=("Type", "first"),
        n_items=("Order Item Id", "count"), order_total=("Order Item Total", "sum"),
    ).reset_index()
    gap = (orders.ship_date - orders.order_date).dt.days
    print(f"orders where ship date - order date != recorded transit days: "
          f"{int((gap != orders.days_real).sum())}")

    orders["took_longer"] = (orders.days_real > orders.days_sched).astype(int)
    print("\nLabel reconciliation (delivery status x took longer than scheduled x late flag):")
    print(orders.groupby(["delivery_status", "took_longer", "late_flag"]).size().to_string())

    # ------------------------------------------------------------ 02 explore
    section("02  EXPLORE AND TEST")
    d = orders[orders.delivery_status != "Shipping canceled"].copy()
    d["late"] = d.late_flag
    d["weekend"] = d.order_date.dt.dayofweek.isin([5, 6]).astype(int)
    d["order_qtr"] = d.order_date.dt.quarter
    d["order_total_100"] = d.order_total / 100
    d["order_month"] = d.order_date.dt.to_period("M")
    print(f"delivered orders: {len(d):,}   late: {int(d.late.sum()):,} ({d.late.mean():.1%})")
    tab = d.groupby("ship_mode").late.agg(late="sum", orders="size", late_rate="mean")
    tab["share_of_all_late"] = tab.late / tab.late.sum()
    print(tab.round(4).to_string())
    print("\nScheduled days by mode:")
    print(pd.crosstab(d.ship_mode, d.days_sched).to_string())
    print("\nActual transit days by mode:")
    print(pd.crosstab(d.ship_mode, d.days_real).to_string())
    from scipy.stats import chi2_contingency
    print("\nPearson chi-square, each factor x late:")
    for f in ["ship_mode", "market", "segment", "pay_type", "order_qtr", "weekend"]:
        chi2, p, dof, _ = chi2_contingency(pd.crosstab(d[f], d.late), correction=False)
        print(f"  {f:10s} chi2={chi2:10.2f}  df={dof}  p={p:.4g}")

    # ------------------------------------------------------------ 03 model
    section("03  LOGISTIC MODEL")
    train = d[d.order_date < "2017-01-01"]
    holdout = d[d.order_date >= "2017-01-01"].copy()
    print(f"train: {len(train):,} orders (late {train.late.mean():.1%})   "
          f"holdout: {len(holdout):,} orders (late {holdout.late.mean():.1%})")
    fc = train[train.ship_mode == "First Class"]
    print(f"First Class in train: {int(fc.late.sum()):,} late of {len(fc):,} "
          f"-> quasi-complete separation")
    sub = train[train.ship_mode != "First Class"]
    print(f"\nScreening subset (First Class excluded): {len(sub):,} orders")

    print("\nStep 1 - crude models:")
    for e in CANDIDATES:
        X, g = design(sub, [e])
        chi2, df, p = type3(sm.Logit(sub.late, X).fit(disp=0), g)[e]
        print(f"  {e:16s} Wald chi2={chi2:9.2f}  df={df}  p={p:.4g}")

    print("\nStep 2 - backward elimination (SLSTAY=0.10):")
    current = list(CANDIDATES)
    while True:
        X, g = design(sub, current)
        fit = sm.Logit(sub.late, X).fit(disp=0)
        t3 = type3(fit, g)
        worst = max(t3, key=lambda k: t3[k][2])
        if t3[worst][2] > 0.10 and len(current) > 1:
            print(f"  remove {worst:16s} p={t3[worst][2]:.4f}")
            current.remove(worst)
        else:
            break
    print("  retained:", ", ".join(f"{k} (p={t3[k][2]:.4g})" for k in current))
    print(np.exp(fit.params).rename("odds_ratio").round(4).to_string())

    X, g = design(sub, ["ship_mode", "market"], interaction=("ship_mode", "market"))
    chi2, df, p = type3(sm.Logit(sub.late, X).fit(disp=0), g)["ship_mode*market"]
    print(f"\nStep 3 - ship_mode*market interaction: Wald chi2={chi2:.2f} df={df} p={p:.4f}")

    def xmat(data, extra):
        X = pd.DataFrame({"Intercept": 1.0}, index=data.index)
        for level in ["First Class", "Same Day", "Second Class"]:
            X[level] = (data.ship_mode == level).astype(float)
        for e in extra:
            X[e] = data[e]
        return X

    print("\nStep 5 - Firth models fitted on all training orders:")
    betas = {}
    for label, extra in [("A: ship_mode", []), ("B: ship_mode + order_total_100", ["order_total_100"])]:
        X = xmat(train, extra)
        beta = firth_logit(X, train.late)
        betas[label] = beta
        print(f"\n  Model {label}")
        for name, b in zip(X.columns, beta):
            print(f"    {name:16s} estimate={b:9.4f}  odds ratio={np.exp(b):12.3f}")
        for nm, part in [("train", train), ("holdout", holdout)]:
            p = 1 / (1 + np.exp(-np.asarray(xmat(part, extra)) @ beta))
            print(f"    {nm:8s} AUC={roc_auc_score(part.late, p):.4f}  "
                  f"Brier={brier_score_loss(part.late, p):.4f}  "
                  f"error rate={((p >= 0.5) != part.late).mean():.4f}")

    # ------------------------------------------------------------ 04 monitoring
    section("04  MONITORING (final model A on the 2017-2018 holdout)")
    beta = betas["A: ship_mode"]
    base_auc = roc_auc_score(train.late, 1 / (1 + np.exp(-np.asarray(xmat(train, [])) @ beta)))
    holdout["p_late"] = 1 / (1 + np.exp(-np.asarray(xmat(holdout, [])) @ beta))
    print(f"baseline (training) AUC: {base_auc:.4f}   "
          f"alert if monthly AUC < {base_auc - AUC_TOLERANCE:.4f} "
          f"or |observed - predicted| > {GAP_TOLERANCE:.2f}")
    rows = []
    for month, part in holdout.groupby("order_month"):
        auc = roc_auc_score(part.late, part.p_late)
        gap = part.late.mean() - part.p_late.mean()
        alert = ("AUC below tolerance" if base_auc - auc > AUC_TOLERANCE
                 else "Calibration drift" if abs(gap) > GAP_TOLERANCE else "OK")
        rows.append((str(month), len(part), part.late.mean(), part.p_late.mean(), gap, auc, alert))
    mon = pd.DataFrame(rows, columns=["month", "orders", "observed", "predicted", "gap", "auc", "alert"])
    print(mon.round(4).to_string(index=False))
    print(f"\nmonthly AUC range: {mon.auc.min():.4f} to {mon.auc.max():.4f}   "
          f"gap range: {mon.gap.min():+.4f} to {mon.gap.max():+.4f}   "
          f"alerts: {int((mon.alert != 'OK').sum())}")

    cap = holdout.groupby("ship_mode").agg(predicted_risk=("p_late", "first"),
                                           orders=("late", "size"), late=("late", "sum"))
    cap = cap.sort_values("predicted_risk", ascending=False)
    cap["share_of_orders"] = cap.orders.cumsum() / cap.orders.sum()
    cap["share_of_late_caught"] = cap.late.cumsum() / cap.late.sum()
    print("\nCapture table (holdout, riskiest tier first, cumulative):")
    print(cap.round(4).to_string())


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
