## The cost of `arrows` compared with hand-written code. Run it with
## `nimble bench`, or with `nim c -r -d:release benchmarks/bench_overhead.nim`.
##
## In the first sections, each broker provider completes immediately, so the
## rows show only the cost of the plumbing. In the last section, each provider
## waits one turn of the event loop, as a provider that does input or output
## does.

import std/[monotimes, strutils, times]
import ../arrows

RequestBroker:
  proc Ping(n: int): Future[Result[int, string]] {.async.}

RequestBroker:
  proc Down(n: int): Future[Result[int, string]] {.async.}

RequestBroker:
  proc Later(n: int): Future[Result[int, string]] {.async.}

proc turn(): Future[void].Raising([CancelledError]) =
  ## Completes in the next turn of the event loop, without a timer.
  let fut = Future[void].Raising([CancelledError]).init("turn")
  proc fire(udata: pointer) {.gcsafe, raises: [].} =
    if not fut.finished():
      fut.complete()

  callSoon(fire, nil)
  fut

discard Ping.setProvider(
  proc(n: int): Future[Result[int, string]] {.async.} =
    ok(n + 1)
)
discard Down.setProvider(
  proc(n: int): Future[Result[int, string]] {.async.} =
    err("down")
)
discard Later.setProvider(
  proc(n: int): Future[Result[int, string]] {.async.} =
    await turn()
    return ok(n + 1)
)

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
      echo "  ", alignLeft(name, 44), align($(dt.inNanoseconds div n), 6), " ns/call"
      doAssert acc != 0

    waitFor go()

const N = 1_000_000
const M = 300_000

# 10 pure stages.
proc handPure(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  var v = x
  for k in 0 ..< 10:
    v = incf(v)
  ok(v)

var pure = arr(incf)
for k in 1 ..< 10:
  pure = pure >>> arr(incf)

echo "10 pure stages"
bench("hand-written async proc", N):
  acc += (await handPure(i)).get
bench("arrows, sync call", N):
  acc += pure(i).get
bench("arrows, await answerOf", N):
  acc += (await answerOf(pure, i)).get

# 3 ports.
proc handPorts(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = (await Ping.request(x)).valueOr:
    return err(error)
  let b = (await Ping.request(a)).valueOr:
    return err(error)
  await Ping.request(b)

let ports3 = Ping.arrow >>> Ping.arrow >>> Ping.arrow

echo "3 ports"
bench("hand-written", M):
  acc += (await handPorts(i)).get
bench("arrows", M):
  acc += (await ports3(i)).get

# 4 pure stages and 2 ports.
proc handMixed(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = (await Ping.request(incf(x))).valueOr:
    return err(error)
  let b = (await Ping.request(incf(incf(a)))).valueOr:
    return err(error)
  ok(incf(b))

let mixed =
  arr(incf) >>> Ping.arrow >>> arr(incf) >>> arr(incf) >>> Ping.arrow >>> arr(incf)

echo "4 pure stages and 2 ports"
bench("hand-written", M):
  acc += (await handMixed(i)).get
bench("arrows", M):
  acc += (await mixed(i)).get

# A fallback where the first two ports fail.
proc handFallback(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = await Down.request(x)
  if a.isOk:
    return a
  let b = await Down.request(x)
  if b.isOk:
    return b
  await Ping.request(x)

let fallback = Down.arrow.orElse(Down.arrow).orElse(Ping.arrow)

echo "fallback: two ports fail, the third port answers"
bench("hand-written", M):
  acc += (await handFallback(i)).get
bench("arrows", M):
  acc += (await fallback(i)).get

# Middleware around one port.
let guarded = retry(within(Ping.arrow, chronos.seconds(1)), 3).label("ping")

echo "transformers: label (retry (within port))"
bench("bare request", M):
  acc += (await Ping.request(i)).get
bench("arrows", M):
  acc += (await guarded(i)).get

# The same pipelines, with providers that wait one turn of the event loop.
proc handPortsLater(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = (await Later.request(x)).valueOr:
    return err(error)
  let b = (await Later.request(a)).valueOr:
    return err(error)
  await Later.request(b)

proc handMixedLater(x: int): Future[Result[int, string]] {.async: (raises: []).} =
  let a = (await Later.request(incf(x))).valueOr:
    return err(error)
  let b = (await Later.request(incf(incf(a)))).valueOr:
    return err(error)
  ok(incf(b))

let ports3Later = Later.arrow >>> Later.arrow >>> Later.arrow
let mixedLater =
  arr(incf) >>> Later.arrow >>> arr(incf) >>> arr(incf) >>> Later.arrow >>> arr(incf)
let guardedLater = retry(within(Later.arrow, chronos.seconds(1)), 3).label("later")

echo "providers that wait one turn of the event loop"
bench("bare request", M):
  acc += (await Later.request(i)).get
bench("3 ports, hand-written", M):
  acc += (await handPortsLater(i)).get
bench("3 ports, arrows", M):
  acc += (await ports3Later(i)).get
bench("4 pure stages and 2 ports, hand-written", M):
  acc += (await handMixedLater(i)).get
bench("4 pure stages and 2 ports, arrows", M):
  acc += (await mixedLater(i)).get
bench("label (retry (within port)), arrows", M):
  acc += (await guardedLater(i)).get
