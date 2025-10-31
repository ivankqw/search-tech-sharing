#!/usr/bin/env python3
import csv
import sys
from pathlib import Path

INPUT = Path("data/free_company_dataset.csv")
OUTPUT = Path("data/free_company_dataset_clean.tsv")

def main() -> int:
    if not INPUT.exists():
        print(f"input file not found: {INPUT}", file=sys.stderr)
        return 1

    if OUTPUT.exists():
        print(f"output already exists: {OUTPUT}", file=sys.stderr)
        return 1

    total = 0
    with INPUT.open("r", encoding="utf-8", newline="") as src, OUTPUT.open("w", encoding="utf-8", newline="") as dst:
        reader = csv.reader(src, escapechar="\\")
        for row in reader:
            if len(row) == 9:
                # Some rows omit the region column; insert an empty placeholder
                row.insert(len(row) - 2, "")
            elif len(row) != 10:
                # Fallback: pad/truncate to 10 columns to keep import aligned
                if len(row) < 10:
                    row.extend([""] * (10 - len(row)))
                else:
                    row = row[:10]
            clean = []
            for value in row:
                clean.append(value.replace("\t", " ").replace("\r", " ").replace("\n", " ").strip())
            dst.write("\t".join(clean) + "\n")
            total += 1
            if total % 500000 == 0:
                print(f"...processed {total:,} rows", file=sys.stderr)

    print(f"Wrote {total:,} rows to {OUTPUT}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
