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
  # This thread makes its own arrow of the edge, and composes it.
  let pipeline =
    arr(
      proc(x: int): int =
        x + 1
    ) >>> MtDouble.arrow >>> MtDouble.arrow
  let r = waitFor pipeline(5)
  gResult.store(if r.isOk: r.get else: -1)
  gDone.store(true)

proc failingWorker() {.thread.} =
  let r = waitFor (MtDouble.arrow <+> zeroArrow[int, int]("no provider"))(1)
  gFellBack.store(r.isErr and r.error == "no provider")
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
  test "a worker thread composes an mt edge that the main thread provides":
    check MtDouble.provide(later(times2)).isOk
    check runInThread(pipelineWorker)
    check gResult.load() == 24
    MtDouble.clearProvider()

  test "an mt edge without a provider gives err in the other thread":
    check runInThread(failingWorker)
    check gFellBack.load()
