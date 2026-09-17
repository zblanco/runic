"""Serialized, reproducible invocation of the common harness in one worktree."""
import argparse
import pathlib
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("worktree")
parser.add_argument("label")
parser.add_argument("output")
parser.add_argument("--coordination", default="legacy")
parser.add_argument("--max-size", default="2048")
parser.add_argument("--group", choices=["standard", "scale", "bounded"], default="standard")
args = parser.parse_args()
harness = pathlib.Path(__file__).resolve().with_name("run.exs")
output = pathlib.Path(args.output).resolve()
output.mkdir(parents=True, exist_ok=True)

if args.group == "standard":
    jobs = [
        ("inline", ["--cases", "collect,sum,deep,binary,repeated,stream"]),
        ("task", ["--execution", "task", "--cases", "collect,sum,deep,binary,repeated,stream"]),
        ("peer", ["--execution", "peer_tcp", "--cases", "collect,sum,binary", "--pass", "timing"]),
    ]
elif args.group == "scale":
    jobs = [("scale", ["--sizes", args.max_size, "--cases", "collect,sum"])]
else:
    jobs = [
        ("bounded-inline", ["--preparation", "bounded", "--cases", "collect,sum,deep,binary,repeated,stream"]),
        ("bounded-task", ["--preparation", "bounded", "--execution", "task", "--cases", "collect,sum,deep,binary,repeated,stream"]),
    ]

for suffix, options in jobs:
    dest = output / f"{args.label}-{suffix}.csv"
    # Never silently overwrite completed evidence.
    if dest.exists():
        raise SystemExit(f"output already exists: {dest}")
    command = ["mix", "run", str(harness), "--label", args.label,
               "--coordination", args.coordination, *options]
    print("START", args.label, suffix, flush=True)
    with dest.open("w") as stdout, dest.with_suffix(".stderr.txt").open("w") as stderr:
        result = subprocess.run(command, cwd=args.worktree, stdout=stdout, stderr=stderr)
    if result.returncode:
        raise SystemExit(f"FAILED {args.label} {suffix}: see {dest.with_suffix('.stderr.txt')}")
    print("DONE", args.label, suffix, flush=True)
