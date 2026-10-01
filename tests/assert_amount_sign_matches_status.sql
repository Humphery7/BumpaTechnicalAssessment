-- Refunds are negative amounts, while all other orders are non-negative.
-- Any row returned here violates that pattern and could inflate net revenue.
select order_id, status, amount
from {{ ref('stg_merchant_orders') }}
where (status = 'refunded' and amount >= 0)
   or (status <> 'refunded' and amount < 0)
