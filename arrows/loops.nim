## Loops and feedback.
##
## `ArrowLoop` connects an output of an arrow back to an input of the same
## run. That needs the value before the run makes it. Haskell gets such a
## value from laziness. Nim is strict and has no such value. Imperative code
## sends the value back to a later point instead, in one of two forms.
##
## * A `while` loop sends a value back to the next iteration of the same run.
##   This is `iterate`.
## * An object sends its state back to its next call. This is `feedback`, a
##   Mealy machine. It is `ArrowLoop` with a delay of one run.

import ./core, ./choice, ./private/answers

template again*(v: untyped): untyped =
  ## The step of `iterate` gives this value to run again with `v`.
  typeof(result).ok(typeof(result.get)(isRight: false, left: v))

template finishWith*(v: untyped): untyped =
  ## The step of `iterate` gives this value to stop with the result `v`.
  typeof(result).ok(typeof(result.get)(isRight: true, right: v))

proc limitErr(limit: int): string =
  "iterate: no result after " & $limit & " steps"

# --- iterate ------------------------------------------------------------------

proc iterate*[A, B](
    step: SyncArrow[A, Either[A, B]], limit = high(int)
): SyncArrow[A, B] =
  ## A `while` loop in one run. `step` runs on the input. When it gives
  ## `again(v)`, `step` runs again on `v`. When it gives `finishWith(v)`, `v`
  ## is the answer. The first `err` stops the loop. After `limit` steps
  ## without a result, the answer is `err`. The loop does not use the stack,
  ## so it can do many steps.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    var r = step(a)
    var n = 1
    while true:
      if r.isErr:
        return err(r.error)
      if r.get.isRight:
        return ok(move(r.value.right))
      if n >= limit:
        return err(limitErr(limit))
      r = step(r.get.left)
      inc n

proc iterateSlow[A, B](
    step: Arrow[A, Either[A, B]], pending: Answer[Either[A, B]], started, limit: int
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  var fut = pending
  var n = started
  while true:
    waitStage(fut, cancelled)
    if cancelled:
      return err("cancelled")
    if fut.failed:
      return err(fut.failure)
    if fut.value().get.isRight:
      return ok(fut.value().get.right)
    if n >= limit:
      return err(limitErr(limit))
    # The new answer goes into a `let` first. With ORC, the code for
    # `fut = step(fut.value().get.left)` in an async proc destroys the old
    # future before the step reads its input.
    let next = step(fut.value().get.left)
    fut = next
    inc n

proc iterate*[A, B](step: Arrow[A, Either[A, B]], limit = high(int)): Arrow[A, B] =
  ## A `while` loop in one run, with an async step. See the sync overload.
  ## While the steps complete immediately, the loop runs in this proc and
  ## makes only one completed future, for its answer.
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    var fut = step(a)
    var n = 1
    while true:
      if not fut.finished():
        return iterateSlow[A, B](step, fut, n, limit)
      if fut.failed:
        return answer(Result[B, string].err(fut.failure))
      if fut.value().get.isRight:
        return answer(Result[B, string].ok(fut.value().get.right))
      if n >= limit:
        return answer(Result[B, string].err(limitErr(limit)))
      fut = step(fut.value().get.left)
      inc n

# --- feedback -----------------------------------------------------------------

type
  Gate = Future[void].Raising([])
    ## Completes when a run of an async `feedback` arrow is done with the state.

  Cell[S] = ref object
    state: S
    last: Gate # The gate of the last run that started, or nil.

proc newGate(): Gate =
  Gate.init("feedback", {FutureFlag.OwnCancelSchedule})

proc feedback*[B, C, S](
    initial: S, step: SyncArrow[Pair[B, S], Pair[C, S]]
): SyncArrow[B, C] =
  ## Keeps a state between runs. Each run gives the input and the current
  ## state to `step`. `step` gives the output and the next state. An `err`
  ## does not change the state. Each call of `feedback` makes a new state.
  ## Two copies of the same arrow share one state.
  let cell = Cell[S](state: initial)
  result = proc(b: B): Result[C, string] {.gcsafe, raises: [].} =
    var r = step((fst: b, snd: cell.state))
    if r.isErr:
      return err(r.error)
    cell.state = move(r.value.snd)
    ok(move(r.value.fst))

proc openAfter(prev, gate: Gate) {.async: (raises: []).} =
  await prev
  gate.complete()

proc feedbackRest[C, S](
    cell: Cell[S], fut: Answer[Pair[C, S]], gate: Gate
): Future[Result[C, string]] {.async: (raises: []).} =
  # A cancel goes to the step, but this run waits until the step is done. The
  # gate must open only when the step is done with the state. The waits use
  # `awaitne`, as `waitStage` does.
  while not fut.finished():
    let joined = fut.join()
    discard awaitne joined
    if joined.cancelled():
      fut.cancelSoon()
  if fut.failed:
    gate.complete()
    return err(fut.failure)
  cell.state = fut.value().get.snd
  gate.complete()
  return ok(fut.value().get.fst)

proc feedbackQueued[B, C, S](
    cell: Cell[S], step: Arrow[Pair[B, S], Pair[C, S]], b: B, prev, gate: Gate
): Future[Result[C, string]] {.async: (raises: []).} =
  let turn = prev.join()
  discard awaitne turn
  if turn.cancelled():
    # This run gets a cancel before its turn. Its step does not run, and the
    # next run waits for the run before this one.
    asyncSpawn openAfter(prev, gate)
    return err("cancelled")
  let fut = step((fst: b, snd: cell.state))
  # The same wait as in `feedbackRest`. A call of `feedbackRest` here would
  # make one more future and one more copy of the answer.
  while not fut.finished():
    let joined = fut.join()
    discard awaitne joined
    if joined.cancelled():
      fut.cancelSoon()
  if fut.failed:
    gate.complete()
    return err(fut.failure)
  cell.state = fut.value().get.snd
  gate.complete()
  return ok(fut.value().get.fst)

proc feedback*[B, C, S](initial: S, step: Arrow[Pair[B, S], Pair[C, S]]): Arrow[B, C] =
  ## Keeps a state between runs, with an async step. See the sync overload.
  ## The runs use the state in the order of the calls. A run starts its step
  ## only after the run before it is done, so each run sees the state that
  ## the run before it made. A run that gets a cancel before its turn does
  ## not run its step. A run can also get a cancel while its step runs. Then
  ## it sends the cancel to the step, waits for the step, and gives the answer
  ## of the step. When no run is in progress and the step completes
  ## immediately, the run makes only one completed future, for its answer.
  let cell = Cell[S](state: initial)
  result = proc(b: B): Answer[C] {.gcsafe, raises: [].} =
    if cell.last.isNil or cell.last.finished():
      let fut = step((fst: b, snd: cell.state))
      if fut.finished():
        if fut.failed:
          return answer(Result[C, string].err(fut.failure))
        cell.state = fut.value().get.snd
        return answer(Result[C, string].ok(fut.value().get.fst))
      let gate = newGate()
      cell.last = gate
      return feedbackRest[C, S](cell, fut, gate)
    let prev = cell.last
    let gate = newGate()
    cell.last = gate
    feedbackQueued[B, C, S](cell, step, b, prev, gate)
