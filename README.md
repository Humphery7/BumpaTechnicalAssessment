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


## The incremental loading note

**The problem.** Right now every time I run `dbt build`, it deletes and rebuilds everything from scratch. With 10,000 rows that takes a second. With millions of new rows arriving every day, rebuilding the whole history each time would be slow and expensive.

**The idea.** "Incremental" means only processing the new data and adding it to what's already there. Here's how I'd set it up:

1. **Keep every delivery of raw data and tag it with the time it arrived.** My loader already adds a `_loaded_at` column to every row. At scale, I'd add new batches to the raw table instead of replacing it. This also explains the duplicates in this data: if a system sends the same order twice, you get two rows. Duplicates will keep arriving, so the cleaning step has to handle them every time.
2. **Make the staging model only look at new rows.** dbt has a setting called incremental(https://docs.getdbt.com/docs/build/incremental-models-overview?version=2) for this. On each run, the model would read only raw rows that arrived after the latest `_loaded_at` it has already processed. That "last processed" point is called a watermark.
3. **Use the arrival time as the watermark, not the order date.** This is easy to get wrong. Say an order from March gets corrected in October. Its order date is old, so if I filtered on order date I'd skip it and never see the fix. Its arrival time is new, so I'll catch it.
4. **Update orders that already exist, instead of adding them again.** dbt can be told that `order_id` identifies a row. If an incoming order matches one already in the table, it replaces the old row. If it's new, it's added. That keeps one row per order even when duplicates keep arriving.
5. **Only rebuild the days that changed in the daily summary.** If new data touches 3 March, I'd delete the 3 March rows from the mart and recalculate just that day. Recalculating a whole day is simpler and safer than trying to adjust the old totals.
6. **Re-check the last few days every run.** I'd reprocess, say, the last 3 days each time, in case data turns up late. It costs a little extra computing for much better accuracy.



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

### Step 1: Decide what "leaving/churn" means

This has to come first, because the whole model is built around it. If it is defined badly, everything after is wasted.

Looking at this data shows why it's tricky. In every month, roughly 43% to 49% of merchants who ordered didn't order the following month. So "didn't order next month" is true for almost half of them. A list that flags half of all merchants isn't useful, because the team can't call everyone.

With this I could agree on a stricter definition with the business. For example: *a merchant who had a paid order in the last 90 days, but has none in the next calendar month.* I'd then try a few variations, like a 60-day gap, and see which gives a list that's stable and worth acting on. I'd count only paid orders as activity, since a failed payment or a refund isn't a healthy sign.

### Step 2: Turn the data into clues about each merchant

Neither a rule nor a model can read a list of orders. Both need one row per merchant with columns that describe their behaviour. These columns are called features. I'd build them with dbt, on top of the staging model I already have. Examples:

- **How long since their last paid order.** A merchant who last ordered 40 days ago is different from one who ordered yesterday.
- **How many orders in the last 7, 30 and 90 days.** This shows how active they are.
- **Whether they're speeding up or slowing down.** For example, the last 30 days compared with the 60 days before.
- **Gaps between orders.** The average and the longest gap.
- **How much they sell.** Compared against the merchant's own past, not other merchants, because the currencies differ and I have no exchange rates.
- **How many payments fail, and how many orders get refunded.** Rising failures or refunds could be a warning sign. This dataset only has an order status. In real life I'd want proper payment data, like payouts and disputes, which would add much more here.
- **How long they've been a merchant.**

The important rule is that each row may only use information from before the date it describes. If a feature accidentally includes something from after that date, the score will look brilliant in testing and then fail in real use. This mistake is called "leakage".

### Step 3: Train the model and check it honestly

I'd take a snapshot of every merchant at the end of each month. For each snapshot, the features are what I knew then, and the answer is whether they left in the following month. That gives the model thousands of past examples to learn from.

A few things I'd be careful about:

- **Split the data by time (a time series split), not at random.** I'd train on older months and test on newer ones. A random split would put the same merchant in both the training and the test sets, which lets the model cheat by recognising merchants it has already seen.
- **Start simple, and only add complexity if it earns its place.** I'd try three things in this order:
  2. **A simple model** that weighs several clues at once (logistic regression, which can be turned into a points score).
  3. **A more powerful model** (gradient-boosted trees, which are many small decision trees that learn from each other's mistakes), which can pick up combinations of clues the simple model misses.

  Each step has to do clearly better than the one before it when tested on later months it hasn't seen. If it doesn't, I stop there and use the simpler one, because it's cheaper to run and easier to explain to the business.
- **Measure what the business cares about.** The team can only contact a limited number of merchants each week. So the question is: *if I take the top 200 merchants on the list, how many of them were truly about to leave?* I'd also check that a score of 0.7 really means about a 70% chance, and I'd rank merchants by how much money is at stake, not just how likely they are to leave.
- **Be honest about the data.** This dataset has only six months and about 1,200 merchants. That's enough for a prototype, but too short to learn seasonality, like a quiet December. A real model needs more history.

### Step 4: Put the results where people can use them

A score in a notebook helps nobody. Here's how I'd get it to the team:

1. **Run it on a schedule.** Weekly or monthly is enough. Since I'm predicting a month ahead, real-time scoring would add cost and no benefit.
2. **Write the results to a table** in the data warehouse. Each merchant gets a row. Here's a made-up example of what it might look like:

| merchant | chance of leaving | risk level | why | money at risk |
|---|---|---|---|---|
| M1234 | 82% | High | Orders down 60% vs the previous 3 months; 4 failed payments last month | high |
| M2001 | 55% | Medium | No order in 25 days, longer than usual | medium |

3. **Include the reasons and the priority.** Each merchant's row carries a short list of reasons, so a support agent knows what to say. For a rules score, the reasons are the rules that fired, like "no paid order in 34 days". For a model, I measure how much each clue pushed that merchant's score above the average merchant's, keep the top two or three, and write each as a plain sentence, like "Only 1 paid order this month (typical: 2)". These go in a `top_reasons` column. They show what moved the score, not what caused the merchant to leave, so I'd only show them for a score that passed the Step 4 backtest. Also, to rank by priority, I'd multiply the chance of leaving by the merchant's usual sales.
4. **Send it where the team already works.** A dashboard for managers, and the table pushed into the CRM or support tool so the right person sees the right merchants.
5. **Match the action to the risk.** High-risk, high-value merchants get a call from an account manager. Medium-risk ones get an automatic message or in-app nudge. Merchants with failing payments get help fixing their payment setup.

### Step 5: Prove that it works, and keep it working

The most important question isn't "is the model accurate?" It's "did contacting these merchants keep more of them?" To find out, I'd hold back a small random group (about 10%) from any outreach, even if they're flagged. Then I'd compare how many stayed in the contacted group against the held-back group. If the contacted group stays more, the whole system is working. I'd also record every outreach, so the results can feed back into the next version.

After launch I'd keep an eye on:

- Whether the data is arriving on time and in the expected volume (my dbt tests help here).
- Whether the merchants' behaviour is drifting away from what the model learned.
- How accurate it actually is, once the real outcomes come in a month later.

I'd retrain on a schedule, monthly or quarterly, and keep old versions of the model so I can switch back if a new one performs worse.
