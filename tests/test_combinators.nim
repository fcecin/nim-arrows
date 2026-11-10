## The behavior of the core and choice combinators. The laws are in
## `test_laws`. This suite checks the order of the runs, the stop at the first
## `err`, the fast paths, the adapters, and the copies of the values. It also
## checks that the slow paths keep heap values whole.

import std/strutils
import ./helpers

proc recorder(log: ref seq[string], name: string): SyncArrow[int, int] =
  result = proc(x: int): Result[int, string] =
    log[].add(name)
    if x < 0:
      err(name & " failed")
    else:
      ok(x)

suite "order of the runs":
  test "&&& runs f before g, and g does not run when f fails":
    let log = new seq[string]
    let pipe = later(recorder(log, "f")) &&& now(recorder(log, "g"))
    check run(pipe, 1) == Result[Pair[int, int], string].ok((fst: 1, snd: 1))
    check log[] == @["f", "g"]
    log[].setLen(0)
    check run(pipe, -1).error == "f failed"
    check log[] == @["f"]

  test "*** runs f before g, and g does not run when f fails":
    let log = new seq[string]
    let pipe = recorder(log, "f") *** later(recorder(log, "g"))
    check run(pipe, (fst: 2, snd: 3)).get == (fst: 2, snd: 3)
    check log[] == @["f", "g"]
    log[].setLen(0)
    check run(pipe, (fst: -2, snd: 3)).error == "f failed"
    check log[] == @["f"]

  test ">>> stops at the first err":
    let log = new seq[string]
    let pipe = recorder(log, "a") >>> later(recorder(log, "b")) >>> recorder(log, "c")
    check run(pipe, -5).error == "a failed"
    check log[] == @["a"]

  test "<+> does not run g after an ok from f":
    let log = new seq[string]
    let pipe = later(recorder(log, "f")) <+> recorder(log, "g")
    check run(pipe, 4).get == 4
    check log[] == @["f"]
    log[].setLen(0)
    check run(pipe, -4).error == "g failed"
    check log[] == @["f", "g"]

suite "fast paths":
  test "a chain of async stages that complete immediately gives a completed answer":
    check (now(plus1) >>> now(times2) >>> now(pickyBase))(5).completed()
    check (plus1 >>> now(times2))(5).completed()
    check first[int, int, string](now(plus1))((fst: 1, snd: "x")).completed()
    check (now(plus1) &&& now(times2))(1).completed()
    check (now(plus1) <+> now(times2))(1).completed()

  test "a stage that waits gives a pending answer, and the answer arrives":
    let fut = (now(plus1) >>> later(times2) >>> plus1)(5)
    check not fut.completed()
    check (waitFor fut).get == 13

suite "choice":
  test "||| runs the branch that the input selects":
    let lens: SyncArrow[string, int] = proc(s: string): Result[int, string] =
      ok(s.len)
    let pick = later(pickyBase) ||| lens
    check run(pick, toLeft[int, string](10)).get == 7
    check run(pick, toRight[int, string]("four")).get == 4

  test "+++ keeps the branch of the input":
    let up: SyncArrow[string, string] = proc(s: string): Result[string, string] =
      ok(s & "!")
    let both = times2 +++ later(up)
    check run(both, toLeft[int, string](4)).get == toLeft[int, string](8)
    check run(both, toRight[int, string]("hi")).get == toRight[int, string]("hi!")

  test "$ shows the branch and the value":
    check $toLeft[int, string](1) == "left(1)"
    check $toRight[int, string]("r") == "right(r)"

  test "right passes a left value without a change":
    let r = right[int, int, string](later(times2))
    check run(r, toLeft[string, int]("keep")).get == toLeft[string, int]("keep")
    check run(r, toRight[string, int](21)).get == toRight[string, int](42)

