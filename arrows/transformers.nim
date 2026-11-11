## Transformers, the middleware tier. A transformer takes an arrow and gives
## an arrow with an added behavior. The stage inside does not change. Use a
## transformer to add observation, timing, retries or error mapping to a
## stage, and a timeout to an async stage. A broker edge is a stage too.

import ./core, ./private/answers

proc tap*[A](f: proc(a: A) {.gcsafe, raises: [].}): SyncArrow[A, A] =
  ## Calls `f` with the value, and passes the value on without a change.
  result = proc(a: A): Result[A, string] {.gcsafe, raises: [].} =
    f(a)
    ok(a)

proc ensure*[A](
    pred: proc(a: A): bool {.gcsafe, raises: [].}, reason: string
): SyncArrow[A, A] =
  ## A guard stage. It gives the value back when `pred` is true. It gives
  ## `err(reason)` when `pred` is false.
  result = proc(a: A): Result[A, string] {.gcsafe, raises: [].} =
    if pred(a):
      ok(a)
    else:
      err(reason)

# --- timed --------------------------------------------------------------------

proc timedSlow[B](
    fb: Answer[B], t0: Moment, report: proc(d: Duration) {.gcsafe, raises: [].}
): Future[Result[B, string]] {.async: (raises: []).} =
  # A cancel also ends the run, so `report` gets the time of the run.
  var cancelled = false
  waitStage(fb, cancelled)
  report(Moment.now() - t0)
  if cancelled:
    return err("cancelled")
  return outcome(fb)

proc timed*[A, B](
    f: SyncArrow[A, B], report: proc(d: Duration) {.gcsafe, raises: [].}
): SyncArrow[A, B] =
  ## Runs `f` and calls `report` with the time from the call to the answer. A
  ## run that gets a cancel also calls `report`.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    let t0 = Moment.now()
    result = f(a)
    report(Moment.now() - t0)

proc timed*[A, B](
    f: Arrow[A, B], report: proc(d: Duration) {.gcsafe, raises: [].}
): Arrow[A, B] =
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    let t0 = Moment.now()
    let fb = f(a)
    if fb.completed():
      report(Moment.now() - t0)
      return fb
    timedSlow[B](fb, t0, report)

# --- retry --------------------------------------------------------------------

type RetryIf* = proc(e: string): bool {.gcsafe, raises: [].}
  ## Gets the error text of a failed run. `retry` starts a new run only when
  ## this proc gives true.

proc again(retryIf: RetryIf, e: string): bool {.inline.} =
  retryIf.isNil or retryIf(e)

proc retry*[A, B](
    f: SyncArrow[A, B], attempts: int, retryIf: RetryIf = nil
): SyncArrow[A, B] =
  ## Runs `f` a maximum of `attempts` times, with no pause between the runs.
  ## See the async form for the other rules.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    result = f(a)
    var n = 1
    while result.isErr and n < attempts and again(retryIf, result.error):
      result = f(a)
      inc n

