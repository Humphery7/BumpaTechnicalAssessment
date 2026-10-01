# Bumpa Data Technical Assessment

## What's in the repo

| Task | What I did | Where to find it |
|---|---|---|
| 1. dbt modelling | Cleaned the data, built a daily summary table, added tests | `models/` and `tests/` folders |
| 1. Incremental loading note | Explained how I'd handle millions of rows | [Task 1 incremental note](#the-incremental-loading-note) |
| 2. SQL problem | Worked out what % of merchants kept ordering for three months | `task2.sql`, answer [here](#task-2-the-sql-problem) |
| 3. Applied scenario | Wrote up how I'd predict which merchants are about to leave | [Task 3](#task-3-predicting-which-merchants-might-leave) |

## Words you'll see in this README

some terms definitions:

- **dbt**: a tool for turning raw data into clean, usable tables. You write each step as a short SQL file, and dbt runs them in the right order. It also runs checks on the results.
- **SQL**: the language used to ask questions of a database, like "count the orders per day".
- **DuckDB**: a small database that lives in a single file on my laptop. There's no server to set up, which is why I used it here.
- **Raw data**: the data exactly as it arrived, mistakes included. I never edit it.
- **Model**: in dbt, a model is just one SQL file that produces one table.
- **Staging model**: the first cleaning step. It takes the raw data and fixes its problems.
- **Mart**: a table built for a specific use, like reporting. It's built on top of the cleaned data.
- **Test**: an automatic check. For example, "no two rows should have the same order ID". If the check fails, dbt tells me.
- **Churn**: when a merchant stops using Bumpa.
- **Cohort**: a group of merchants who started in the same month.

## How the pieces fit together

```
Excel file  ->  loader script  ->  raw table  ->  staging model  ->  mart model
(as given)      (copies it in)    (untouched)     (cleaned up)       (daily summary)
```

Each step only reads from the one before it. If something looks wrong in the daily summary, I can trace it back one step at a time until I find where it went wrong.

## How to run it

You need Python 3.10 or newer. Run these from the project folder.

```bash
python -m venv .venv
source .venv/bin/activate            # if on Windows: .venv\Scripts\activate
pip install -r requirements.txt

python scripts/load_data_duckdb.py
dbt build --profiles-dir .
```

What each command does:

1. The first two lines make a private Python environment, so nothing gets installed on your whole computer.
2. `pip install -r requirements.txt` installs the three libraries the loader script needs.
3. `python scripts/load_data_duckdb.py` reads the Excel file and puts it into a DuckDB file called `bumpa_merchant_orders.duckdb`. That file doesn't exist until you run this, and it's the "raw table" in the diagram above.
4. `dbt build --profiles-dir .` builds the staging model, builds the mart, and runs all the tests. The `--profiles-dir .` part tells dbt to use the `profiles.yml` in this folder, which holds the database connection.

The answer to Task 2 is embedded as a comment in the task2.sql file but to rerun and  see the answer, you can use the following command after the build finishes:

```bash
python -c "import duckdb; print(duckdb.connect('bumpa_merchant_orders.duckdb', read_only=True).execute(open('task2.sql').read()).df().to_string(index=False))"
```

That one-liner opens the database, runs the SQL file, and prints the result.

## What I found in the data

Before building anything, I spent time looking at the data. The queries are in `exploration/data_exploration.sql`, with the results written next to them as comments. Every decision in the dbt models comes from something in this list.

| What I found | What I did about it |
|---|---|
| 296 order IDs show up more than once (300 extra rows). In every case the copies are identical. | Keep one copy of each. Since they're identical, nothing is lost. |
| 305 rows have no order date (298 once duplicates are removed). It's about 3% in every status and every currency, so it looks random. | Keep them, but mark them with a flag. I can't put them on a day, so the daily summary leaves them out. |
| The date column comes in as a timestamp, but the time is always midnight. | Turn it into a plain date. |
| The amount column is stored as a decimal-point number, but every value has exactly two decimal places. | Store it as a fixed two-decimal number. This avoids tiny rounding errors when adding up money. |
| There are three currencies (NGN, KES, GHS) and no exchange rates. Amounts look similar in size across all three. | Never add amounts from different currencies together. The daily summary keeps each currency on its own row. |
| 955 of the 1,219 merchants have orders in more than one currency. | This tells me currency belongs to each order, not to each merchant. |
| Refunds are negative amounts. Each refund is its own row with its own order ID, and none of them point back to an original order. | I can't link a refund to the sale it reverses, so I report refunds as their own column. |
| The text columns (status, currency, IDs) have no stray spaces or mixed capitalisation. | Nothing to fix, so I didn't add any cleaning code for it. |


## Task 1: dbt modelling

### The staging model: `stg_merchant_orders`

This is the cleaning step. It reads the raw table and produces a table with exactly one row per order. It does three things:

1. **Removes duplicates.** If the same order ID appears two or three times, it keeps one row. It picks the row in a fixed order, so the result is the same on every run. That's 10,000 raw rows down to 9,700 orders.
2. **Fixes the data types.** The date becomes a plain date and the amount becomes a two-decimal number.
3. **Flags missing dates.** I add a true/false column called `is_missing_order_date`. The orders stay in the table because they did happen. The flag lets whoever uses the table decide what to do with them.

It's a "view", which means dbt saves the query, not a copy of the results. Every time someone reads it, it reflects the latest raw data.

Two things I left out deliberately. I didn't trim spaces or change capitalisation, because the text is already clean and writing code for a problem that doesn't exist would just be clutter. If that ever changes, the `accepted_values` tests will fail and tell me. I also didn't convert currencies, since I have no exchange rates and guessing them would give wrong numbers.

### The mart model: `mart_daily_orders`

This is the summary table. It has one row for each day and currency, and it answers questions like "how many orders did we get in naira on 1 January, and how much money was that?"

Here's a real row from it:

| order_date | currency | total_orders | paid_orders | refunded_orders | failed_orders | active_merchants | paid_amount | refunded_amount | net_amount |
|---|---|---|---|---|---|---|---|---|---|
| 2026-01-01 | NGN | 31 | 25 | 3 | 3 | 29 | 313,552.98 | -34,586.49 | 278,966.49 |

`net_amount` is paid amount plus refunded amount. Refunds are already negative, so adding them takes the money back out. Failed payments aren't counted as money because no money moved.

I made two choices here:

- **Currency is part of each row.** If I'd made one total per day, it would add naira to Kenyan shillings, which is meaningless. Putting currency in the row makes that mistake impossible.
- **Orders without a date are left out.** They can't be placed on a day. They aren't lost, because they stay in the staging table, and a test (see below) checks that the mart accounts for every dated order. The mart ends up with 9,402 orders, which is 9,700 minus the 298 undated ones.

It's a "table", so dbt stores the results, which makes reading it fast.

### The tests

A test is a check that runs automatically. If the data breaks the rule, the test fails. I wrote these:

- **Order ID is unique and never empty (staging).** After removing duplicates, every order ID should appear exactly once. This proves the cleaning worked.
- **Status can only be `paid`, `refunded` or `failed` (staging).** If a new value ever shows up, I want to know.
- **Currency can only be NGN, KES or GHS (staging).** Same idea.
- **Key columns are never empty (staging and mart).** Merchant ID, amount, status, currency and date.
- **Refunds are negative and everything else isn't (custom test).** If a refund ever arrived as a positive number, it would quietly inflate revenue.
- **The mart has one row per day and currency (custom test).** This protects the structure expected.
- **The mart adds up to the staging table (custom test).** The mart's order count and net amount should match the dated orders in staging. This catches anything lost or double-counted between the two steps.


### The incremental loading note

At the moment, every time I run `dbt build` it deletes everything and builds it again from scratch. With 10,000 rows that takes about a second, so it's fine. With millions of rows coming in every day it would take too long. I haven't built the fix, but this is what I would do.

The idea is called [incremental](https://docs.getdbt.com/docs/build/incremental-models-overview?version=2). Each run only handles the new rows and adds them to what is already there.

First I would change my loader. Right now it replaces the raw table every time. Instead it should add each new batch to the bottom. It already puts a `_loaded_at` column on every row, which tells me when the row arrived, and I'd keep that. This matters because the duplicates in this data probably come from the same order being sent twice. That will keep happening, so the cleaning step has to deal with it on every run.

Then I would change the staging model so that it only reads rows that arrived after the last run. The point where it stopped last time is called a watermark. My staging model doesn't pass `_loaded_at` through yet, so I'd need to add that.

I would use the arrival time as the watermark and not the order date. Say an order from March is corrected in October. If I only looked at order dates, I would miss it, because March is old. But it arrived in October, so the arrival time catches it.

Some of the new rows will be orders I already have. So I would tell dbt that `order_id` identifies an order (this setting is called `unique_key`). If an order already exists, the new row replaces the old one. If it doesn't exist, it gets added. That way there is still one row per order.

The daily summary works the same way. If a new batch has orders from 3 March, I would delete the 3 March rows and work out that day again. That is easier than trying to fix the old totals. I would also go back over the last few days on every run, in case some data arrives late. I haven't tested how many days is enough. Three is just a first guess.

Small differences can slowly build up when you only ever add new data. So now and then, maybe once a week, I would rebuild everything from scratch with dbt's `--full-refresh` option. My tests, like the one checking that order IDs are unique, would show me if the two versions ever disagree.

The orders with no date also need a rule. I would keep leaving them out of the daily summary, and count them on each run. If that number suddenly jumps, something has probably gone wrong before the data reaches me.



## Task 2: the SQL problem

**The question.** Using the same dataset, calculate the percentage of merchants who placed an order in their first calendar month and then placed at least one additional order in each of the following three calendar months.

**Understanding.** Merchant A first orders on 14 January. That makes January their first month. To count as retained, they need at least one order in February, one in March and one in April. Merchant B first orders on 3 March. Their first month is March, and they'd need orders in April, May and June. Each merchant has their own first month. The percentage is calculated across all of them together.

**How the query works.** The file is `task2.sql`, with the result appended from the run. It reads from the cleaned staging table, so I don't repeat the cleaning logic.

1. List each merchant's order months: one line for every month a merchant had at least one order.
2. Find each merchant's first month. This is the earliest of their months.
3. Drop merchants who can't be judged yet (they don't have 3 full months after their first month).
4. For each remaining merchant, count how many of the three following months have an order. If all three do, they're retained.
5. Divide the number of retained merchants by the number of merchants still in the list.

**The answer.**

| What counts as "an order" | Merchants judged | Retained | Percentage |
|---|---:|---:|---:|
| Any order: paid, refunded or failed (my main answer) | 1,207 | 189 | 15.66% |
| Paid orders only | 1,170 | 158 | 13.50% |

**Choices made:**

- **Merchants who started in April, May or June are left out.** The data stops at the end of June. A merchant who started in April doesn't have three full months after it in the data, so I can't tell if they'd have stayed. If I counted them, they'd look like failures just because the future isn't in the file. Only the January, February and March starters can be fully judged. (If I'd kept the others in anyway, the answer would be 15.50%, so it barely matters here, but leaving them out is the correct method.)
- **I assume two cases of what counts as an order.** For one, a failed payment is still an order someone placed, so my main answer counts every status. But you could argue a failed payment isn't real activity, so I also show paid-only. The gap is about two percentage points. In `task2.sql` this is controlled by a small list at the top, so both come out of one query.
- **Orders without a date are ignored.** I can't tell which month they belong to.
- **limitation:** if a merchant's very first order is one of the undated ones, I use their first dated order instead, which could put them in a later month than the truth. There's no way to recover the missing dates, so I note it and move on.

