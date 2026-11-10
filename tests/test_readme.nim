## The README. Its code blocks compile here, and the claims of its text hold.
## A test makes sure that each code block of `README.md` is in this file. The
## blocks are in this file without their `import` line.

import std/strutils
import ./helpers

type
  Envelope = object
    topic: string

  Stamped = object
    env: Envelope

  Route = object
    at, dst: string
    path: seq[string]

RequestBroker:
  proc RelayPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc LightpushPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc NextHop(at: string, dst: string): Future[Result[string, string]] {.async.}

# The first code block of the README.

# Each broker is an edge between nodes. It is a plain nim-brokers declaration.
RequestBroker(sync):
  proc Validate(env: Envelope): Result[Envelope, string]
RequestBroker:
  proc Stamp(env: Envelope): Future[Result[Stamped, string]] {.async.}
RequestBroker:
  proc Publish(msg: Stamped): Future[Result[string, string]] {.async.}
RequestBroker:
  proc Send(env: Envelope): Future[Result[string, string]] {.async.}

# One line makes a new edge from three edges. The compiler checks each seam.
discard Send.provide(Validate.arrow >>> Stamp.arrow >>> Publish.arrow)

# Middleware around an edge, with no change to its provider.
let relay = RelayPublish.arrow.retry(3, 5.milliseconds, 2).within(200.milliseconds)
let sendAny = relay <+> LightpushPublish.arrow

# The second code block of the README.

let hop: Arrow[Route, Either[Route, seq[string]]] = proc(
    r: Route
): Future[Result[Either[Route, seq[string]], string]] {.async: (raises: []).} =
  if r.at == r.dst:
    return finishWith(r.path)
  let next = (await NextHop.request(r.at, r.dst)).valueOr:
    return err(error)
  return again(Route(at: next, dst: r.dst, path: r.path & next))
let route = iterate(hop, limit = 8)

# The third code block of the README.

let numbered = feedback(
  0,
  arr(
    proc(p: Pair[string, int]): Pair[string, int] =
      (fst: $(p.snd + 1) & ": " & p.fst, snd: p.snd + 1)
  ),
)
# numbered("hello") gives ok("1: hello"), and numbered("world") gives ok("2: world").

proc nimBlocks(md: string): seq[string] =
  ## The `nim` code blocks of a Markdown text, without their `import` lines.
  var inNim, inOther = false
  var lines: seq[string]
  for line in md.splitLines:
    if line.startsWith("```"):
      if inNim:
        result.add(lines.join("\n"))
        lines.setLen(0)
        inNim = false
      elif inOther:
        inOther = false
      elif line.strip == "```nim":
        inNim = true
      else:
        inOther = true
    elif inNim and not line.startsWith("import "):
      lines.add(line)

suite "README":
  test "each code block of the README is in this file":
    const readme = staticRead("../README.md")
    const self = staticRead("test_readme.nim")
    let blocks = nimBlocks(readme)
    check blocks.len == 3
    for b in blocks:
      check b.strip in self

  test "the third code block gives the answers that its comment tells":
    check numbered("hello").get == "1: hello"
    check numbered("world").get == "2: world"

  test "the second code block routes a message through the edge":
    proc link(at: string): string =
      case at
      of "a": "b"
      of "b": "c"
      of "c": "d"
      else: ""

    discard NextHop.setProvider(
      proc(at: string, dst: string): Future[Result[string, string]] {.async.} =
        await sleepAsync(chronos.milliseconds(1))
        if link(at).len == 0:
          return err("no link from " & at)
        return ok(link(at))
    )
    check run(route, Route(at: "a", dst: "d", path: @["a"])).get == @[
      "a", "b", "c", "d"
    ]
    check run(route, Route(at: "a", dst: "z", path: @["a"])).error == "no link from d"

  test "the operators accept the two kinds, and give a sync arrow only for sync inputs":
    let s = plus1
    let a = now(plus1)
    let e = arr(
      proc(x: Either[int, int]): Either[int, int] =
        x
    )
    check (s >>> s) is SyncArrow[int, int]
    check (s >>> a) is Arrow[int, int]
    check (a >>> s) is Arrow[int, int]
    check (a <<< a) is Arrow[int, int]
    check (s *** s) is SyncArrow[Pair[int, int], Pair[int, int]]
    check (s *** a) is Arrow[Pair[int, int], Pair[int, int]]
    check (a &&& s) is Arrow[int, Pair[int, int]]
    check (s +++ s) is SyncArrow[Either[int, int], Either[int, int]]
    check (a +++ s) is Arrow[Either[int, int], Either[int, int]]
    check (s ||| s) is SyncArrow[Either[int, int], int]
    check (s ||| a) is Arrow[Either[int, int], int]
    check (s <+> s) is SyncArrow[int, int]
    check (s <+> a) is Arrow[int, int]
    check s.orElse(a) is Arrow[int, int]
    check (e >>> (s ||| s)) is SyncArrow[Either[int, int], int]

  test "some procs take explicit generic parameters":
    let f = plus1
    check compiles(idArrow[int]())
    check compiles(zeroArrow[int, int]())
    check compiles(toLeft[int, string](1))
    check compiles(app[int, int]())
    check first[int, int, string](f)((fst: 1, snd: "s")).get == (fst: 2, snd: "s")
    check second[int, int, string](f)((fst: "s", snd: 1)).get == (fst: "s", snd: 2)
    check left[int, int, string](f)(toLeft[int, string](1)).get == toLeft[int, string](
      2
    )
    check right[int, int, string](f)(toRight[string, int](1)).get ==
      toRight[string, int](2)
    check not compiles(first(f))
