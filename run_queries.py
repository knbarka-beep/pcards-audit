"""Run every Part II and Part III query and save the results.

Usage (from the repo folder):  py run_queries.py
Output: results/<query name>.csv for each query, plus results/summary.md with row counts and the
first rows of each result, ready to copy into the assignment document.
"""
import csv
import re
import sqlite3
import time
from pathlib import Path

from db import get_db_path

ROOT = Path(__file__).parent
QUERY_FILES = [ROOT / "queries" / "part2_controls.sql", ROOT / "queries" / "part3_fraud.sql"]
OUT = ROOT / "results"
PREVIEW_ROWS = 10


def load_queries(path: Path) -> list[tuple[str, str]]:
    """Split a .sql file into (name, sql) pairs on '-- name: X' lines."""
    text = path.read_text(encoding="utf-8")
    parts = re.split(r"^-- name: (\S+)\s*$", text, flags=re.MULTILINE)
    return [(parts[i], parts[i + 1].strip()) for i in range(1, len(parts), 2)]


def md_table(cols, rows) -> str:
    def fmt(v):
        return "" if v is None else str(v).replace("|", "/")
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    lines += ["| " + " | ".join(fmt(v) for v in r) + " |" for r in rows]
    return "\n".join(lines)


def main():
    OUT.mkdir(exist_ok=True)
    con = sqlite3.connect(f"file:{get_db_path()}?mode=ro", uri=True)
    summary = ["# Query results (OSU, 2014)\n"]
    for qfile in QUERY_FILES:
        for name, sql in load_queries(qfile):
            start = time.perf_counter()
            cur = con.execute(sql)
            cols = [d[0] for d in cur.description]
            rows = cur.fetchall()
            secs = time.perf_counter() - start
            with open(OUT / f"{name}.csv", "w", newline="", encoding="utf-8") as f:
                w = csv.writer(f)
                w.writerow(cols)
                w.writerows(rows)
            print(f"{name:28s} {len(rows):6d} rows  {secs:5.2f} s")
            summary.append(f"## {name}\n\n{len(rows)} rows. First {min(PREVIEW_ROWS, len(rows))} shown.\n")
            summary.append(md_table(cols, rows[:PREVIEW_ROWS]) + "\n")
    (OUT / "summary.md").write_text("\n".join(summary), encoding="utf-8")
    print(f"\nSaved to {OUT}")


if __name__ == "__main__":
    main()
