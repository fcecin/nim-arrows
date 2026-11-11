## The behavior of the core combinators. The laws are in `test_laws`. This
## suite checks the sequence of the runs, the stop at the first `err`, and the
## error text of `orElse`. It also checks the fast paths, the adapters, and
## the copies of the values. The slow paths must keep heap values whole.

import std/strutils
import ./helpers

proc recorder(log: ref seq[string], name: string): SyncArrow[int, int] =
  result = proc(x: int): Result[int, string] =
    log[].add(name)
    if x < 0:
      err(name & " failed")
    else:
      ok(x)

suite "the sequence of the runs":
  test ">>> stops at the first err":
    let log = new seq[string]
    let pipe = recorder(log, "a") >>> later(recorder(log, "b")) >>> recorder(log, "c")
    check run(pipe, -5).error == "a failed"
    check log[] == @["a"]

  test "orElse does not run g after an ok from f":
    let log = new seq[string]
    let pipe = later(recorder(log, "f")).orElse(recorder(log, "g"))
    check run(pipe, 4).get == 4
    check log[] == @["f"]
    log[].setLen(0)
    check run(pipe, -4).error == "f failed | g failed"
    check log[] == @["f", "g"]

  test "orElse does not go back after an ok from f":
    let log = new seq[string]
    let lastStage: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("later stage failed")
    let pipe = recorder(log, "f").orElse(recorder(log, "g")) >>> later(lastStage)
    check run(pipe, 4).error == "later stage failed"
    check log[] == @["f"]

suite "the error text of orElse":
  test "an err of the two stages has the two error texts":
    let a: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("relay: no peers")
    let b: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("lightpush: down")
    eachFlavor(f, a):
      eachFlavor(g, b):
        check run(f.orElse(g), 1).error == "relay: no peers | lightpush: down"

  test "an ok of the second stage is the answer":
    let a: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("relay: no peers")
    eachFlavor(f, a):
      eachFlavor(g, plus1):
        check run(f.orElse(g), 1).get == 2

  test "an empty error text adds nothing":
    let quiet: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("")
    let loud: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      err("down")
    check run(quiet.orElse(loud), 1).error == "down"
    check run(loud.orElse(quiet), 1).error == "down"
    check run(quiet.orElse(quiet), 1).error == ""

suite "fast paths":
  test "a chain of async stages that complete immediately gives a completed answer":
    check (now(plus1) >>> now(times2) >>> now(pickyBase))(5).completed()
    check (plus1 >>> now(times2))(5).completed()
    check now(plus1).orElse(now(times2))(1).completed()

  test "a stage that waits gives a pending answer, and the answer arrives":
    let fut = (now(plus1) >>> later(times2) >>> plus1)(5)
    check not fut.completed()
    check (waitFor fut).get == 13

suite "adapters":
  test "catching changes an exception into err":
    let boom = catching[int, int](
      proc(x: int): Future[Result[int, string]] {.async.} =
        if x > 0:
          raise newException(ValueError, "boom " & $x)
        return ok(x)
    )
    check run(boom, 3).error == "boom 3"
    check run(boom, 0).get == 0

  test "catching changes a cancellation into err":
    let stop = catching[int, int](
      proc(x: int): Future[Result[int, string]] {.async.} =
        raise newException(CancelledError, "stop")
    )
    check run(stop, 1).error == "cancelled"

  test "answerOf runs the two kinds in the same way":
    check (waitFor answerOf(plus1, 1)).get == 2
    check (waitFor answerOf(later(plus1), 1)).get == 2

  test "a lambda with the right shape is an arrow":
    let s = proc(x: int): Result[int, string] =
      ok(x)
    let a = proc(x: int): Future[Result[int, string]] {.async: (raises: []).} =
      ok(x)
    check run(s >>> a, 3).get == 3

suite "heap values on the slow paths":
  # The test makes the strings at run time. Thus a string that a combinator
  # reads from free memory shows as a broken string.
  test "the slow paths of the combinators keep strings whole":
    scoped:
      let up = arr(
        proc(x: string): string =
          x & "!"
      )
      let fails: SyncArrow[string, string] = proc(x: string): Result[string, string] =
        err("no " & x)
      for i in 1 .. 20:
        let a = "v" & $i & "x".repeat(i)
        check run(later(up) >>> later(up), a).get == a & "!!"
        check run(later(fails).orElse(later(up)), a).get == a & "!"
        check run(later(fails).orElse(later(fails)), a).error == "no " & a & " | no " & a
        check run(retry(later(fails).orElse(later(up)), 3), a).get == a & "!"
        check run(both(later(up), later(up)), a).get == (a & "!", a & "!")
        check run(mapAll(later(up)), @[a, a & "c"]).get == @[a & "!", a & "c!"]
        check run(mapSeq(later(up)), @[a, a & "c"]).get == @[a & "!", a & "c!"]

