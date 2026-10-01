-- These are some sql run to explore the dataset and corresponding results that guides the next steps of staging models.


-- 1. Row count -------------------------------------------------------------
select count(*) as total_rows from raw.merchant_orders;
-- 10000


-- 2. Distinct counts -------------------------------------------------------
select
    count(distinct order_id)    as unique_orders,
    count(distinct merchant_id) as unique_merchants,
    count(distinct currency)    as unique_currencies,
    count(distinct status)      as unique_statuses
from raw.merchant_orders;
-- 9700 unique orders in 10000 rows -> 300 surplus rows. 1219 merchants.


-- 3. Are duplicate order_ids exact duplicates, or conflicting versions? ----
select
    count(*)         as duplicated_order_ids,
    sum(copies - 1)  as surplus_rows,
    max(copies)      as max_copies,
    count(*) filter (where distinct_versions > 1) as ids_with_conflicting_values
from (
    select
        order_id,
        count(*) as copies,
        count(distinct (merchant_id, order_date, amount, currency, status)) as distinct_versions
    from raw.merchant_orders
    group by order_id
    having count(*) > 1
);
-- 296 ids, 300 surplus rows, up to 3 copies, 0 conflicting
-- => every duplicate is an exact copy, so keeping one row is lossless.



-- 4. Missing values --------------------------------------------------------
select
    count(*) filter (where order_id    is null) as missing_order_id,
    count(*) filter (where merchant_id is null) as missing_merchant_id,
    count(*) filter (where order_date  is null) as missing_order_date,
    count(*) filter (where amount      is null) as missing_amount,
    count(*) filter (where currency    is null) as missing_currency,
    count(*) filter (where status      is null) as missing_status
from raw.merchant_orders;
-- Only order_date: 305 rows (298 after de-duplication).


-- 4b. Is the missing date systematic? --------------------------------------
select status, count(*) as orders,
       count(*) filter (where order_date is null) as missing_date,
       round(100.0 * count(*) filter (where order_date is null) / count(*), 1) as pct
from raw.merchant_orders
group by status order by orders desc;
-- ~3.0-3.5% in every status (and 1.5-3.2% in every currency): random, not tied
-- to anything. Not worth imputing; flag and exclude from date-based analysis.



-- 5. Categorical values ----------------------------------------------------
select status, count(*) as n from raw.merchant_orders group by status order by n desc;
-- paid 8503 | refunded 779 | failed 718

select currency, count(*) as n from raw.merchant_orders group by currency order by n desc;
-- NGN 7995 | KES 1541 | GHS 464

select
    count(*) filter (where order_id    !~ '^ORD[0-9]+$')  as bad_order_id,
    count(*) filter (where merchant_id !~ '^M[0-9]+$')    as bad_merchant_id,
    count(*) filter (where currency <> upper(trim(currency))
                        or status   <> lower(trim(status))) as untidy_text
from raw.merchant_orders;
-- 0 / 0 / 0 -> text is already clean, so staging does not trim or re-case.



-- 6. Date range ------------------------------------------------------------
select min(order_date) as earliest, max(order_date) as latest from raw.merchant_orders;
-- 2026-01-01 .. 2026-06-28

select date_trunc('month', order_date)::date as month, count(*) as orders
from raw.merchant_orders group by 1 order by 1;
-- Jan 1018 | Feb 1568 | Mar 2080 | Apr 1617 | May 1766 | Jun 1646 | NULL 305
-- Only 6 months of data matters for Task 2: a merchant's first month needs 3
-- further months of follow-up, so only Jan-Mar cohorts can be assessed.



-- 7. Amount sign by status -------------------------------------------------
select status,
       count(*) filter (where amount <  0) as negative,
       count(*) filter (where amount >= 0) as non_negative
from raw.merchant_orders group by status;
-- refunded: all 779 negative. paid and failed: never negative.




-- 8. Currency comparability ------------------------------------------------
select currency, count(*) as n,
       round(median(abs(amount)), 0) as median_amount,
       round(max(abs(amount)), 0)    as max_amount
from raw.merchant_orders group by currency;
-- Median ~13k and max ~25k in ALL three currencies -> amounts are not
-- comparable across currencies and there are no FX rates. Never sum them.
select count(*) as merchants_with_multiple_currencies
from (select merchant_id from raw.merchant_orders group by 1 having count(distinct currency) > 1);
-- 955 of 1219 merchants -> currency belongs to the ORDER, not the merchant.



-- 9. Do refunds point back to an original order? ---------------------------
select count(*) as refund_orders,
       count(*) filter (where exists (
           select 1 from raw.merchant_orders p
           where p.status = 'paid' and p.merchant_id = r.merchant_id and p.amount = -r.amount
       )) as with_matching_paid_order
from (select distinct order_id, merchant_id, amount from raw.merchant_orders where status = 'refunded') r;
-- 760 refunds, 0 matching -> a refund is its own row with its own order_id;
-- it cannot be netted against an original order.



-- 10. Precision ------------------------------------------------------------
select count(*) filter (where abs(amount * 100 - round(amount * 100)) > 1e-6) as more_than_2dp
from raw.merchant_orders;
-- 0 -> amount is stored as DOUBLE but only ever has 2 decimals; staging casts to DECIMAL(18,2).
