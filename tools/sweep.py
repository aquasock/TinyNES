#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Build design variants over many nextpnr seeds in parallel and tabulate them.

Each variant is synthesised once, then placed and routed once per seed. Every
run records its exit status, clock Fmax, hold violations, resource use,
placement wirelength, dedicated clock-routing misses, clock route length, run
time and peak memory. Packing is optional and runs in a smaller pool because
each Apicula pack holds the whole device database in memory. The tool never
loads the board.
"""

import argparse
import collections
import concurrent.futures
import csv
import datetime
import hashlib
import json
import os
import pathlib
import re
import shlex
import statistics
import subprocess
import sys
import threading
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
DESIGNS = ROOT / "tools" / "designs"


def parse_seeds(text):
    seeds = []
    for part in text.split(","):
        first, _, last = part.partition("-")
        seeds.extend(range(int(first), int(last or first) + 1))
    return seeds


class Tools:
    def __init__(self):
        home = pathlib.Path.home()
        self.suite = pathlib.Path(os.environ.get("OSS_CAD_SUITE", home / "oss-cad-suite"))
        self.nextpnr = os.environ.get(
            "NEXTPNR_HIMBAECHEL", home / "tools/nextpnr-mathieufro/nextpnr-himbaechel")
        self.apicula = pathlib.Path(
            os.environ.get("APICULA_FORK", ROOT.parent / "apicula-mathieufro"))
        self.pydeps = os.environ.get("PYDEPS", home / "tools/pydeps")
        for path in (self.suite / "environment", self.nextpnr):
            if not pathlib.Path(path).exists():
                raise SystemExit(f"missing open toolchain: {path}")

    def run(self, argv, log_path, cwd=ROOT):
        """Run argv inside the oss-cad-suite environment; return (rc, seconds, peak MB)."""
        # Match tools/build_ae350_uart.sh: the suite's environment script
        # resets PYTHONHOME, so the Python paths are set after sourcing it.
        env = dict(os.environ)
        env["SWEEP_PYTHONPATH"] = ":".join(
            filter(None, [str(self.apicula), str(self.pydeps), env.get("PYTHONPATH")]))
        script = ('env_script=$1; shift; source "$env_script" && '
                  'export PYTHONHOME="$OSS_SUITE" PYTHONPATH="$SWEEP_PYTHONPATH" && exec "$@"')
        env["OSS_SUITE"] = str(self.suite)
        wrapped = ["bash", "-c", script, "sweep", str(self.suite / "environment"),
                   *map(str, argv)]
        start = time.monotonic()
        with open(log_path, "w") as log:
            proc = subprocess.Popen(wrapped, cwd=cwd, env=env, stdout=log,
                                    stderr=subprocess.STDOUT)
            _, status, usage = os.wait4(proc.pid, 0)
            proc.returncode = os.waitstatus_to_exitcode(status)
        return proc.returncode, time.monotonic() - start, usage.ru_maxrss / 1024


def synthesise(tools, design, name, params, out):
    out.mkdir(parents=True, exist_ok=True)
    reads = [f"read_verilog -lib {src.format(suite=tools.suite)}"
             for src in design.get("lib_sources", [])]
    reads += [f"read_verilog -sv {ROOT / src}" for src in design["sources"]]
    chparams = [f"chparam -set {key} {value} {design['top']}"
                for key, value in params.items()]
    script = "; ".join(reads + chparams + [
        f"synth_gowin -family {design['synth_family']} -top {design['top']}",
        f"write_json {out / 'synth.json'}",
    ])
    rc, seconds, _ = tools.run(["yosys", "-Q", "-T", "-q", "-p", script], out / "synth.log")
    if rc != 0:
        raise SystemExit(f"synthesis of variant {name} failed; see {out / 'synth.log'}")
    print(f"synthesised {name} in {seconds:.1f} s", flush=True)
    return out / "synth.json"


def parse_pnr(log_text, report_path, routed_path):
    row = {}
    errors = re.findall(r"^ERROR: (.*)$", log_text, re.M)
    row["reason"] = errors[0].rstrip(":") if errors else ""
    hold = re.search(r"^Info: (\d+) Hold/min time violations", log_text, re.M)
    row["hold_violations"] = int(hold[1]) if hold else 0
    wirelen = re.findall(r"wirelen = (\d+)", log_text)
    row["placed_wirelen"] = int(wirelen[-1]) if wirelen else ""
    arcs = re.search(r"^Info: Routing (\d+) arcs", log_text, re.M)
    row["routed_arcs"] = int(arcs[1]) if arcs else ""
    misses = collections.Counter(
        re.findall(r"Failed to route net '([^']+)' .* using dedicated routing", log_text))
    clocks = {}
    if report_path.exists():
        report = json.loads(report_path.read_text())
        clocks = report.get("fmax", {})
        for clock, fmax in clocks.items():
            row[f"fmax:{clock}"] = round(fmax["achieved"], 2)
        row["setup_failing_clocks"] = sum(
            1 for fmax in clocks.values() if fmax["achieved"] < fmax["constraint"])
        for cell, use in report.get("utilization", {}).items():
            if use.get("used"):
                row[f"used:{cell}"] = use["used"]
    for net, count in misses.items():
        row[f"dedicated_miss:{net}"] = count
    if routed_path.exists():
        nets = json.loads(routed_path.read_text())["modules"]
        nets = next(iter(nets.values()))["netnames"]
        for net in sorted(set(clocks) | set(misses)):
            routing = nets.get(net, {}).get("attributes", {}).get("ROUTING", "")
            if routing:
                row[f"route_pips:{net}"] = sum(
                    1 for pip in routing.split(";")[1::3] if pip)
    return row


def place_and_route(tools, design, synth_json, out, seed, extra):
    out.mkdir(parents=True, exist_ok=True)
    argv = [tools.nextpnr, "--json", synth_json, "--write", out / "routed.json",
            "--device", design["device"], "--freq", design["freq"],
            "--report", out / "timing.json", "--seed", seed]
    if design.get("cst"):
        argv += ["--vopt", f"cst={ROOT / design['cst']}"]
    if design.get("sdc"):
        argv += ["--sdc", ROOT / design["sdc"]]
    argv += extra
    rc, seconds, rss = tools.run(argv, out / "nextpnr.log")
    row = {"nextpnr_rc": rc, "pnr_s": round(seconds, 1), "pnr_mb": round(rss)}
    row.update(parse_pnr((out / "nextpnr.log").read_text(errors="replace"),
                         out / "timing.json", out / "routed.json"))
    row["status"] = "ok" if rc == 0 else "fail"
    return row


def pack(tools, design, out):
    rc, seconds, rss = tools.run(
        [tools.suite / "py3bin/python3", "-m", "apycula.gowin_pack", "-d", design["family"],
         "-o", out / "design.fs", out / "routed.json"], out / "pack.log")
    row = {"pack_rc": rc, "pack_s": round(seconds, 1), "pack_mb": round(rss)}
    if rc == 0:
        row["fs_sha256"] = hashlib.sha256((out / "design.fs").read_bytes()).hexdigest()
    return row


def summarise(rows, out):
    keys = ["variant", "seed", "status", "reason"]
    extra = sorted({key for row in rows for key in row} - set(keys))
    with open(out / "results.csv", "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=keys + extra)
        writer.writeheader()
        writer.writerows(rows)
    (out / "results.json").write_text(json.dumps(rows, indent=1) + "\n")

    fmax_keys = sorted(key for key in extra if key.startswith("fmax:"))
    miss_keys = sorted(key for key in extra if key.startswith("dedicated_miss:"))
    pip_keys = sorted(key for key in extra if key.startswith("route_pips:"))
    columns = (["variant", "seed", "status", "hold_violations"] + fmax_keys +
               ["placed_wirelen"] + miss_keys + pip_keys + ["pnr_s", "fs_sha256"])
    short = {key: key.split(":", 1)[-1] if ":" in key else key for key in columns}
    short.update({"hold_violations": "hold", "placed_wirelen": "wirelen"})
    short.update({key: "miss:" + key.split(":", 1)[1] for key in miss_keys})
    short.update({key: "pips:" + key.split(":", 1)[1] for key in pip_keys})
    table = [[short[key] for key in columns]]
    for row in rows:
        cells = []
        for key in columns:
            value = row.get(key, "")
            cells.append(str(value)[:12] if key == "fs_sha256" else str(value))
        table.append(cells)
    widths = [max(len(line[i]) for line in table) for i in range(len(columns))]
    lines = ["  ".join(cell.rjust(width) for cell, width in zip(line, widths))
             for line in table]

    lines.append("")
    for variant in dict.fromkeys(row["variant"] for row in rows):
        group = [row for row in rows if row["variant"] == variant]
        clean = [row for row in group if row["status"] == "ok"]
        parts = [f"{variant}: {len(clean)}/{len(group)} clean"]
        for key in fmax_keys:
            values = [row[key] for row in group if row.get(key) != "" and key in row]
            if values:
                parts.append(f"{key.split(':', 1)[1]} Fmax min {min(values)} "
                             f"median {statistics.median(values)} max {max(values)}")
        lines.append("; ".join(parts))
    text = "\n".join(lines) + "\n"
    (out / "summary.txt").write_text(text)
    print(text, end="")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("design", help="design description: a path, or a name in tools/designs")
    parser.add_argument("--variants", help="comma-separated variant names; default all")
    parser.add_argument("--seeds", default="1-16", help="seed list, e.g. 1-16 or 2,5,9-12")
    parser.add_argument("--jobs", type=int, default=16, help="parallel nextpnr runs")
    parser.add_argument("--pack", choices=("none", "clean", "all"), default="none",
                        help="pack no runs, runs that exited cleanly, or every routed run")
    parser.add_argument("--pack-jobs", type=int, default=4,
                        help="parallel packs; each needs about 2 GB")
    parser.add_argument("--nextpnr-arg", action="append", default=[], metavar="ARG",
                        help="extra nextpnr argument, repeatable; split as a shell word list")
    parser.add_argument("--out", type=pathlib.Path, help="output directory")
    args = parser.parse_args()

    design_path = pathlib.Path(args.design)
    if not design_path.exists():
        design_path = DESIGNS / f"{args.design}.json"
    design = json.loads(design_path.read_text())
    names = args.variants.split(",") if args.variants else list(design["variants"])
    unknown = set(names) - set(design["variants"])
    if unknown:
        raise SystemExit(f"unknown variants: {', '.join(sorted(unknown))}")
    seeds = parse_seeds(args.seeds)
    extra = [word for arg in args.nextpnr_arg for word in shlex.split(arg)]
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    out = args.out or ROOT / "build" / "sweep" / f"{design_path.stem}-{stamp}"
    out.mkdir(parents=True, exist_ok=True)
    tools = Tools()
    (out / "sweep.json").write_text(json.dumps({
        "design": str(design_path), "variants": names, "seeds": seeds,
        "nextpnr_args": extra, "pack": args.pack, "argv": sys.argv}, indent=1) + "\n")

    with concurrent.futures.ThreadPoolExecutor(args.jobs) as pool:
        synth = dict(zip(names, pool.map(
            lambda name: synthesise(tools, design, name, design["variants"][name],
                                    out / name),
            names)))

    rows = []
    packs = []
    lock = threading.Lock()
    started = time.monotonic()
    total = len(names) * len(seeds)
    with concurrent.futures.ThreadPoolExecutor(args.pack_jobs) as pack_pool:
        def build(name, seed):
            run_dir = out / name / f"seed{seed}"
            row = {"variant": name, "seed": seed}
            row.update(place_and_route(tools, design, synth[name], run_dir, seed, extra))
            with lock:
                rows.append(row)
                print(f"[{len(rows)}/{total} {time.monotonic() - started:.0f} s] "
                      f"{name} seed {seed}: {row['status']}"
                      f"{' (' + row['reason'] + ')' if row['reason'] else ''}", flush=True)
                if (args.pack == "all" and (run_dir / "routed.json").exists()) or \
                        (args.pack == "clean" and row["status"] == "ok"):
                    packs.append((row, pack_pool.submit(pack, tools, design, run_dir)))

        with concurrent.futures.ThreadPoolExecutor(args.jobs) as pnr_pool:
            for future in [pnr_pool.submit(build, name, seed)
                           for name in names for seed in seeds]:
                future.result()
        if packs:
            print(f"packing {len(packs)} runs, {args.pack_jobs} at a time", flush=True)
        for row, future in packs:
            row.update(future.result())

    rows.sort(key=lambda row: (names.index(row["variant"]), row["seed"]))
    print(f"\nresults in {out}\n")
    summarise(rows, out)


if __name__ == "__main__":
    main()
