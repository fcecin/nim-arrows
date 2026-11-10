## The loop in one run (`iterate`) and the feedback between runs
## (`feedback`).
##
## The `feedback` laws are the `ArrowLoop` laws in their delayed form. A
## `feedback` arrow has a state, so each law compares two sequences of runs.
## `sameRuns` makes each arrow one time and runs all the inputs on it in
## order.

import std/strutils
import ./helpers

template sameRuns(lhs, rhs: typed, inputs: openArray) =
  block:
    let l = lhs
    let r = rhs
    for x in inputs:
      check run(l, x) == run(r, x)

# --- iterate fixtures ---------------------------------------------------------

let gcdStep: SyncArrow[Pair[int, int], Either[Pair[int, int], int]] = proc(
    p: Pair[int, int]
): Result[Either[Pair[int, int], int], string] =
  if p.fst < 0 or p.snd < 0:
    return err("negative")
  if p.snd == 0:
    finishWith(p.fst)
  else:
    again((fst: p.snd, snd: p.fst mod p.snd))

proc gcdLoop(p: Pair[int, int]): Result[int, string] {.gcsafe, raises: [].} =
  if p.fst < 0 or p.snd < 0:
    return err("negative")
  var (a, b) = (p.fst, p.snd)
  while b != 0:
    (a, b) = (b, a mod b)
  ok(a)

let gcdLoopArrow: SyncArrow[Pair[int, int], int] = gcdLoop

const gcdInputs = [
  (fst: 12, snd: 18),
  (fst: 48, snd: 36),
  (fst: 7, snd: 0),
  (fst: 0, snd: 5),
  (fst: -3, snd: 4),
  (fst: 1071, snd: 462),
]

let countdown: SyncArrow[int, Either[int, string]] = proc(
    x: int
): Result[Either[int, string], string] =
  if x == 0:
    finishWith("done")
  else:
    again(x - 1)

# --- feedback fixtures --------------------------------------------------------

# A running sum. The output is the new sum, and the state is the new sum. A
# negative input fails, so the state must not change.
let sumStep: SyncArrow[Pair[int, int], Pair[int, int]] = proc(
    p: Pair[int, int]
): Result[Pair[int, int], string] =
  if p.fst < 0:
    return err("negative " & $p.fst)
  ok((fst: p.fst + p.snd, snd: p.fst + p.snd))

const seqIn = [1, 2, -5, 3, 0, 7, -1, 4]

proc sumRef(inputs: openArray[int], s0: int): seq[Result[int, string]] =
  ## The imperative fold that `feedback(s0, sumStep)` must equal.
  var s = s0
  for b in inputs:
    if b < 0:
      result.add(Result[int, string].err("negative " & $b))
    else:
      s += b
      result.add(Result[int, string].ok(s))

proc shuffle(
    p: Pair[Pair[int, int], int]
): Pair[Pair[int, int], int] {.gcsafe, raises: [].} =
  (fst: (fst: p.fst.fst, snd: p.snd), snd: p.fst.snd)

let nestedStep: SyncArrow[Pair[Pair[int, int], int], Pair[Pair[int, int], int]] = proc(
    p: Pair[Pair[int, int], int]
): Result[Pair[Pair[int, int], int], string] =
  let (b, s, t) = (p.fst.fst, p.fst.snd, p.snd)
  if b < 0:
    return err("negative")
  ok((fst: (fst: b + s + t, snd: s + b), snd: t + 1))

proc unassoc(
    p: Pair[int, Pair[int, int]]
): Pair[Pair[int, int], int] {.gcsafe, raises: [].} =
  (fst: (fst: p.fst, snd: p.snd.fst), snd: p.snd.snd)

proc assoc(
    p: Pair[Pair[int, int], int]
): Pair[int, Pair[int, int]] {.gcsafe, raises: [].} =
  (fst: p.fst.fst, snd: (fst: p.fst.snd, snd: p.snd))

