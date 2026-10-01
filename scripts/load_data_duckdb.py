"""
load_raw.py - This is an ingestion step: From the Excel file -> DuckDB `raw.merchant_orders`.

It does the following:
  1. Fail loudly if the file's columns are not the ones we expect, so schema
     drift is caught at the door rather than as a confusing downstream error.
  2. Stamp every row with `_source_file` and `_loaded_at` so a raw row can
     always be traced back to the load that produced it.

Usage:
    python scripts/load_data_duckdb.py
    python scripts/load_data_duckdb.py --file data/Merchant_Orders_Sample.xlsx --db bumpa_orders.duckdb
"""

import argparse
import sys
from pathlib import Path

import duckdb
import pandas as pd

PROJECT_ROOT = Path(__file__).resolve().parent.parent
# print(PROJECT_ROOT)
DEFAULT_FILE = PROJECT_ROOT / "data" / "Merchant_Orders_Sample.xlsx"
DEFAULT_DB = PROJECT_ROOT / "bumpa_merchant_orders.duckdb"

SCHEMA = "raw"
TABLE = "merchant_orders"
EXPECTED_COLUMNS = ["order_id", "merchant_id", "order_date", "amount", "currency", "status"]


def read_source(path: Path) -> pd.DataFrame:
    df = pd.read_excel(path)
    df.columns = [str(c).strip().lower().replace(" ", "_") for c in df.columns]

    if list(df.columns) != EXPECTED_COLUMNS:
        sys.exit(
            f"Unexpected columns in {path.name}.\n"
            f"  expected: {EXPECTED_COLUMNS}\n"
            f"  found:    {list(df.columns)}"
        )

    df["_source_file"] = path.name
    df["_loaded_at"] = pd.Timestamp.now(tz="UTC").tz_localize(None)
    print(df.head())
    return df


def load(df: pd.DataFrame, db_path: Path) -> int:
    con = duckdb.connect(str(db_path))
    try:
        con.execute(f"CREATE SCHEMA IF NOT EXISTS {SCHEMA}")
        con.register("incoming", df)
        con.execute(
            f"CREATE OR REPLACE TABLE {SCHEMA}.{TABLE} AS SELECT * FROM incoming"
        )
        return con.execute(f"SELECT count(*) FROM {SCHEMA}.{TABLE}").fetchone()[0]
    finally:
        con.close()


def main():
    parser = argparse.ArgumentParser(description="Load merchant orders into DuckDB raw schema.")
    parser.add_argument("--file", type=Path, default=DEFAULT_FILE, help="Excel file to load.")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB, help="DuckDB database file.")
    args = parser.parse_args()

    if not args.file.exists():
        sys.exit(f"File not found: {args.file}")

    df = read_source(args.file)
    rows = load(df, args.db)
    print(f"Loaded {rows:,} rows into {SCHEMA}.{TABLE} ({args.db.name})")


if __name__ == "__main__":
    main()