when defined(gcOrc) or defined(gcArc) or defined(gcAtomicArc):
  # The copy hook counts the copies of a payload. The combinators give a
  # value to the next stage without a copy. A combinator copies a value one
  # time in three cases. A value goes from the future of a stage into a new
  # value or a new future. An input goes into a new output, because the
  # caller keeps its input. An input goes to a stage after a wait, because
  # the caller does not keep its input for the wait. The counts also hold the
  # copy that `later` makes, as an async proc copies its input. `waitTurn`
  # waits one turn of the event loop, and it does not copy its input or its
  # output.
  type Payload = object
    data: seq[byte]

  var payloadCopies = 0

  proc `=copy`(dst: var Payload, src: Payload) =
    inc payloadCopies
    dst.data = src.data

  proc mk(n: int): Payload {.gcsafe, raises: [].} =
    Payload(data: newSeq[byte](n))

  proc size(p: Payload): int {.gcsafe, raises: [].} =
    p.data.len

  let mkS = arr(mk)
  let sizeS = arr(size)

  proc waitTurn[A, B](f: SyncArrow[A, B]): Arrow[A, B] =
    result = proc(a: A): Answer[B] =
      let fut = Answer[B].init("waitTurn", {FutureFlag.OwnCancelSchedule})
      var r = f(a)
      proc fire(udata: pointer) {.gcsafe, raises: [].} =
        fut.complete(move(r))

      callSoon(fire, nil)
      fut

  template copiesOf(body: untyped): int =
    payloadCopies = 0
    discard body
    payloadCopies

  suite "copies":
    test "a value that goes to the next stage is not copied":
      check copiesOf(waitFor (now(mkS) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (now(mkS) >>> now(sizeS))(8)) == 0
      check copiesOf(waitFor (now(mkS).orElse(now(mkS)) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (retry(now(mkS), 2) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (later(mkS) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (later(mkS) >>> later(sizeS))(8)) == 1 # `later`

    test "an input that goes to a stage after a wait is copied one time":
      let msg = mk(8)
      let fails: SyncArrow[Payload, int] = proc(p: Payload): Result[int, string] =
        err("no")
      let keep = proc(
          p: Payload, e: string
      ): Result[int, string] {.gcsafe, raises: [].} =
        ok(0)
      check copiesOf(waitFor waitTurn(fails).orElse(sizeS)(msg)) == 1
      check copiesOf(waitFor retry(waitTurn(fails), 2)(msg)) == 1
      check copiesOf(waitFor recover(waitTurn(fails), keep)(msg)) == 1
      # `mapSeq` copies only the items that did not start.
      let three = @[mk(8), mk(8), mk(8)]
      check copiesOf(waitFor mapSeq(waitTurn(sizeS))(three)) == 2
      let pick: Arrow[Payload, int] = proc(p: Payload): Answer[int] =
        if p.data.len == 9:
          waitTurn(sizeS)(p)
        else:
          now(sizeS)(p)
      let four = @[mk(8), mk(8), mk(9), mk(8)]
      check copiesOf(waitFor mapSeq(pick)(four)) == 1
      check copiesOf(waitFor mapSeq(now(sizeS))(three)) == 0

    test "a value that goes into a new output is copied one time":
      let pairSize = arr(
        proc(p: (Payload, Payload)): int =
          p[0].data.len
      )
      let seqLen = arr(
        proc(s: seq[Payload]): int =
          s.len
      )
      # `tap` and `ensure` give their input back in a new `Result`.
      let msg = mk(8)
      let look = tap(
        proc(p: Payload) {.gcsafe, raises: [].} =
          discard
      )
      let always = ensure(
        proc(p: Payload): bool {.gcsafe, raises: [].} =
          true,
        "never",
      )
      check copiesOf((look >>> sizeS)(msg)) == 1
      check copiesOf((always >>> sizeS)(msg)) == 1
      check copiesOf(waitFor (both(now(mkS), later(mkS)) >>> pairSize)(8)) == 2
      check copiesOf(waitFor (all(@[now(mkS), later(mkS)]) >>> seqLen)(8)) == 2
      check copiesOf(waitFor (mapSeq(later(mkS)) >>> seqLen)(@[8, 8, 8])) == 3
      check copiesOf(waitFor (mapAll(later(mkS)) >>> seqLen)(@[8, 8])) == 2
      # Two values are in the list when the third item waits. They go to the
      # slow path without a copy.
      let mkPick: Arrow[int, Payload] = proc(x: int): Answer[Payload] =
        if x == 9:
          waitTurn(mkS)(x)
        else:
          now(mkS)(x)
      check copiesOf(waitFor (mapSeq(mkPick) >>> seqLen)(@[8, 8, 9, 8])) == 4

    test "firstOk and the transformers copy as the rule tells":
      check copiesOf(waitFor (firstOk(@[now(mkS)]) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (firstOk(@[later(mkS), later(mkS)]) >>> sizeS)(8)) == 1
      let same = proc(e: string): string {.gcsafe, raises: [].} =
        e
      let keep = proc(
          x: int, e: string
      ): Result[Payload, string] {.gcsafe, raises: [].} =
        err(e)
      let quiet = proc(d: Duration) {.gcsafe, raises: [].} =
        discard
      check copiesOf(waitFor (recover(now(mkS), keep) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (mapErr(later(mkS), same) >>> sizeS)(8)) == 1
      check copiesOf(waitFor (timed(later(mkS), quiet) >>> sizeS)(8)) == 1
      check copiesOf(waitFor (within(now(mkS), chronos.seconds(1)) >>> sizeS)(8)) == 0
