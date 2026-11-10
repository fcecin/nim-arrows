## The behavior of the transformers (the middleware tier).

import std/strutils
import ./helpers

proc flaky(calls: ref int, failures: int): Arrow[int, int] =
  ## Gives `err` for the first `failures` calls, and `ok(x * 10)` after them.
  result = proc(x: int): Future[Result[int, string]] {.async: (raises: []).} =
    inc calls[]
    if calls[] <= failures:
      return err("transient " & $calls[])
    return ok(x * 10)

suite "tap and ensure":
  test "tap sees the value between two stages":
    scoped:
      let seen = new seq[int]
      let pipe =
        plus1 >>>
        tap(
          proc(x: int) =
            seen[].add(x)
        ) >>> later(times2)
      check run(pipe, 5).get == 12
      check seen[] == @[6]

  test "ensure gives err when the predicate is false":
    let positive = ensure(
      proc(x: int): bool =
        x > 0,
      "not positive",
    )
    check run(positive, 3).get == 3
    check run(positive, -3).error == "not positive"

suite "timed":
  test "timed reports the duration of a sync arrow":
    scoped:
      let d = new seq[Duration]
      let t = timed(
        plus1,
        proc(x: Duration) =
          d[].add(x),
      )
      check run(t, 1).get == 2
      check d[].len == 1
      check d[0] >= ZeroDuration

  test "timed reports the time until the answer of an async arrow":
    scoped:
      let d = new seq[Duration]
      let t = timed(
        sleeper(plus1, 30),
        proc(x: Duration) =
          d[].add(x),
      )
      check run(t, 1).get == 2
      check d[].len == 1
      check d[0] >= chronos.milliseconds(25)

  test "timed of a completed answer gives the same answer":
    let t = timed(
      now(plus1),
      proc(x: Duration) =
        discard,
    )
    check t(1).completed()

suite "retry":
  test "a sync retry stops at the first ok":
    scoped:
      let calls = new int
      let s: SyncArrow[int, int] = proc(x: int): Result[int, string] =
        inc calls[]
        if calls[] < 3:
          err("no")
        else:
          ok(x)
      check run(retry(s, 5), 7).get == 7
      check calls[] == 3

  test "an async retry stops at the first ok":
    let calls = new int
    check run(retry(flaky(calls, 2), 5), 4).get == 40
    check calls[] == 3

  test "an async retry gives the last err when all runs fail":
    let calls = new int
    check run(retry(flaky(calls, 10), 3), 1).error == "transient 3"
    check calls[] == 3

  test "an attempts value of 1 or less gives one run":
    let calls = new int
    check run(retry(flaky(calls, 10), 0), 1).error == "transient 1"
    check calls[] == 1

  test "the pauses grow by the factor":
    let calls = new int
    let t0 = Moment.now()
    check run(retry(flaky(calls, 2), 3, chronos.milliseconds(20), 2), 1).get == 10
    # The pauses are 20 ms and then 40 ms.
    check Moment.now() - t0 >= chronos.milliseconds(55)

suite "recover, mapErr and label":
  test "recover gives a value in place of an error":
    let r = recover(
      later(pickyBase),
      proc(x: int, e: string): Result[int, string] =
        ok(-100),
    )
    check run(r, -1).get == -100
    check run(r, 10).get == 7

  test "recover of a sync arrow sees the input and the error":
    let r = recover(
      pickyBase,
      proc(x: int, e: string): Result[int, string] =
        err(e & " at " & $x),
    )
    check run(r, -2).error == "negative -2 at -2"

  test "recover of a sync arrow gives the ok of f without a change":
    scoped:
      let calls = new int
      let r = recover(
        pickyBase,
        proc(x: int, e: string): Result[int, string] =
          inc calls[]
          ok(-1),
      )
      check run(r, 10).get == 7
      check calls[] == 0

  test "mapErr changes only the error text":
    let m = mapErr(
      later(pickyBase),
      proc(e: string): string =
        e.toUpperAscii,
    )
    check run(m, -1).error == "NEGATIVE -1"
    check run(m, 5).get == 2

  test "label puts the stage name before the error":
    let pipe =
      plus1.label("plus1") >>> later(pickyBase).label("picky") >>> showBase.label(
        "show"
      )
    check run(pipe, -9).error == "picky: negative -8"
    check run(pipe, 9).error == "show: seven"

suite "within":
  test "within gives err when the stage does not answer in time":
    let r = run(within(sleeper(plus1, 200), chronos.milliseconds(20)), 1)
    check r.isErr
    check "timed out" in r.error

  test "within passes an answer that comes in time":
    check run(within(sleeper(plus1, 5), chronos.seconds(2)), 1).get == 2

  test "within cancels the stage at the timeout":
    let done = new int
    discard run(within(sleeper(plus1, 100, done), chronos.milliseconds(10)), 1)
    waitFor sleepAsync(chronos.milliseconds(150))
    check done[] == 0

  test "within of a completed answer gives the same answer":
    check within(now(plus1), chronos.milliseconds(1))(1).completed()
