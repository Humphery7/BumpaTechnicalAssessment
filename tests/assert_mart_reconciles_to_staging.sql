-- Nothing may be lost or invented between staging and the mart. A row is
-- returned if the mart's order count or net amount differs from the dated
-- orders in staging.
with stg as (
    select count(*) as orders, sum(amount) filter (where status in ('paid', 'refunded')) as net_amount
    from {{ ref('stg_merchant_orders') }}
    where not is_missing_order_date
),

mart as (
    select sum(total_orders) as orders, sum(net_amount) as net_amount
    from {{ ref('mart_daily_orders') }}
)

select stg.orders as stg_orders, mart.orders as mart_orders,
       stg.net_amount as stg_net, mart.net_amount as mart_net
from stg, mart
where stg.orders <> mart.orders
   or stg.net_amount <> mart.net_amount
