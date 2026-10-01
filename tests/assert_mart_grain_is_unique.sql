-- Test to affirm the uniqueness of the mart results, as it promises one row per (order_date, currency). 
-- Any row returned would be violation.

select order_date, currency, count(*) as n
from {{ ref('mart_daily_orders') }}
group by order_date, currency
having count(*) > 1