RequestBroker:
  proc NextSeq(tag: string): Future[Result[string, string]] {.async.}

RequestBroker(sync):
  proc NextHop(at: string, dst: string): Result[string, string]

# --- iterate ------------------------------------------------------------------

suite "iterate":
  test "iterate is a while loop":
    eachFlavor(s, gcdStep):
      sameOn(iterate(s), gcdLoopArrow, gcdInputs)

  test "the fixed-point equation: iterate s == s >>> (iterate s ||| idArrow)":
    eachFlavor(s, gcdStep):
      sameOn(iterate(s), s >>> (iterate(s) ||| idArrow[int]()), gcdInputs)

  test "a step that finishes at once: iterate (f >>> arr finishWith) == f":
    let stop = arr(
      proc(x: int): Either[int, int] =
        toRight[int, int](x)
    )
    eachFlavor(f, pickyBase):
      sameOn(iterate(f >>> stop), f, ints)

  test "naturality: iterate s >>> arr h == iterate (s >>> arr (id +++ h))":
    let h = proc(x: int): string {.gcsafe, raises: [].} =
      "#" & $x
    let mapped = arr(
      proc(e: Either[Pair[int, int], int]): Either[Pair[int, int], string] =
        if e.isRight:
          toRight[Pair[int, int], string](h(e.right))
        else:
          toLeft[Pair[int, int], string](e.left)
    )
    eachFlavor(s, gcdStep):
      sameOn(iterate(s) >>> arr(h), iterate(s >>> mapped), gcdInputs)

  test "the limit stops a loop that does not finish":
    scoped:
      let count = new int
      let forever: SyncArrow[int, Either[int, int]] = proc(
          x: int
      ): Result[Either[int, int], string] =
        inc count[]
        again(x + 1)
      check run(iterate(forever, limit = 5), 0).error ==
        "iterate: no result after 5 steps"
      check count[] == 5
      count[] = 0
      check run(iterate(now(forever), limit = 5), 0).error ==
        "iterate: no result after 5 steps"
      check count[] == 5
      count[] = 0
      check run(iterate(later(forever), limit = 5), 0).error ==
        "iterate: no result after 5 steps"
      check count[] == 5

  test "a limit of 1 lets a step that finishes at once give its result":
    check run(iterate(countdown, limit = 1), 0).get == "done"
    check run(iterate(countdown, limit = 1), 1).isErr

  test "the first err stops the loop":
    let upToThree: SyncArrow[int, Either[int, int]] = proc(
        x: int
    ): Result[Either[int, int], string] =
      if x == 3:
        return err("three")
      again(x + 1)
    eachFlavor(s, upToThree):
      check run(iterate(s), 0).error == "three"

  test "a step that waits gets its input whole":
    # The input holds strings that the steps make at run time. A loop that
    # frees the answer of a step before the next step reads it gives broken
    # strings here.
    let grow: SyncArrow[seq[string], Either[seq[string], seq[string]]] = proc(
        p: seq[string]
    ): Result[Either[seq[string], seq[string]], string] =
      if p.len >= 6:
        finishWith(p)
      else:
        again(p & ("node" & $p.len))
    let evenWaits: Arrow[seq[string], Either[seq[string], seq[string]]] = proc(
        p: seq[string]
    ): Answer[Either[seq[string], seq[string]]] =
      if p.len mod 2 == 0:
        later(grow)(p)
      else:
        now(grow)(p)
    let expected = @["node0", "node1", "node2", "node3", "node4", "node5"]
    check run(iterate(grow), newSeq[string]()).get == expected
    check run(iterate(now(grow)), newSeq[string]()).get == expected
    check run(iterate(later(grow)), newSeq[string]()).get == expected
    check run(iterate(evenWaits), newSeq[string]()).get == expected

  test "a long loop does not use the stack":
    check run(iterate(countdown), 1_000_000).get == "done"
    check run(iterate(now(countdown)), 1_000_000).get == "done"
    check run(iterate(later(countdown)), 2_000).get == "done"

  test "a loop of async steps that complete at once gives a completed answer":
    check iterate(now(countdown))(10).completed()

  test "again and finishWith work in an async step":
    let s: Arrow[int, Either[int, string]] = proc(
        x: int
    ): Future[Result[Either[int, string], string]] {.async: (raises: []).} =
      if x >= 4:
        return finishWith("reached " & $x)
      return again(x * 2)
    check run(iterate(s), 1).get == "reached 4"

  test "iterate walks a route through a broker edge":
    discard NextHop.setProvider(
      proc(at: string, dst: string): Result[string, string] =
        if at.len < dst.len:
          ok(dst[0 .. at.len])
        else:
          err("no route from " & at)
    )
    let hop = arr(
      proc(p: Pair[string, string]): tuple[at: string, dst: string] =
        (at: p.fst, dst: p.snd)
    )
    let step =
      (
        hop &&&
        arr(
          proc(p: Pair[string, string]): string =
            p.snd
        )
      ) >>> first[tuple[at: string, dst: string], string, string](NextHop.arrow) >>>
      arr(
        proc(p: Pair[string, string]): Either[Pair[string, string], string] =
          if p.fst == p.snd:
            toRight[Pair[string, string], string](p.fst)
          else:
            toLeft[Pair[string, string], string](p)
      )
    check run(iterate(step, limit = 8), (fst: "a", snd: "abcd")).get == "abcd"
    check run(iterate(step, limit = 2), (fst: "a", snd: "abcd")).isErr

