## The cancel contract. A combinator that waits and gets a cancel answers
## `err("cancelled")` at once. It sends the cancel to the stage that runs, and
## it starts no new stage. A test cancels a run while a stage of the run
## waits, and then checks that no other stage starts. The last suite checks an
## inner `Answer` in the cancelled state.
##
## A stubborn stage does not stop when it gets a cancel. With a stubborn stage,
## a test shows that the combinator stops by itself. A combinator that gives
## the future of a stage, as `|||` does, sends the cancel to that stage.
## `feedback` waits for a step that runs, because the step must finish with
## the state.

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

suite "a cancel stops the core and choice combinators":
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

  test "*** and &&& start no second stage":
    let s1 = new int
    let s2 = new int
    let split = (stubborn(s1, 60) *** stubborn(s2, 1))((fst: 1, snd: 2))
    cancelWhileRunning(split)
    let fan = (stubborn(s1, 60) &&& stubborn(s2, 1))(1)
    cancelWhileRunning(fan)
    check s1[] == 2
    check s2[] == 0

  test "first and second answer at once":
    let s1 = new int
    let f = first[int, int, string](stubborn(s1, 60))((fst: 1, snd: "x"))
    cancelWhileRunning(f)
    let g = second[int, int, string](stubborn(s1, 60))((fst: "x", snd: 1))
    cancelWhileRunning(g)

  test "<+> starts no fallback":
    let s1 = new int
    let s2 = new int
    let fut = (stubborn(s1, 60, fail = true) <+> stubborn(s2, 1))(1)
    cancelWhileRunning(fut)
    check s2[] == 0

  test "left, right and +++ answer at once":
    let s1 = new int
    let l = left[int, int, string](stubborn(s1, 60))(toLeft[int, string](1))
    cancelWhileRunning(l)
    let r = right[int, int, string](stubborn(s1, 60))(toRight[string, int](1))
    cancelWhileRunning(r)
    let s = (stubborn(s1, 60) +++ plus1)(toLeft[int, int](1))
    cancelWhileRunning(s)
    check s1[] == 3

  test "||| gives the future of the branch, so the cancel goes to the branch":
    let done = new int
    let j = (sleeper(plus1, 60, done) ||| plus1)(toLeft[int, int](1))
    cancelWhileRunning(j)
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

suite "a cancel stops the concurrency and loop combinators":
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

  test "iterate starts no next step":
    let s1 = new int
    let again1 = arr(
      proc(x: int): Either[int, int] =
        toLeft[int, int](x)
    )
    let fut = iterate(stubborn(s1, 60) >>> again1, limit = 10)(1)
    cancelWhileRunning(fut)
    check s1[] == 1

  test "feedback waits for its step, and keeps the state of the step":
    scoped:
      let s1 = new int
      let step: Arrow[Pair[int, int], Pair[int, int]] = proc(
          p: Pair[int, int]
      ): Future[Result[Pair[int, int], string]] {.async: (raises: []).} =
        inc s1[]
        try:
          await sleepAsync(chronos.milliseconds(60))
        except CancelledError:
          # The step goes on after the cancel, for 50 ms more.
          try:
            await sleepAsync(chronos.milliseconds(50))
          except CancelledError:
            discard
        return ok((fst: p.snd + 1, snd: p.snd + 1))
      let m = feedback(0, step)
      let fut = m(1)
      waitFor sleepAsync(chronos.milliseconds(10))
      fut.cancelSoon()
      let t0 = Moment.now()
      check (waitFor fut).get == 1
      check Moment.now() - t0 >= chronos.milliseconds(30)
      check (waitFor m(2)).get == 2

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

suite "an Answer in the cancelled state":
  # The combinators treat an inner `Answer` in the cancelled state as a
  # failure of that stage, and they do not wait without end.
  test "the waiting combinators give err":
    let b = broken()
    check bounded(b >>> plus1, 1).error == "cancelled"
    check bounded(b >>> later(plus1), 1).error == "cancelled"
    check bounded(first[int, int, int](b), (fst: 1, snd: 2)).error == "cancelled"
    check bounded(second[int, int, int](b), (fst: 1, snd: 2)).error == "cancelled"
    check bounded(b *** plus1, (fst: 1, snd: 2)).error == "cancelled"
    check bounded(b &&& plus1, 1).error == "cancelled"
    check bounded(left[int, int, int](b), toLeft[int, int](1)).error == "cancelled"
    check bounded(right[int, int, int](b), toRight[int, int](1)).error == "cancelled"
    check bounded(within(b, chronos.seconds(1)), 1).error == "cancelled"
    check bounded(retry(b, 2), 1).error == "cancelled"
    check bounded(mapSeq(b), @[1, 2]).error == "cancelled"
    let again1 = arr(
      proc(x: int): Either[int, int] =
        toLeft[int, int](x)
    )
    check bounded(iterate(b >>> again1), 1).error == "cancelled"
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
    check bounded(b <+> zeroArrow[int, int]("fallback"), 1).error == "fallback"
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
    staticRead("../arrows/choice.nim"),
    staticRead("../arrows/transformers.nim"),
    staticRead("../arrows/concurrent.nim"),
    staticRead("../arrows/loops.nim"),
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
    let stepWaits: Arrow[Pair[int, int], Pair[int, int]] = proc(
        p: Pair[int, int]
    ): Answer[Pair[int, int]] =
      pendingAnswer[Pair[int, int]]()

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
      let inStep = feedback(0, stepWaits)
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
      check bytesPerRun(
        proc() =
          cancelOf(inStep(1))
      ) < 16

    test "a cancel of a feedback run before its turn frees its memory":
      let m = feedback(0, stepWaits)
      check bytesPerRun(
        proc() =
          let first = m(1)
          let second = m(2)
          second.cancelSoon()
          first.cancelSoon()
          discard waitFor first
          discard waitFor second
          waitFor sleepAsync(chronos.milliseconds(0))
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