## Task 3: predicting which merchants might leave

Bumpa wants to flag merchants at risk of churn one month ahead, using order and payment data. Walk us through your approach from end to end, from raw data to a served prediction that a business team could act on.

### The definition problem

When I looked at this data, between 43% and 49% of merchants who placed an order in a given month didn't place one the following month. That's nearly half the active merchants, every single month. If "didn't order next month" is the definition of churn, then almost half of all merchants are always at risk, and a list that long is useless. Nobody can act on it.

So I'd push back and agree on something stricter with whoever owns the merchant relationship. Something like: a merchant who had at least one paid order in the last 90 days but then has none in the next calendar month. That filters out the casually-inactive ones and focuses attention on merchants who were clearly engaged and then went quiet. I'd count only paid orders, not failed or refunded ones, because a failed payment isn't really evidence of activity.

### Turning orders into features

With order and payment data available, I would have more features to use. To score merchants you need one row per merchant, not one row per order. That means turning the order history into summary columns. Some features I'd prioritise above everything else are **days since last paid order**, **How much they sell.**, **How many payments fail, and how many orders get refunded.**, **How long they've been a merchant** and **average and median gap between orders** . These could explain most of the signals. The rest could be refinements.

When comparing volumes I'd compare each merchant against their own past rather than against other merchants. The currencies aren't convertible, and a merchant doing 2 orders a month who drops to 0 is a very different risk profile from a high-volume merchant with the same drop.

