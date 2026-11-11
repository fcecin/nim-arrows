import std/strutils

# Package
version = "0.2.0"
author = "Fabiana Cecin"
description = "Arrows for nim-brokers: typed connections that compose."
license = "Unlicense"
skipDirs = @["tests", "examples", "benchmarks"]

# Dependencies
requires "nim >= 2.2.4"
requires "chronos >= 4.4.0"
requires "results >= 0.5.1"
requires "brokers >= 3.4.0"

const tests = [
  "test_laws", "test_operations", "test_transformers", "test_concurrent", "test_brokers",
  "test_ports", "test_threads", "test_cancel", "test_scope", "test_readme",
]

task test, "Run the test suites":
  for t in tests:
    exec "nim c -r --outdir:build --hints:off tests/" & t & ".nim"

task examples, "Compile and run the examples, and compare their output":
  for ex in [
    "e01_ports", "e02_transformers", "e03_events", "e04_routing", "e05_links",
    "e06_adapters",
  ]:
    exec "nim c --outdir:build --hints:off examples/" & ex & ".nim"
    let (output, code) = gorgeEx("build/" & ex)
    if code != 0:
      quit("examples/" & ex & ".nim exited with " & $code)
    var lines: seq[string]
    for line in output.splitLines:
      # A line with "took" shows a time, and a time changes from run to run.
      if "took" notin line:
        lines.add(line)
    if lines.join("\n").strip != readFile("examples/expected/" & ex & ".txt").strip:
      echo output
      quit("examples/" & ex & ".nim does not give examples/expected/" & ex & ".txt")
    echo ex, " gives the expected output"

task bench, "Run the overhead benchmark (release build)":
  exec "nim c -r -d:release --outdir:build --hints:off benchmarks/bench_overhead.nim"
