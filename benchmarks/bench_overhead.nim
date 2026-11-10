## The cost of `arrows` compared with hand-written code. Run it with
## `nimble bench`, or with `nim c -r -d:release benchmarks/bench_overhead.nim`.
##
## The `naive` rows use a design with one async closure for each stage. The
## `arrows` rows use this library. The broker providers complete immediately,
## so the rows show only the cost of the plumbing.

import std/[monotimes, strutils, times]
import ../arrows

RequestBroker:
  proc Ping(n: int): Future[Result[int, string]] {.async.}

RequestBroker:
  proc Down(n: int): Future[Result[int, string]] {.async.}

discard Ping.setProvider(
  proc(n: int): Future[Result[int, string]] {.async.} =
    ok(n + 1)
)
discard Down.setProvider(
  proc(n: int): Future[Result[int, string]] {.async.} =
    err("down")
)

# --- The naive design, with an async closure for each stage -------------------

type Naive[A, B] = proc(a: A): Future[Result[B, string]] {.gcsafe.}

proc naiveArr[A, B](f: proc(a: A): B {.gcsafe, raises: [].}): Naive[A, B] =
  result = proc(a: A): Future[Result[B, string]] {.async, gcsafe.} =
    ok(f(a))

proc naiveThen[A, B, C](f: Naive[A, B], g: Naive[B, C]): Naive[A, C] =
  result = proc(a: A): Future[Result[C, string]] {.async, gcsafe.} =
    let b = (await f(a)).valueOr:
      return err(error)
    await g(b)

proc naiveEdge(): Naive[int, int] =
  result = proc(x: int): Future[Result[int, string]] {.async, gcsafe.} =
    await Ping.request(x)

# --- Harness ------------------------------------------------------------------

proc incf(x: int): int {.gcsafe, raises: [].} =
  x + 1

template bench(name: string, n: int, body: untyped) =
  block:
    proc go(): Future[void] {.async.} =
      var acc {.inject.} = 0
      let t0 = getMonoTime()
      for i {.inject.} in 0 ..< n:
        {.cast(gcsafe).}:
          body
      let dt = getMonoTime() - t0
      echo "  ", alignLeft(name, 40), align($(dt.inNanoseconds div n), 6), " ns/call"
      doAssert acc != 0

    waitFor go()

const N = 1_000_000
const M = 300_000

# 10 pure stages.
proc handPureAsync(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  var v = x
  for k in 0 ..< 10:
    v = incf(v)
  ok(v)

var naivePure = naiveArr(incf)
var pure = arr(incf)
for k in 1 ..< 10:
  naivePure = naiveThen(naivePure, naiveArr(incf))
  pure = pure >>> arr(incf)

echo "10 pure stages"
bench("hand-written async proc", N):
  acc += (await handPureAsync(i)).get
bench("naive", N):
  acc += (await naivePure(i)).get
bench("arrows (a SyncArrow, sync call)", N):
  acc += pure(i).get
bench("arrows (await answerOf)", N):
  acc += (await answerOf(pure, i)).get

# 3 broker edges.
proc handEdges(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = (await Ping.request(x)).valueOr:
    return err(error)
  let b = (await Ping.request(a)).valueOr:
    return err(error)
  await Ping.request(b)

let naiveE = naiveEdge()
let naive3 = naiveThen(naiveThen(naiveE, naiveE), naiveE)
let edges3 = Ping.arrow >>> Ping.arrow >>> Ping.arrow

echo "3 broker edges"
bench("hand-written awaits", M):
  acc += (await handEdges(i)).get
bench("naive", M):
  acc += (await naive3(i)).get
bench("arrows", M):
  acc += (await edges3(i)).get

# 4 pure stages and 2 broker edges.
proc handMixed(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = (await Ping.request(incf(x))).valueOr:
    return err(error)
  let b = (await Ping.request(incf(incf(a)))).valueOr:
    return err(error)
  ok(incf(b))

let naiveMixed = naiveThen(
  naiveThen(
    naiveThen(
      naiveThen(naiveThen(naiveArr(incf), naiveE), naiveArr(incf)), naiveArr(incf)
    ),
    naiveE,
  ),
  naiveArr(incf),
)
let mixed =
  arr(incf) >>> Ping.arrow >>> arr(incf) >>> arr(incf) >>> Ping.arrow >>> arr(incf)

echo "4 pure stages and 2 broker edges"
bench("hand-written", M):
  acc += (await handMixed(i)).get
bench("naive", M):
  acc += (await naiveMixed(i)).get
bench("arrows", M):
  acc += (await mixed(i)).get

# A fallback chain where the first two edges fail.
proc handFallback(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = await Down.request(x)
  if a.isOk:
    return a
  let b = await Down.request(x)
  if b.isOk:
    return b
  await Ping.request(x)

let fallback = Down.arrow <+> Down.arrow <+> Ping.arrow

echo "fallback: two edges fail, the third answers"
bench("hand-written", M):
  acc += (await handFallback(i)).get
bench("arrows (<+>)", M):
  acc += (await fallback(i)).get

# Middleware around one edge.
let guarded = retry(within(Ping.arrow, chronos.seconds(1)), 3).label("ping")

echo "middleware: label (retry (within edge))"
bench("bare edge", M):
  acc += (await Ping.request(i)).get
bench("arrows", M):
  acc += (await guarded(i)).get

# Fan-out of a 1 KiB message to two stages. The loop takes the two messages
# in turn, so the C compiler can not move the work out of the loop.
type Message = object
  payload: seq[byte]

proc payloadSize(m: Message): int {.gcsafe, raises: [].} =
  m.payload.len

let messages =
  [Message(payload: newSeq[byte](1024)), Message(payload: newSeq[byte](512))]
let dupFan =
  arr(
    proc(m: Message): Pair[Message, Message] {.gcsafe, raises: [].} =
      (fst: m, snd: m)
  ) >>> (arr(payloadSize) *** arr(payloadSize))
let fan = arr(payloadSize) &&& arr(payloadSize)

echo "fan-out of a 1 KiB message to two stages"
bench("hand-written", N):
  acc += payloadSize(messages[i and 1]) + payloadSize(messages[i and 1])
bench("copying, arr dup >>> (f *** g)", N):
  let p = dupFan(messages[i and 1]).get
  acc += p.fst + p.snd
bench("arrows (&&&)", N):
  let p = fan(messages[i and 1]).get
  acc += p.fst + p.snd