I'd build all of this with dbt, on top of the staging model I already have. One non-negotiable constraint: every feature must only use data from before the date the score is calculated. If a feature accidentally uses future information, the model looks brilliant in testing and fails completely in production. This is called data leakage and it's easy to do by accident if you're not careful about how you join tables.

### Starting simple

With only 6 months of data and around 1,200 merchants, I wouldn't start with a machine learning model. Sometimes the best solutions are the most obvious/simplest , So I'd start with a rule: if a merchant had paid orders in the previous 2 months but none in the last 30 days, flag them, then Rank by revenue accumulated. Run that for a short period to see how many flagged merchants actually churned versus how many came back on their own, and use that to decide whether the rule is any good.

If the rule isn't sharp enough, logistic regression is the next step. It's fast, it produces a probability, if logistic regression doesn't give a good prediction rate, more complex models like Gradient boosted trees can pick up patterns logistic regression misses, but they're harder to explain and I wouldn't reach for them unless the simpler model was clearly falling short.

Either way, I'd train on the earlier months and test on the later ones, never a random split. A random split leaks future merchants into the training set and makes the numbers look better than they are.

The metric that matters isn't accuracy. It's: of the top 200 merchants I flag this month, how many genuinely churned? The business team has limited capacity, so precision at the top of the list matters more than overall scores.

