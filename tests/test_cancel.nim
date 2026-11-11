## The cancel contract. A combinator that waits and gets a cancel answers
## `err("cancelled")` at once. It sends the cancel to the stage that runs, and
## it starts no new stage. A test cancels a run while a stage of the run
## waits, and then checks that no other stage starts. The last suite checks an
## inner `Answer` in the cancelled state.
##
## A stubborn stage does not stop when it gets a cancel. With a stubborn stage,
## a test shows that the combinator stops by itself.

import std/strutils
import ./helpers

proc stubborn(starts: ref int, ms: int, fail = false): Arrow[int, int] =
  ## Adds 1 to `starts`, waits `ms` also after a cancel, and then answers.
  result = proc(x: int): Future[Result[int, string]] {.async: (raises: []).} =
    inc starts[]
    try:
      await sleepAsync(chronos.milliseconds(ms))
    except CancelledError:
      discard
    if fail:
      return err("failed")
    return ok(x)

proc slowToStop(starts, running, most: ref int): Arrow[int, int] =
  ## Waits 40 ms and then fails. After a cancel, it takes 30 ms more to stop.
  ## `running` is the number of runs in progress, and `most` is its maximum.
  result = proc(x: int): Future[Result[int, string]] {.async: (raises: []).} =
    inc starts[]
    inc running[]
    most[] = max(most[], running[])
    try:
      await sleepAsync(chronos.milliseconds(40))
    except CancelledError:
      await noCancel sleepAsync(chronos.milliseconds(30))
    dec running[]
    return err("stopped")

proc counter(starts: ref int): SyncArrow[int, int] =
  result = proc(x: int): Result[int, string] =
    inc starts[]
    ok(x)

template cancelWhileRunning(fut: untyped) =
  ## Cancels `fut` 10 ms after its start. The answer must be
  ## `err("cancelled")`, and it must come long before the 60 ms stage ends.
  waitFor sleepAsync(chronos.milliseconds(10))
  fut.cancelSoon()
  let t0 = Moment.now()
  let r = waitFor fut
  check r.isErr
  check r.error == "cancelled"
  check Moment.now() - t0 < chronos.milliseconds(30)
  # Time for any work that starts after the cancel.
  waitFor sleepAsync(chronos.milliseconds(100))

EventBroker:
  type Tick = object
    n*: int

suite "a cancel stops the core combinators":
  test ">>> starts no next stage":
    let s1 = new int
    let s2 = new int
    let fut = (stubborn(s1, 60) >>> stubborn(s2, 1))(1)
    cancelWhileRunning(fut)
    check s1[] == 1
    check s2[] == 0

  test ">>> does not run a next sync stage":
    let s1 = new int
    let s2 = new int
    let fut = (stubborn(s1, 60) >>> counter(s2))(1)
    cancelWhileRunning(fut)
    check s2[] == 0

  test "orElse starts no fallback":
    let s1 = new int
    let s2 = new int
    let fut = stubborn(s1, 60, fail = true).orElse(stubborn(s2, 1))(1)
    cancelWhileRunning(fut)
    check s2[] == 0

  test "orElse answers at once to a cancel in its second stage":
    let s1 = new int
    let s2 = new int
    let failNow: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("no")
    # The first stage fails after a wait.
    let afterWait = stubborn(s1, 1, fail = true).orElse(stubborn(s2, 60))(1)
    cancelWhileRunning(afterWait)
    # The first stage fails immediately, as a sync stage and as an async stage.
    let afterSync = failNow.orElse(stubborn(s2, 60))(1)
    cancelWhileRunning(afterSync)
    let afterNow = now(failNow).orElse(stubborn(s2, 60))(1)
    cancelWhileRunning(afterNow)
    check s2[] == 3

  test "a combinator that gives the future of a stage sends the cancel to it":
    # The first stage is a sync stage, so `>>>` gives the future of the
    # second stage as its answer.
    let done = new int
    let fut = (plus1 >>> sleeper(plus1, 60, done))(1)
    cancelWhileRunning(fut)
    check done[] == 0

  test "catching answers at once":
    let c = catching[int, int](
      proc(x: int): Future[Result[int, string]] {.async.} =
        await sleepAsync(chronos.milliseconds(60))
        return ok(x)
    )
    let fut = c(1)
    cancelWhileRunning(fut)