proc retrySlow[A, B](
    f: Arrow[A, B],
    a: A,
    first: Answer[B],
    attempts: int,
    backoff: Duration,
    factor: int,
    retryIf: RetryIf,
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  var fut = first
  var pause = backoff
  var n = 1
  while true:
    waitStage(fut, cancelled)
    if cancelled:
      return err("cancelled")
    if not fut.failed or n >= attempts or not again(retryIf, fut.failure):
      return outcome(fut)
    if pause > ZeroDuration:
      let slept = sleepAsync(pause)
      discard awaitne slept
      if slept.cancelled():
        return err("cancelled")
      pause = pause * max(1, factor)
    fut = f(a)
    inc n

proc retry*[A, B](
    f: Arrow[A, B],
    attempts: int,
    backoff = ZeroDuration,
    factor = 1,
    retryIf: RetryIf = nil,
): Arrow[A, B] =
  ## Runs `f` a maximum of `attempts` times. It stops at the first `ok`. An
  ## `attempts` value less than 1 gives one run. A pause of `backoff` comes
  ## before the second run. Each pause after it is `factor` times the pause
  ## before it. When all the runs fail, the last `err` is the answer.
  ##
  ## Without `retryIf`, each `err` starts a new run. With `retryIf`, an `err`
  ## starts a new run only when `retryIf` gives true for its error text. Use
  ## it to stop at an error that a new run can not remove.
  ##
  ## An `err` does not show that the run did nothing. Use `retry` only for
  ## requests that are safe to do more than one time.
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    let fb = f(a)
    if fb.completed() and (fb.value().isOk or attempts <= 1):
      return fb
    retrySlow[A, B](f, a, fb, attempts, backoff, factor, retryIf)

# --- recover, mapErr, label ---------------------------------------------------

proc recoverSlow[A, B](
    fb: Answer[B],
    a: A,
    g: proc(a: A, e: string): Result[B, string] {.gcsafe, raises: [].},
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if not fb.failed:
    return outcome(fb)
  return g(a, fb.failure)

proc recover*[A, B](
    f: SyncArrow[A, B],
    g: proc(a: A, e: string): Result[B, string] {.gcsafe, raises: [].},
): SyncArrow[A, B] =
  ## When `f` gives `err`, `g` gets the input and the error text. `g` can
  ## give a value in place of the error, or a different error.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    let rb = f(a)
    if rb.isOk:
      return rb
    g(a, rb.error)

proc recover*[A, B](
    f: Arrow[A, B], g: proc(a: A, e: string): Result[B, string] {.gcsafe, raises: [].}
): Arrow[A, B] =
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    let fb = f(a)
    if fb.completed():
      if fb.value().isOk:
        return fb
      return answer(g(a, fb.value().error))
    recoverSlow[A, B](fb, a, g)

proc mapErrSlow[B](
    fb: Answer[B], g: proc(e: string): string {.gcsafe, raises: [].}
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if not fb.failed:
    return outcome(fb)
  return err(g(fb.failure))

proc mapErr*[A, B](
    f: SyncArrow[A, B], g: proc(e: string): string {.gcsafe, raises: [].}
): SyncArrow[A, B] =
  ## Changes the error text of `f` with `g`. An `ok` does not change.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    let rb = f(a)
    if rb.isOk:
      return rb
    err(g(rb.error))

proc mapErr*[A, B](
    f: Arrow[A, B], g: proc(e: string): string {.gcsafe, raises: [].}
): Arrow[A, B] =
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    let fb = f(a)
    if fb.completed():
      if fb.value().isOk:
        return fb
      return answer(Result[B, string].err(g(fb.value().error)))
    mapErrSlow[B](fb, g)

proc label*[A, B](f: SyncArrow[A, B], name: string): SyncArrow[A, B] =
  ## Puts `name: ` before the error text of `f`. Use it to find the stage
  ## that failed in a long pipeline.
  mapErr(
    f,
    proc(e: string): string {.gcsafe, raises: [].} =
      name & ": " & e,
  )

proc label*[A, B](f: Arrow[A, B], name: string): Arrow[A, B] =
  mapErr(
    f,
    proc(e: string): string {.gcsafe, raises: [].} =
      name & ": " & e,
  )

# --- within -------------------------------------------------------------------

proc withinSlow[B](
    fb: Answer[B], timeout: Duration
): Future[Result[B, string]] {.async: (raises: []).} =
  # A cancelled `Answer` completes with `err`, so `withTimeout` can not tell
  # a timeout from an answer. This proc runs its own race with a timer.
  let timer = sleepAsync(timeout)
  let winner = race(FutureBase(fb), FutureBase(timer))
  discard awaitne winner
  if winner.cancelled():
    timer.cancelSoon()
    fb.cancelSoon()
    return err("cancelled")
  if fb.finished():
    timer.cancelSoon()
    return outcome(fb)
  fb.cancelSoon()
  return err("timed out after " & $timeout)

proc within*[A, B](f: Arrow[A, B], timeout: Duration): Arrow[A, B] =
  ## Gives `f` a time limit. When `f` does not answer in time, this proc
  ## cancels `f` and answers `err("timed out after ...")`. A broker request
  ## that gets a cancel sends the cancel to its provider.
  ##
  ## The answer comes at the time limit. It does not wait until `f` stops. The
  ## work that `f` did before the cancel stays done. Thus a `retry` or a
  ## fallback after `within` can start a new run before the cancelled run
  ## stops.
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    let fb = f(a)
    if fb.completed():
      return fb
    withinSlow[B](fb, timeout)
