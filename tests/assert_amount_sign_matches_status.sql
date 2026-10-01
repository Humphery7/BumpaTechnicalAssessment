-- Business rule observed in the raw data: refunds are negative, everything else
-- is non-negative. Any row returned breaks that rule (a refund stored as a
-- positive number would silently inflate net revenue).
select order_id, status, amount
from {{ ref('stg_merchant_orders') }}
where (status = 'refunded' and amount >= 0)
   or (status <> 'refunded' and amount < 0)
