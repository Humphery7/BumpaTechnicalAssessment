-- Task 2: % of merchants who ordered in their first calendar month AND then
-- ordered in each of the next three calendar months.
--
-- Dialect : DuckDB
-- Requires: `dbt build` has run (reads analytics.stg_merchant_orders, so the
--           de-duplication and typing live in one place, not copied here).
--
-- Definitions
--   first calendar month  the month of a merchant's earliest dated order.
--                         (By construction they ordered in it.)
--   retained              orders in ALL of months +1, +2 and +3 after that month
--                         (at least one order in each; the months need not
--                         be consecutive orders, just each non-empty).
--   eligible              a merchant can only be judged retained or not if the
--                         data contains their full 3-month follow-up window.
--                         The data ends 2026-06-28, so only Jan-Mar cohorts
--                         qualify; Apr-Jun cohorts (12 merchants) are excluded
--                         from the denominator. Counting them would score them
--                         as failures merely because the future hasn't happened.
--   dated orders only     the 298 orders with no date cannot be assigned to a
--                         month, so they are ignored.
--
-- "Placed an order" is read literally for the headline (scope = all_statuses:
-- paid, refunded and failed all count). The second row (scope = paid_only)
-- shows the stricter reading where only paid orders count, since a failed
-- payment is arguably not real merchant activity. The two can differ.

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

    -- Keep merchants whose month +3 falls inside the data.
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
