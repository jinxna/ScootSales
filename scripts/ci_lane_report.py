import argparse
import json
import statistics
import sys
from pathlib import Path


def read_json(path):
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def flow_results(artifact):
    rows = []
    for path in sorted(artifact.glob("lane*/*/result.json")):
        result = read_json(path)
        rows.append(
            {
                "flow": result["flow"],
                "seconds": float(result["seconds"]),
                "passed": bool(result["passed"]),
                "lane": path.parent.parent.name.removeprefix("lane"),
            }
        )
    return rows


def find_artifacts(roots):
    found = []
    for root in roots:
        for wall in sorted(Path(root).rglob("wall.json")):
            found.append(wall.parent)
    if not found:
        raise SystemExit("no wall.json found under " + ", ".join(map(str, roots)))
    return found


def load_artifact(artifact):
    wall = read_json(artifact / "wall.json")
    rows = flow_results(artifact)
    lane_sums = {}
    for row in rows:
        lane_sums[row["lane"]] = lane_sums.get(row["lane"], 0.0) + row["seconds"]
    return {
        "lanes": int(wall["lanes"]),
        "wall": float(wall["wallSeconds"]),
        "lane_exit": wall["laneExit"],
        "rows": rows,
        "flow_phase": max(lane_sums.values()) if lane_sums else 0.0,
        "lane_sums": lane_sums,
        "path": str(artifact),
    }


def summary(artifact):
    data = load_artifact(Path(artifact))
    print(f"### {data['lanes']} lane(s), wall {data['wall']:.1f} s, longest lane of flows {data['flow_phase']:.1f} s")
    print()
    print("| flow | seconds | result | lane |")
    print("| --- | ---: | --- | ---: |")
    for row in sorted(data["rows"], key=lambda r: (r["lane"], r["flow"])):
        print(f"| {row['flow']} | {row['seconds']:.1f} | {'pass' if row['passed'] else 'FAIL'} | {row['lane']} |")
    bad = {lane: code for lane, code in data["lane_exit"].items() if code != 0}
    if bad:
        print()
        print("Lanes with a non-zero exit: " + ", ".join(f"lane {lane} exit {code}" for lane, code in bad.items()))


def report(roots):
    runs = [load_artifact(a) for a in find_artifacts(roots)]
    by_lanes = {}
    for run in runs:
        by_lanes.setdefault(run["lanes"], []).append(run)
    if 1 not in by_lanes:
        raise SystemExit("need at least one 1-lane run as the baseline")

    single = {}
    for run in by_lanes[1]:
        for row in run["rows"]:
            if row["passed"]:
                single.setdefault(row["flow"], []).append(row["seconds"])
    baseline = {flow: statistics.median(times) for flow, times in single.items()}

    for lanes in sorted(by_lanes):
        group = by_lanes[lanes]
        walls = [run["wall"] for run in group]
        phases = [run["flow_phase"] for run in group]
        rows = [row for run in group for row in run["rows"]]
        failures = sum(1 for row in rows if not row["passed"])
        exits = sum(1 for run in group for code in run["lane_exit"].values() if code != 0)
        factors = [row["seconds"] / baseline[row["flow"]] for row in rows if row["passed"] and row["flow"] in baseline]
        print(f"lanes={lanes} runs={len(group)}")
        print(f"  wall of the whole step (s): median {statistics.median(walls):.1f}, max {max(walls):.1f}")
        print(f"  longest lane of flow seconds (s): median {statistics.median(phases):.1f}, max {max(phases):.1f}")
        if factors:
            print(f"  slowdown f vs 1 lane: median {statistics.median(factors):.2f}, max {max(factors):.2f} over {len(factors)} flow runs")
        else:
            print("  slowdown f vs 1 lane: no passed flow to compare")
        print(f"  failed flows: {failures} of {len(rows)}; lanes with non-zero exit: {exits}")


def main():
    parser = argparse.ArgumentParser(description="Report lane probe results.")
    parser.add_argument("paths", nargs="*", help="folders holding downloaded probe artifacts (each has wall.json)")
    parser.add_argument("--summary", metavar="DIR", help="print a Markdown table for one artifact folder")
    args = parser.parse_args()
    if args.summary:
        summary(args.summary)
    elif args.paths:
        report(args.paths)
    else:
        parser.error("give artifact folders or --summary DIR")


if __name__ == "__main__":
    sys.exit(main())
