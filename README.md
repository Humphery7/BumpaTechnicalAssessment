# Bumpa Data Technical Assessment

dbt v2 + DuckDB solution for the three tasks, built on the provided merchant orders dataset.

```
Excel file ──► scripts/load_raw.py ──► DuckDB  raw.merchant_orders
                                            │  source('raw','merchant_orders')
                                            ▼
                              staging: stg_merchant_orders   (view)
                                            │  ref()
                                            ▼
                              mart:    mart_daily_orders     (table)

                              task2.sql  reads stg_merchant_orders
```

| Deliverable | Where |
|---|---|
| Task 1: staging model, mart, tests | `models/staging/`, `models/marts/`, `tests/` |
| Task 1: incremental loading note | [Task 1 note](#task-1-incremental-loading-at-millions-of-rows) |
| Task 2: SQL | `task2.sql` (result [below](#task-2-result)) |
| Task 3: churn approach | [Task 3](#task-3-churn-risk-from-raw-data-to-a-served-prediction) |

## Running it

Needs Python 3.10+. dbt v2 is a compiled binary, so Python is only used by the ingestion script.

```bash
python -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements.txt      # duckdb, pandas, openpyxl
pip install dbt                      # dbt v2 (bundles its own DuckDB adapter)

python scripts/load_raw.py           # Excel -> raw.merchant_orders
dbt build --profiles-dir .           # models + all tests
```

Run Task 2 once the build has finished:

```bash
python -c "import duckdb; print(duckdb.connect('bumpa_orders.duckdb', read_only=True).execute(open('task2.sql').read()).df().to_string(index=False))"
```

Optional: `dbt docs generate && dbt docs serve` to browse the documented lineage.

**Expected output:** `dbt build` should finish successfully with **one warning**. That is the source-level `unique` test on `raw.merchant_orders.order_id`, which reports the 296 duplicated order IDs. It is set to `warn` on purpose: it records the upstream defect without blocking the build, while the same test on the *staging* model must (and does) pass.

**Troubleshooting:** if DuckDB reports it cannot open the database file, the `duckdb` version used by the loader is newer than the one bundled in dbt. DuckDB files open in the same or a newer engine, not an older one. Lower the pin in `requirements.txt` and re-run the loader.

## Task 1: dbt modelling

### What the data looked like

Every modelling choice traces to something found in `exploration/data_exploration.sql`:

| Finding | How it is handled |
|---|---|
| 296 order IDs are duplicated (300 surplus rows, all exact copies, none conflicting) | Staging keeps one row per `order_id`. Lossless because copies are identical. |
| 305 rows (298 after dedup) have no `order_date`, about 3% in every status and currency | Kept and flagged with `is_missing_order_date`. Excluded from the mart, which is date-based. |
| `amount` is a DOUBLE but only ever has 2 decimals | Cast to `DECIMAL(18,2)` to avoid float drift when summing money. |
| `order_date` arrives as a midnight TIMESTAMP | Cast to `DATE`. |
| Refunds are negative, standalone rows (none match an earlier paid order) | Not netted per order. The mart reports refunds as their own negative column. |
| NGN, KES and GHS amounts have the same range, and 955 of 1,219 merchants use several currencies | No conversion (there are no FX rates). Currency is part of the mart grain, so amounts can never be summed across currencies. |
| Text columns are already clean | No `trim`/`lower` boilerplate. `accepted_values` tests fail if that changes. |

### Models

- **`stg_merchant_orders`** (view): one clean row per order, as described above.
- **`mart_daily_orders`** (table): one row per `(order_date, currency)` with order counts by status, active merchants, paid, refunded and net amounts.

### Tests

- Source: `not_null` on keys, and `unique(order_id)` as a *warning* documenting the known defect.
- Staging: `unique` and `not_null` on `order_id`, `not_null` on key columns, `accepted_values` on `status` and `currency`.
- Mart: `not_null` and `accepted_values` on the grain columns.
- Singular tests in `tests/`:
  - `assert_amount_sign_matches_status`: refunds must be negative and everything else non-negative.
  - `assert_mart_grain_is_unique`: one row per `(order_date, currency)`.
  - `assert_mart_reconciles_to_staging`: the mart's order count and net amount equal the dated orders in staging, so nothing is lost or invented.

### Task 1 note: incremental loading at millions of rows

Today both models are rebuilt from scratch, which is fine at 10,000 rows and wasteful at tens of millions. The approach:

1. **Make raw append-only.** The loader already stamps `_loaded_at`. At scale each batch is appended rather than replacing the table, so raw becomes a log of everything received. That is also why duplicates must be handled downstream: re-delivered batches create exactly the duplication seen here.
2. **Make staging incremental**, with `materialized='incremental'` and `unique_key='order_id'`. On incremental runs, process only raw rows where `_loaded_at` is greater than the maximum already in the target, then de-duplicate within the batch and merge on `order_id` so a re-delivered order updates the existing row rather than adding another. The watermark must be the **load time, not `order_date`**: late-arriving or corrected orders have old order dates, and filtering on `order_date` would silently drop them.
3. **Re-aggregate only the affected days in the mart.** Use the `delete+insert` strategy, rebuilding only the `order_date` values touched by the new batch. Because the mart is a pure aggregate, recomputing a whole day is simpler and safer than trying to adjust running totals. dbt's `microbatch` strategy is a natural fit for this daily grain, subject to checking adapter support.
4. **Add a small lookback.** Reprocess the last N days (for example 3) on each run to absorb late data, trading a little compute for correctness.
5. **Keep a safety net.** Schedule an occasional `--full-refresh` (for example weekly) so drift between incremental and full results cannot accumulate unnoticed. The existing `unique` and reconciliation tests then verify the incremental result.

Orders with a null date need a policy at scale: they would be held out of the mart as they are now, with their count monitored, since a rising share signals an upstream problem.

## Task 2 result

`task2.sql` calculates, among merchants whose first calendar month leaves a full three-month follow-up in the data, the share who ordered in each of the next three calendar months.

| Definition of "an order" | Eligible merchants | Retained | **Retention** |
|---|---:|---:|---:|
| All statuses (**headline**, the literal reading) | 1,207 | 189 | **15.66%** |
| Paid orders only (sensitivity) | 1,170 | 158 | 13.50% |

Judgement calls, all documented in the file:

- **Eligibility.** The data ends 28 June 2026, so only merchants whose first month is January to March have all three follow-up months observable. The 12 merchants starting April to June are excluded from the denominator. Counting them would mark them as failures purely because the future has not happened yet. (Including them anyway gives 15.50%, so the choice barely moves the number here, but it is the correct method.)
- **Which orders count.** The headline takes "placed an order" literally, so paid, refunded and failed orders all count. Excluding failed payments, which is arguably a more honest measure of real activity, lowers the figure to 13.50%. The query returns both rows so the choice is visible.
- **Dated orders only.** The 298 undated orders cannot be assigned to a month and are ignored.
- **"Each of the following three months"** means at least one order in month +1, +2 and +3, not merely three orders in total.

## Task 3: churn risk, from raw data to a served prediction

### 1. Define churn, using the data

A model is only as good as its label, so this comes first. In this sample roughly 43 to 49% of merchants active in one month place no order in the next, month after month. Merchants are bursty, so "no order next month" is a noisy label that would flag half the base. I would agree a definition with the business that separates real disengagement from ordinary gaps, for example: *a merchant with a paid order in the trailing 90 days who has no paid order in the following calendar month*, then test alternatives (such as a 60-day inactivity window) by how stable and actionable the resulting list is. Refunded and failed orders do not count as activity. The prediction target is that label, one month ahead.

### 2. Build features in dbt (raw to features)

Layer a merchant-by-month feature table on the existing staging models, built **point-in-time**: each row uses only data available before its snapshot date, with the label taken from the following month. Getting this wrong (leakage) is the most common reason churn models look excellent in testing and fail in production.

- **Recency and frequency:** days since last paid order, orders in the last 7, 30 and 90 days.
- **Trend:** last 30 days versus the prior 60, plus the largest and average gap between orders.
- **Value:** order value and revenue per currency. There is no FX table, so values are compared *within* a merchant over time rather than added across currencies, until an FX table exists.
- **Payment health:** failed-payment rate and refund rate. Rising failures or refunds are plausible early warnings. A real payments feed (settlement, payout and dispute data) would add much more here than this extract can.
- **Tenure and mix:** days since first order, number of currencies, active days per month.

### 3. Train and evaluate

- **Split by time, not randomly.** The same merchant appears in many monthly rows, so a random split leaks. Train on earlier snapshots, validate on later ones.
- **Start with a baseline**: a simple recency rule ("no order in 30 days"). Then logistic regression, then gradient-boosted trees, which suit small tabular data and can be explained. The model must beat the rule by a margin that justifies its complexity.
- **Judge it the way the business will use it.** Precision-recall AUC and *recall at the top K*, where K is how many merchants the team can actually contact each week. Check calibration so a score of 0.7 means roughly 70%, and weight by value at risk, not just count.
- **Data caveat.** This dataset covers only six months and about 1,200 merchants, which is enough for a prototype but cannot capture seasonality. A production model needs a longer history.

### 4. Serve it so a team can act

- **Batch scoring on a schedule** (weekly or monthly, matching the label horizon). Real-time is unnecessary for a one-month-ahead prediction.
- **Pipeline:** the orchestrator runs ingestion, `dbt build` (features), then a scoring job that loads the registered model and writes `mart_merchant_churn_risk` back to the warehouse: `merchant_id`, `score_date`, `churn_probability`, `risk_tier`, `top_reasons`, `value_at_risk`, `model_version`.
- **Make it actionable, not just a number.** The business needs a *reason* and a *priority*. Per-merchant explanations (for example from SHAP) become plain-language drivers such as "orders down 60% on the prior quarter" or "payment failures rising". Ranking by `probability × recent revenue` puts the merchants worth saving first.
- **Deliver where the team works**: a dashboard for managers, and the scored table pushed through reverse ETL into the CRM or support queue, with an in-app or WhatsApp nudge for lower tiers.
- **Tiered playbooks:** high-risk, high-value merchants get a call from an account manager. Medium-risk merchants get an automated nudge or help. Merchants with failing payments get a prompt to fix their payment setup.

### 5. Prove it works and keep it working

- **Measure uplift, not just accuracy.** Hold out a control group (about 10%) who receive no intervention. The goal is merchants *retained*, so success is the retention difference between contacted and control merchants. Log every intervention to learn from the outcome.
- **Monitor** data freshness and volume (dbt tests), feature drift, and the score distribution. Labels mature one month later, so track real precision and recall as they arrive.
- **Retrain** on a schedule (monthly or quarterly) or on drift, keeping a versioned model registry so a bad model can be rolled back.
- **Later improvement:** a churn score says who is likely to leave, not who is *persuadable*. Once there is intervention history, uplift modelling targets the merchants an outreach would actually change.
