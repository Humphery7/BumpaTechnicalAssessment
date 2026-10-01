-- Mart: daily order activity per currency.
-- Why orders without a date are excluded: they cannot be placed on a day. They
-- are not lost - they stay in stg_merchant_orders, and a singular test
-- (assert_mart_reconciles_to_staging) proves the mart accounts for every dated
-- order.

with orders as (

    select * from {{ ref('stg_merchant_orders') }}
    where not is_missing_order_date

)

select
    order_date,
    currency,

    count(*)                                         as total_orders,
    count(*) filter (where status = 'paid')          as paid_orders,
    count(*) filter (where status = 'refunded')      as refunded_orders,
    count(*) filter (where status = 'failed')        as failed_orders,
    count(distinct merchant_id)                      as active_merchants,

    coalesce(sum(amount) filter (where status = 'paid'), 0)      as paid_amount,
    -- Refund rows are already negative, so this figure is <= 0.
    coalesce(sum(amount) filter (where status = 'refunded'), 0)  as refunded_amount,
    -- Net amount: Money actually kept: paid + (negative) refunds. Failed payments excluded.
    coalesce(sum(amount) filter (where status in ('paid', 'refunded')), 0) as net_amount

from orders
group by order_date, currency