# --- feedback -----------------------------------------------------------------

suite "feedback":
  test "feedback is the imperative fold over the runs":
    eachFlavor(f, sumStep):
      let m = feedback(10, f)
      let expected = sumRef(seqIn, 10)
      for i, x in seqIn:
        check run(m, x) == expected[i]

  test "an err does not change the state":
    let m = feedback(0, sumStep)
    check run(m, 5).get == 5
    check run(m, -1).isErr
    check run(m, 1).get == 6

  test "each feedback has its own state, and copies share one state":
    let a = feedback(0, sumStep)
    let b = feedback(0, sumStep)
    let c = a
    check run(a, 5).get == 5
    check run(b, 1).get == 1
    check run(c, 1).get == 6

  test "a feedback of a step that completes at once gives a completed answer":
    check feedback(0, now(sumStep))(1).completed()

suite "feedback laws (ArrowLoop with a delay of one run)":
  test "no state: feedback(s0, first g) == g":
    eachFlavor(g, pickyBase):
      sameRuns(feedback(5, first[int, int, int](g)), g, seqIn)

  test "left tightening: feedback(s0, first h >>> f) == h >>> feedback(s0, f)":
    eachFlavor(h, pickyBase):
      eachFlavor(f, sumStep):
        sameRuns(
          feedback(0, first[int, int, int](h) >>> f), h >>> feedback(0, f), seqIn
        )

  test "right tightening: feedback(s0, f >>> first h) == feedback(s0, f) >>> h":
    # `h` must not fail. When the step fails, the state does not change. But
    # when `h` after the loop fails, the step is already done.
    eachFlavor(h, times2):
      eachFlavor(f, sumStep):
        sameRuns(
          feedback(0, f >>> first[int, int, int](h)), feedback(0, f) >>> h, seqIn
        )

  test "sliding: feedback(s0, f >>> second k) == feedback(t0, second k >>> f), k(t0) = s0":
    let kBase = arr(
      proc(x: int): int =
        x + 100
    )
    eachFlavor(k, kBase):
      eachFlavor(f, sumStep):
        sameRuns(
          feedback(0, f >>> second[int, int, int](k)),
          feedback(-100, second[int, int, int](k) >>> f),
          seqIn,
        )

  test "vanishing: two nested feedbacks == one feedback with a pair of states":
    eachFlavor(f, nestedStep):
      sameRuns(
        feedback(1, feedback(2, f)),
        feedback((fst: 1, snd: 2), arr(unassoc) >>> f >>> arr(assoc)),
        seqIn,
      )

  test "superposing: first (feedback(s0, f)) == feedback(s0, shuffle >>> first f >>> shuffle)":
    let pairsIn =
      [(fst: 1, snd: 10), (fst: -2, snd: 20), (fst: 3, snd: 30), (fst: 4, snd: 40)]
    eachFlavor(f, sumStep):
      sameRuns(
        first[int, int, int](feedback(0, f)),
        feedback(
          0,
          arr(shuffle) >>> first[Pair[int, int], Pair[int, int], int](f) >>> arr(
            shuffle
          ),
        ),
        pairsIn,
      )

