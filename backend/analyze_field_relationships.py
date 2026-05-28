"""分析样本字段之间、字段与ground_truth之间的关联强度。

输出:
  data/field_ground_truth_mutual_info.csv
  data/categorical_cramers_v.csv
  data/numeric_spearman_corr.csv
  data/field_relationship_summary.txt
"""

import csv
import math
import os
from itertools import combinations

import numpy as np
import pandas as pd
from scipy.stats import chi2_contingency, spearmanr
from sklearn.feature_selection import mutual_info_classif
from sklearn.preprocessing import LabelEncoder


INPUT_CSV = "data/realistic_scene_samples.csv"
OUT_DIR = "data"
TARGET = "ground_truth"


DROP_FOR_SIGNAL = {
    "sample_id",
    "ground_truth",
    "ground_truth_id",
    "gt_confidence",
    "context_text",
    "confusable_group",
    "conflict_reason",
    "user_correction_to",
}


def cramers_v(x, y):
    table = pd.crosstab(x.fillna("__NA__"), y.fillna("__NA__"))
    if table.shape[0] < 2 or table.shape[1] < 2:
        return 0.0
    chi2 = chi2_contingency(table, correction=False)[0]
    n = table.to_numpy().sum()
    if n == 0:
        return 0.0
    phi2 = chi2 / n
    r, k = table.shape
    # bias correction
    phi2corr = max(0.0, phi2 - ((k - 1) * (r - 1)) / (n - 1))
    rcorr = r - ((r - 1) ** 2) / (n - 1)
    kcorr = k - ((k - 1) ** 2) / (n - 1)
    denom = min(kcorr - 1, rcorr - 1)
    if denom <= 0:
        return 0.0
    return math.sqrt(phi2corr / denom)


def discretize_numeric(series, bins=5):
    numeric = pd.to_numeric(series, errors="coerce")
    if numeric.nunique(dropna=True) <= 1:
        return pd.Series(["single"] * len(series), index=series.index)
    try:
        return pd.qcut(numeric, q=min(bins, numeric.nunique(dropna=True)), duplicates="drop").astype(str).fillna("__NA__")
    except ValueError:
        return numeric.fillna(numeric.median()).astype(str)


def ground_truth_mutual_info(df):
    rows = []
    y = LabelEncoder().fit_transform(df[TARGET].astype(str))
    feature_cols = [c for c in df.columns if c not in DROP_FOR_SIGNAL]

    for col in feature_cols:
        s = df[col]
        if pd.api.types.is_numeric_dtype(s):
            x = pd.to_numeric(s, errors="coerce").fillna(pd.to_numeric(s, errors="coerce").median()).to_numpy().reshape(-1, 1)
            discrete = False
        else:
            x = LabelEncoder().fit_transform(s.fillna("__NA__").astype(str)).reshape(-1, 1)
            discrete = True
        mi = mutual_info_classif(x, y, discrete_features=[discrete], random_state=42)[0]
        rows.append({
            "field": col,
            "mutual_info_with_ground_truth": round(float(mi), 6),
            "normalized_by_log_18": round(float(mi / math.log(18)), 6),
            "type": "numeric" if pd.api.types.is_numeric_dtype(s) else "categorical",
            "unique_values": int(s.nunique(dropna=False)),
        })
    return pd.DataFrame(rows).sort_values("mutual_info_with_ground_truth", ascending=False)


def categorical_cramers(df):
    cat_cols = []
    for col in df.columns:
        if col in {"context_text", "sample_id", "conflict_reason"}:
            continue
        if not pd.api.types.is_numeric_dtype(df[col]) or df[col].nunique(dropna=False) <= 25:
            cat_cols.append(col)

    prepared = {}
    for col in cat_cols:
        if pd.api.types.is_numeric_dtype(df[col]):
            prepared[col] = discretize_numeric(df[col])
        else:
            prepared[col] = df[col].fillna("__NA__").astype(str)

    rows = []
    for a, b in combinations(cat_cols, 2):
        rows.append({"field_a": a, "field_b": b, "cramers_v": round(cramers_v(prepared[a], prepared[b]), 6)})
    return pd.DataFrame(rows).sort_values("cramers_v", ascending=False)


def numeric_spearman(df):
    numeric_cols = [c for c in df.columns if pd.api.types.is_numeric_dtype(df[c]) and df[c].nunique(dropna=True) > 1]
    rows = []
    for a, b in combinations(numeric_cols, 2):
        corr, p = spearmanr(df[a], df[b], nan_policy="omit")
        if np.isnan(corr):
            continue
        rows.append({"field_a": a, "field_b": b, "spearman_corr": round(float(corr), 6), "p_value": round(float(p), 6)})
    return pd.DataFrame(rows).sort_values("spearman_corr", key=lambda s: s.abs(), ascending=False)


def write_summary(mi_df, cv_df, sp_df):
    summary_path = os.path.join(OUT_DIR, "field_relationship_summary.txt")
    with open(summary_path, "w", encoding="utf-8") as f:
        f.write("字段与ground_truth的互信息 Top 15\\n")
        f.write(mi_df.head(15).to_string(index=False))
        f.write("\\n\\n分类字段之间 Cramer's V Top 20\\n")
        f.write(cv_df.head(20).to_string(index=False))
        f.write("\\n\\n数值字段之间 Spearman |corr| Top 20\\n")
        f.write(sp_df.head(20).to_string(index=False))
        f.write("\\n")
    return summary_path


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    df = pd.read_csv(INPUT_CSV, encoding="utf-8-sig")

    mi_df = ground_truth_mutual_info(df)
    cv_df = categorical_cramers(df)
    sp_df = numeric_spearman(df)

    mi_path = os.path.join(OUT_DIR, "field_ground_truth_mutual_info.csv")
    cv_path = os.path.join(OUT_DIR, "categorical_cramers_v.csv")
    sp_path = os.path.join(OUT_DIR, "numeric_spearman_corr.csv")

    mi_df.to_csv(mi_path, index=False, encoding="utf-8-sig")
    cv_df.to_csv(cv_path, index=False, encoding="utf-8-sig")
    sp_df.to_csv(sp_path, index=False, encoding="utf-8-sig")
    summary_path = write_summary(mi_df, cv_df, sp_df)

    print("字段与ground_truth互信息 Top 12:")
    print(mi_df.head(12).to_string(index=False))
    print("\\n分类字段之间 Cramer's V Top 12:")
    print(cv_df.head(12).to_string(index=False))
    print("\\n数值字段之间 Spearman |corr| Top 12:")
    print(sp_df.head(12).to_string(index=False))
    print("\\n输出文件:")
    print(mi_path)
    print(cv_path)
    print(sp_path)
    print(summary_path)


if __name__ == "__main__":
    main()
