-- The mart promises one row per (order_date, currency). Any row returned is a
-- grain violation.
select order_date, currency, count(*) as n
from {{ ref('mart_daily_orders') }}
group by order_date, currency
having count(*) > 1
