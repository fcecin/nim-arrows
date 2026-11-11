## Arrows and threads. An arrow is a closure, so each thread makes its own
## arrows. A multi-thread broker (`RequestBroker(mt)`) connects the threads.
## Its provider runs in the thread that set it, and that thread keeps its
## event loop running.

import std/atomics
import ./helpers

RequestBroker(mt):
  proc MtDouble(n: int): Future[Result[int, string]] {.async.}

var gDone: Atomic[bool]
var gResult: Atomic[int]
var gFellBack: Atomic[bool]

proc pipelineWorker() {.thread.} =
  # This thread makes its own arrow of the port, and composes it.
  let pipeline =
    arr(
      proc(x: int): int =
        x + 1
    ) >>> MtDouble.arrow >>> MtDouble.arrow
  let r = waitFor pipeline(5)
  gResult.store(if r.isOk: r.get else: -1)
  gDone.store(true)

proc failingWorker() {.thread.} =
  # The port has no provider, so the fallback of this thread answers.
  let r = waitFor MtDouble.arrow.orElse(
    arr(
      proc(x: int): int =
        -x
    )
  )(1)
  gFellBack.store(r.isOk and r.get == -1)
  gDone.store(true)

proc runInThread(worker: proc() {.thread, nimcall.}): bool =
  ## Starts `worker` and keeps the event loop of this thread running, so
  ## that the provider in this thread can answer. Gives false when the
  ## worker does not finish in 5 s.
  gDone.store(false)
  var t: Thread[void]
  t.createThread(worker)
  let deadline = Moment.now() + chronos.seconds(5)
  while not gDone.load() and Moment.now() < deadline:
    waitFor sleepAsync(chronos.milliseconds(2))
  if not gDone.load():
    return false
  t.joinThread()
  true

suite "threads":
  test "a worker thread composes an mt port that the main thread provides":
    check MtDouble.provide(later(times2)).isOk
    check runInThread(pipelineWorker)
    check gResult.load() == 24
    MtDouble.clearProvider()

  test "an mt port without a provider gives err, and a fallback answers":
    check runInThread(failingWorker)
    check gFellBack.load()
