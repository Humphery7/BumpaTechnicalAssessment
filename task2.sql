-- Task 2: The % of merchants who ordered in their first calendar month AND then
-- ordered in each of the next three calendar months.
--
-- Database: DuckDB
-- Requires: `dbt build` has run (reads analytics.stg_merchant_orders).
--
-- Definitions
--   First calendar month:  We will define this as the month of a merchant's earliest dated order

--   Retained:              We will calculate retention in two ways here:
--                          1. all_statuses: the merchant had at least one order in each of months +1, +2 and +3,
--                             regardless of whether the order was paid, refunded or failed.\
--
--                          2. paid_only: the merchant had at least one paid order in each of months +1, +2 and +3.

--   Eligible:              A merchant is only eligible for the retention calculation if we have
--                          the full 3-month follow-up period for them. Since the data ends on
--                          2026-06-28, only Jan-Mar cohorts have enough history. Apr-Jun cohorts
--                          are excluded because their 3-month window isn't complete.

--   Dated orders only:     The 298 orders with no date cannot be assigned to a
--                          month, so they are ignored.
--
-- The headline uses "placed an order" literally, so paid, refunded and failed
-- orders all count. The paid_only row shows the stricter version where only
-- successful payments count, since a failed payment may not represent actual
-- merchant activity. The two definitions can produce different results.




-- Result Otained: --------------------------------------------------------
-- │    scope     │ eligible_merchants │ retained_merchants │ retention_pct │
-- │   varchar    │       int64        │       int64        │    double     │
-- ├──────────────┼────────────────────┼────────────────────┼───────────────┤
-- │ all_statuses │               1207 │                189 │         15.66 │
-- │ paid_only    │               1170 │                158 │          13.5 │
-- └──────────────┴────────────────────┴────────────────────┴───────────────


-- create different categories of scopes
with scopes as (

    select 'all_statuses' as scope, ['paid', 'refunded', 'failed'] as counted_statuses
    union all
    select 'paid_only',             ['paid']

),

merchant_months as (

    -- One row per merchant per calendar month in which they ordered.
    select distinct
        s.scope,
        o.merchant_id,
        date_trunc('month', o.order_date) as order_month
    from analytics.stg_merchant_orders as o
    cross join scopes as s
    where not o.is_missing_order_date
      and list_contains(s.counted_statuses, o.status)

),

cohorts as (

    select scope, merchant_id, min(order_month) as cohort_month
    from merchant_months
    group by scope, merchant_id

),

data_window as (

    select scope, max(order_month) as last_month
    from merchant_months
    group by scope

),

eligible as (

    -- only keeping the merchants whose month +3 falls inside the available data.
    select c.scope, c.merchant_id, c.cohort_month
    from cohorts as c
    join data_window as w using (scope)
    where c.cohort_month + interval 3 month <= w.last_month

),

retention as (

    select
        e.scope,
        e.merchant_id,
        -- Distinct months among +1..+3 that contain an order; 3 means all of them.
        count(distinct m.order_month) filter (
            where datediff('month', e.cohort_month, m.order_month) between 1 and 3
        ) = 3 as is_retained
    from eligible as e
    left join merchant_months as m
        on  m.scope = e.scope
        and m.merchant_id = e.merchant_id
    group by e.scope, e.merchant_id, e.cohort_month

)

select
    scope,
    count(*)                                                     as eligible_merchants,
    count(*) filter (where is_retained)                          as retained_merchants,
    round(100.0 * count(*) filter (where is_retained) / count(*), 2) as retention_pct
from retention
group by scope
order by scope;