### Getting the score to the people who need it

A score sitting in a notebook is worthless. I'd write results to a table in the data warehouse - one row per merchant, with their churn probability, a rough risk tier, their typical monthly revenue, and a short plain-English reason for the score: "no paid order in 34 days, longest gap in 3 months." That last part is what makes it actionable. A support agent needs to know what to say, not just that a merchant is flagged.

I'd run it weekly. Monthly is probably too slow to catch early signs, and anything more frequent is overkill when you're predicting a month ahead. The output table feeds into whatever CRM or support tool the team already uses.

High-risk, high-revenue merchants get a direct call. Mid-risk ones get an automated nudge in the app. Merchants with a pattern of failed payments probably need help with their payment setup specifically, so those get a different message.

### Checking whether it actually works

The real test isn't whether the model is accurate — it's whether contacting the flagged merchants keeps more of them. I'd hold back some of the flagged merchants from outreach and compare what happens to them with the ones we contacted. If the contacted group stays active more often, that gives us evidence that the outreach is actually helping. If it doesn't, either the model is wrong or the outreach isn't effective, and both are worth knowing.

After launch I'd watch the data quality (the dbt tests already cover most of this), watch for drift in merchant behaviour over time, and retrain regularly. I'd always keep the previous model version so I can roll back if a new one performs worse on real outcomes.
