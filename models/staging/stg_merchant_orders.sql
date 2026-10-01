with source as (

    select * from {{ source('dbt_source', 'merchant_orders') }}

),


-- remove duplicates 
deduplicated as (

    select
        *,
        row_number() over (
            partition by order_id
            order by order_date nulls last, merchant_id, amount, currency, status
        ) as row_num
    from source

)

select
    order_id,
    merchant_id,
    cast(order_date as date)        as order_date,
    order_date is null              as is_missing_order_date,
    cast(amount as decimal(18, 2))  as amount,
    currency,
    status
from deduplicated
where row_num = 1