suite "a cancel stops the transformers":
  test "timed reports the run, and answers at once":
    scoped:
      let reports = new int
      let s1 = new int
      let t = timed(
        stubborn(s1, 60),
        proc(d: Duration) =
          inc(reports[]),
      )
      let fut = t(1)
      cancelWhileRunning(fut)
      check reports[] == 1

  test "retry makes no new attempt after a cancel in an attempt":
    let s1 = new int
    let fut = retry(stubborn(s1, 60, fail = true), 5)(1)
    cancelWhileRunning(fut)
    check s1[] == 1

  test "retry makes no new attempt after a cancel in a pause":
    let s1 = new int
    let fut = retry(stubborn(s1, 1, fail = true), 5, chronos.milliseconds(60))(1)
    cancelWhileRunning(fut)
    check s1[] == 1

  test "recover does not recover a cancel":
    let s1 = new int
    let rec = recover(
      stubborn(s1, 60, fail = true),
      proc(x: int, e: string): Result[int, string] =
        ok(-1),
    )
    let fut = rec(1)
    cancelWhileRunning(fut)

  test "mapErr and label do not change a cancel":
    let s1 = new int
    let fut = stubborn(s1, 60).label("stage")(1)
    cancelWhileRunning(fut)

  test "within answers at once to a cancel from outside":
    let done = new int
    let fut = within(sleeper(plus1, 60, done), chronos.seconds(2))(1)
    cancelWhileRunning(fut)
    check done[] == 0

suite "a stage that goes on after a cancel":
  # A cancel tells a stage to stop. A combinator does not wait until the stage
  # stops, and the work that the stage did stays done.
  test "retry after within starts a new run before the cancelled run stops":
    let starts = new int
    let running = new int
    let most = new int
    let f =
      retry(within(slowToStop(starts, running, most), chronos.milliseconds(10)), 3)
    check "timed out" in run(f, 1).error
    check starts[] == 3
    check most[] == 3
    waitFor sleepAsync(chronos.milliseconds(100))
    check running[] == 0

  test "a fallback after within runs before the cancelled stage stops":
    let starts = new int
    let running = new int
    let most = new int
    let f =
      within(slowToStop(starts, running, most), chronos.milliseconds(10)).orElse(plus1)
    check run(f, 1).get == 2
    check starts[] == 1
    check running[] == 1
    waitFor sleepAsync(chronos.milliseconds(100))
    check running[] == 0

suite "a cancel stops the concurrency combinators and drive":
  test "both, all, firstOk and mapAll answer at once, and cancel their runs":
    let done = new int
    let b = both(sleeper(plus1, 60, done), sleeper(plus1, 60, done))(1)
    cancelWhileRunning(b)
    let a = all(@[sleeper(plus1, 60, done), sleeper(plus1, 60, done)])(1)
    cancelWhileRunning(a)
    let f = firstOk(@[sleeper(plus1, 60, done), sleeper(plus1, 60, done)])(1)
    cancelWhileRunning(f)
    let m = mapAll(sleeper(plus1, 60, done))(@[1, 2, 3])
    cancelWhileRunning(m)
    check done[] == 0

  test "mapSeq starts no next item":
    let s1 = new int
    let fut = mapSeq(stubborn(s1, 60))(@[1, 2, 3])
    cancelWhileRunning(fut)
    check s1[] == 1

  test "drive cancels the run when the listener stops, and reports no error":
    scoped:
      let errors = new seq[string]
      let done = new int
      let sink: ErrorSink = proc(e: string) =
        errors[].add(e)
      let slow = sleeper(
        arr(
          proc(t: Tick): int =
            t.n
        ),
        100,
        done,
      )
      check Tick.drive(slow, sink).isOk
      Tick.emit(Tick(n: 1))
      waitFor sleepAsync(chronos.milliseconds(10))
      waitFor Tick.dropAllListeners()
      waitFor sleepAsync(chronos.milliseconds(150))
      check errors[].len == 0
      check done[] == 0

  test "a run that finishes in the turn of the stop of its listener is no error":
    scoped:
      let errors = new seq[string]
      let pending = new seq[Answer[int]]
      let sink: ErrorSink = proc(e: string) =
        errors[].add(e)
      let manual: Arrow[Tick, int] = proc(t: Tick): Answer[int] =
        pending[].add(Answer[int].init("manual", {FutureFlag.OwnCancelSchedule}))
        pending[][^1]
      check Tick.drive(manual, sink).isOk
      Tick.emit(Tick(n: 1))
      waitFor sleepAsync(chronos.milliseconds(10))
      check pending[].len == 1
      # The answer completes. The listener stops before the event loop runs the
      # callback of the answer.
      pending[][0].complete(Result[int, string].err("late"))
      let stop = Tick.dropAllListeners()
      waitFor stop
      waitFor sleepAsync(chronos.milliseconds(10))
      check errors[].len == 0