suite "apply":
  test "app runs the stage that the data selects":
    scoped:
      let stages = [now(plus1), later(times2)]
      let route = arr(
        proc(x: int): Pair[Arrow[int, int], int] =
          (fst: stages[x mod 2], snd: x)
      )
      let pipe = route >>> app[int, int]()
      check run(pipe, 4).get == 5
      check run(pipe, 5).get == 10

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

  test "isSync is known at compile time":
    static:
      doAssert isSync(plus1)
      doAssert not isSync(later(plus1))

  test "zeroArrow carries its reason":
    check run(zeroArrow[int, int]("no route"), 1).error == "no route"

  test "toAsync gives an async arrow back without a change":
    let a = later(plus1)
    check toAsync(a) == a

  test "a lambda with the right shape is an arrow":
    let s = proc(x: int): Result[int, string] =
      ok(x)
    let a = proc(x: int): Future[Result[int, string]] {.async: (raises: []).} =
      ok(x)
    check run(s >>> a, 3).get == 3

suite "heap values on the slow paths":
  # The strings are made at run time, so that a value that a combinator reads
  # after it is freed shows as a broken string.
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
        check run(later(up) *** later(up), (fst: a, snd: a & "b")).get ==
          (fst: a & "!", snd: a & "b!")
        check run(later(up) &&& later(up), a).get == (fst: a & "!", snd: a & "!")
        check run(later(fails) <+> later(up), a).get == a & "!"
        check run(later(up) +++ later(up), toRight[string, string](a)).get ==
          toRight[string, string](a & "!")
        check run(retry(later(fails) <+> later(up), 3), a).get == a & "!"
        check run(both(later(up), later(up)), a).get == (fst: a & "!", snd: a & "!")
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
    test "&&& does not copy its input when its first stage does not wait":
      let msg = Payload(data: newSeq[byte](1024))
      payloadCopies = 0
      check (sizeS &&& sizeS)(msg).get == (fst: 1024, snd: 1024)
      check (sizeS &&& now(sizeS))(msg).completed()
      check (now(sizeS) &&& now(sizeS))(msg).completed()
      check payloadCopies == 0

    test "a value that goes to the next stage is not copied":
      check copiesOf(waitFor (now(mkS) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (now(mkS) >>> now(sizeS))(8)) == 0
      check copiesOf(waitFor ((now(mkS) <+> now(mkS)) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (retry(now(mkS), 2) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (later(mkS) >>> sizeS)(8)) == 0
      check copiesOf(waitFor (later(mkS) >>> later(sizeS))(8)) == 1 # `later`

    test "an input that goes to a stage after a wait is copied one time":
      let msg = mk(8)
      let pp = (fst: mk(8), snd: mk(8))
      let fails =
        arr(
          proc(p: Payload): int =
            0
        ) >>> zeroArrow[int, int]()
      let keep = proc(
          p: Payload, e: string
      ): Result[int, string] {.gcsafe, raises: [].} =
        ok(0)
      check copiesOf(waitFor (waitTurn(sizeS) &&& sizeS)(msg)) == 1
      check copiesOf(waitFor (waitTurn(sizeS) *** sizeS)(pp)) == 1
      check copiesOf(waitFor (waitTurn(fails) <+> sizeS)(msg)) == 1
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
      let fstSize = arr(
        proc(p: Pair[Payload, string]): int =
          p.fst.data.len
      )
      let pairSize = arr(
        proc(p: Pair[Payload, Payload]): int =
          p.fst.data.len
      )
      let seqLen = arr(
        proc(s: seq[Payload]): int =
          s.len
      )
      check copiesOf(
        waitFor (first[int, Payload, string](now(mkS)) >>> fstSize)((fst: 8, snd: "x"))
      ) == 1
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

    test "a pair from a stage that waits copies each value one time":
      let ii = (fst: 8, snd: 8)
      let pairSize = arr(
        proc(p: Pair[Payload, Payload]): int =
          p.fst.data.len + p.snd.data.len
      )
      check copiesOf(waitFor ((now(mkS) *** later(mkS)) >>> pairSize)(ii)) == 2
      check copiesOf(waitFor ((later(mkS) *** now(mkS)) >>> pairSize)(ii)) == 2
      check copiesOf(waitFor ((mkS *** later(mkS)) >>> pairSize)(ii)) == 1
      check copiesOf(waitFor ((now(mkS) &&& later(mkS)) >>> pairSize)(8)) == 2
      # A value from a sync stage goes into the pair without a copy.
      check copiesOf(waitFor ((now(mkS) *** mkS) >>> pairSize)(ii)) == 1
      check copiesOf(waitFor ((mkS &&& now(mkS)) >>> pairSize)(8)) == 1
      let firstPayload = arr(
        proc(x: int): Pair[Payload, int] =
          (fst: mk(x), snd: x)
      )
      check copiesOf(
        waitFor (
          firstPayload >>> second[int, Payload, Payload](later(mkS)) >>> pairSize
        )(8)
      ) == 2
      let pp = (fst: 8, snd: mk(8))
      check copiesOf(
        waitFor (first[int, Payload, Payload](later(mkS)) >>> pairSize)(pp)
      ) == 2

    test "choice, firstOk and the transformers copy as the rule tells":
      let eSize = arr(
        proc(e: Either[Payload, Payload]): int =
          if e.isRight: e.right.data.len else: e.left.data.len
      )
      check copiesOf(waitFor ((now(mkS) +++ later(mkS)) >>> eSize)(toLeft[int, int](8))) ==
        1
      check copiesOf(
        waitFor ((now(mkS) +++ later(mkS)) >>> eSize)(toRight[int, int](8))
      ) == 1
      check copiesOf(waitFor ((later(mkS) ||| now(mkS)) >>> sizeS)(toLeft[int, int](8))) ==
        0
      # A value from a sync stage goes into the `Either` without a copy.
      check copiesOf(waitFor ((mkS +++ waitTurn(mkS)) >>> eSize)(toLeft[int, int](8))) ==
        0
      check copiesOf(waitFor ((waitTurn(mkS) +++ mkS) >>> eSize)(toRight[int, int](8))) ==
        0
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

    test "an async feedback copies the input only when a run waits for its turn":
      # This step reads its input in place and answers one turn later, so the
      # counts show only the copies of `feedback`.
      let readLater: Arrow[Pair[Payload, int], Pair[int, int]] = proc(
          p: Pair[Payload, int]
      ): Answer[Pair[int, int]] =
        let fut =
          Answer[Pair[int, int]].init("readLater", {FutureFlag.OwnCancelSchedule})
        let res = (fst: p.fst.data.len, snd: p.snd + 1)
        proc fire(udata: pointer) {.gcsafe, raises: [].} =
          fut.complete(Result[Pair[int, int], string].ok(res))

        callSoon(fire, nil)
        fut
      let m = feedback(0, readLater)
      let msg = mk(8)
      check copiesOf(waitFor m(msg)) == 0
      # The second run waits for its turn in an async proc, which keeps a copy
      # of the input.
      payloadCopies = 0
      let f1 = m(msg)
      let f2 = m(msg)
      discard waitFor f1
      discard waitFor f2
      check payloadCopies == 1

    test "iterate and the sync feedback do not copy the values":
      let grow = arr(
        proc(p: Payload): Either[Payload, int] =
          if p.data.len >= 11:
            toRight[Payload, int](p.data.len)
          else:
            toLeft[Payload, int](mk(p.data.len + 1))
      )
      check copiesOf(iterate(grow)(mk(8))) == 0
      check copiesOf(waitFor iterate(now(grow))(mk(8))) == 0
      let fbStep = arr(
        proc(p: Pair[int, int]): Pair[Payload, int] =
          (fst: mk(p.fst), snd: p.snd + 1)
      )
      check copiesOf((feedback(0, fbStep) >>> sizeS)(8)) == 0
      let toPayload: SyncArrow[int, Either[int, Payload]] = proc(
          x: int
      ): Result[Either[int, Payload], string] =
        if x >= 3:
          finishWith(mk(x))
        else:
          again(x + 1)
      check copiesOf(iterate(toPayload)(0)) == 0
      let grows = arr(
        proc(p: Pair[int, Payload]): Pair[int, Payload] =
          (fst: p.fst + p.snd.data.len, snd: mk(p.snd.data.len + 1))
      )
      let m = feedback(mk(1), grows)
      check copiesOf(m(5)) == 0
      check copiesOf(m(5)) == 0