suite "feedback with async runs that overlap":
  test "the runs take the state in the order of the calls":
    scoped:
      let order = new seq[int]
      let step: Arrow[Pair[int, int], Pair[int, int]] = proc(
          p: Pair[int, int]
      ): Future[Result[Pair[int, int], string]] {.async: (raises: []).} =
        # A later call waits less. Without the order rule, the later calls
        # would finish first and read a stale state.
        try:
          await sleepAsync(chronos.milliseconds(16 - 2 * p.fst))
        except CancelledError:
          return err("cancelled")
        order[].add(p.fst)
        return ok((fst: p.snd + 1, snd: p.snd + 1))
      let numbered = feedback(0, step)
      var futs: seq[Answer[int]]
      for i in 0 ..< 8:
        futs.add(numbered(i))
      for i, f in futs:
        check (waitFor f).get == i + 1
      check order[] == @[0, 1, 2, 3, 4, 5, 6, 7]

  test "a run that gets a cancel before its turn does not run its step":
    scoped:
      let ran = new seq[int]
      let step: Arrow[Pair[int, int], Pair[int, int]] = proc(
          p: Pair[int, int]
      ): Future[Result[Pair[int, int], string]] {.async: (raises: []).} =
        try:
          await sleepAsync(chronos.milliseconds(40))
        except CancelledError:
          return err("cancelled")
        ran[].add(p.fst)
        return ok((fst: p.snd + 1, snd: p.snd + 1))
      let m = feedback(0, step)
      let f1 = m(1)
      let f2 = within(m, chronos.milliseconds(10))(2)
      let f3 = m(3)
      check "timed out" in (waitFor f2).error
      check (waitFor f1).get == 1
      check (waitFor f3).get == 2
      check ran[] == @[1, 3]

  test "a run that waits for its turn and fails does not change the state":
    let m = feedback(0, later(sumStep))
    let f1 = m(5)
    let f2 = m(-1)
    let f3 = m(2)
    check (waitFor f1).get == 5
    check (waitFor f2).error == "negative -1"
    check (waitFor f3).get == 7

  test "a step that gives err after a cancel does not change the state":
    let m = feedback(0, sleeper(sumStep, 50))
    check "timed out" in run(within(m, chronos.milliseconds(10)), 7).error
    check run(m, 1).get == 1

  test "a feedback arrow can be the provider of an edge":
    let tagStep: SyncArrow[Pair[string, int], Pair[string, int]] = proc(
        p: Pair[string, int]
    ): Result[Pair[string, int], string] =
      ok((fst: p.fst & "#" & $(p.snd + 1), snd: p.snd + 1))
    check NextSeq.provide(feedback(0, later(tagStep))).isOk
    check (waitFor NextSeq.request("a")).get == "a#1"
    check (waitFor NextSeq.request("b")).get == "b#2"
    let f3 = NextSeq.request("c")
    let f4 = NextSeq.request("d")
    check (waitFor f4).get == "d#4"
    check (waitFor f3).get == "c#3"