suite "an Answer in the cancelled state":
  # The combinators treat an inner `Answer` in the cancelled state as a
  # failure of that stage, and they do not wait without end.
  test "the waiting combinators give err":
    let b = broken()
    check bounded(b >>> plus1, 1).error == "cancelled"
    check bounded(b >>> later(plus1), 1).error == "cancelled"
    check bounded(within(b, chronos.seconds(1)), 1).error == "cancelled"
    check bounded(retry(b, 2), 1).error == "cancelled"
    check bounded(mapSeq(b), @[1, 2]).error == "cancelled"
    check bounded(
      timed(
        b,
        proc(d: Duration) =
          discard,
      ),
      1,
    ).error == "cancelled"

  test "a fallback and a recovery treat it as a failure of the stage":
    let b = broken()
    let fallback: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("fallback")
    check bounded(b.orElse(fallback), 1).error == "cancelled | fallback"
    check bounded(
      recover(
        b,
        proc(x: int, e: string): Result[int, string] =
          ok(-1),
      ),
      1,
    ).get == -1
    check bounded(
      mapErr(
        b,
        proc(e: string): string =
          "inner " & e,
      ),
      1,
    ).error == "inner cancelled"

suite "exceptions and memory":
  # With ORC, Nim 2.2.4 to 2.2.10 leak each exception that a closure iterator
  # catches after a `yield` (Nim issue #23615, fixed in Nim 2.2.12). An async
  # proc is a closure iterator. Thus the waits of the library do not raise. They
  # use `awaitne` and read the state of the future.
  const librarySources = [
    staticRead("../arrows/core.nim"),
    staticRead("../arrows/transformers.nim"),
    staticRead("../arrows/concurrent.nim"),
    staticRead("../arrows/brokers.nim"),
    staticRead("../arrows/private/answers.nim"),
  ]

  test "the library catches no exception":
    for src in librarySources:
      for line in src.splitLines:
        check not line.strip.startsWith("except")

  when defined(gcOrc):
    proc pendingAnswer[B](): Answer[B] =
      ## Completes with `err` only when it gets a cancel. It makes no exception.
      let fut = Answer[B].init("pending", {FutureFlag.OwnCancelSchedule})
      fut.cancelCallback = proc(udata: pointer) {.gcsafe, raises: [].} =
        fut.complete(Result[B, string].err("cancelled"))
      fut

    proc soonErr(): Answer[int] =
      ## Completes with `err` on the next turn of the event loop.
      let fut = Answer[int].init("soonErr", {FutureFlag.OwnCancelSchedule})
      proc fire(udata: pointer) {.gcsafe, raises: [].} =
        if not fut.finished():
          fut.complete(Result[int, string].err("e"))

      fut.cancelCallback = proc(udata: pointer) {.gcsafe, raises: [].} =
        if not fut.finished():
          fut.complete(Result[int, string].err("cancelled"))
      callSoon(fire, nil)
      fut

    let waits: Arrow[int, int] = proc(x: int): Answer[int] =
      pendingAnswer[int]()
    let failsSoon: Arrow[int, int] = proc(x: int): Answer[int] =
      soonErr()

    proc bytesPerRun(run: proc()): int =
      ## The growth of the occupied memory for each run, after a first set of
      ## runs that fills the caches.
      for i in 0 ..< 500:
        run()
      GC_fullCollect()
      let before = getOccupiedMem()
      for i in 0 ..< 5000:
        run()
      GC_fullCollect()
      (getOccupiedMem() - before) div 5000

    proc cancelOf(fut: Answer[int], turns = 0) =
      for i in 0 ..< turns:
        waitFor sleepAsync(chronos.milliseconds(0))
      fut.cancelSoon()
      discard waitFor fut

    test "a cancel of a run that waits frees its memory":
      let then = waits >>> plus1
      let pause = retry(failsSoon, 3, chronos.milliseconds(50))
      let limit = within(waits, chronos.seconds(1))
      check bytesPerRun(
        proc() =
          cancelOf(then(1))
      ) < 16
      check bytesPerRun(
        proc() =
          cancelOf(pause(1), turns = 1)
      ) < 16
      check bytesPerRun(
        proc() =
          cancelOf(limit(1))
      ) < 16

    test "a failure in catching frees its memory":
      let failing = proc(x: int): Future[Result[int, string]] {.gcsafe, raises: [].} =
        let fut = newFuture[Result[int, string]]("failing")
        proc fire(udata: pointer) {.gcsafe, raises: [].} =
          fut.fail(newException(ValueError, "boom"))

        callSoon(fire, nil)
        fut
      let c = catching[int, int](failing)
      check run(c, 1).error == "boom"
      check bytesPerRun(
        proc() =
          discard waitFor c(1)
      ) < 16
