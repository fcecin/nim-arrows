## The core of `arrows`. This module holds the two arrow types, the procs that
## make arrows, composition and the fallback.
##
## An arrow is a typed connection from an `A` to a `B` that can fail with a
## `string`. There are two kinds of arrow.
##
## * `SyncArrow[A, B]` gives its answer immediately. It is a Kleisli arrow of
##   `Result[_, string]`.
## * `Arrow[A, B]` gives its answer in a future. It is a Kleisli arrow of
##   `Future[Result[_, string]]`, and the future can not raise. A nim-brokers
##   request has this shape.
##
## `>>>` and `orElse` accept the two kinds in all combinations. When the two
## inputs are sync arrows, the result is a sync arrow. In all other cases, the
## result is an async arrow. `toAsync` changes a sync arrow into an async
## arrow, and it keeps composition.
##
## Cost model. A sync stage makes no future. When a combinator ends with an
## async stage, it gives the future of that stage when it can. In the other
## cases, it makes one completed future for its answer. When a stage must
## wait, a combinator of this module goes on in an async proc. That proc
## makes one future for its answer, and one or two more futures for each wait.
##
## Error model. An arrow reports a failure with `err`. It does not raise. A
## cancelled arrow also answers with `err`. `>>>` stops at the first `err`. A
## combinator that waits and gets a cancel answers `err("cancelled")` at once.
## It sends the cancel to the stage that runs, and it starts no new stage. The
## stage can continue to run after this answer, until it obeys the cancel.

import chronos, results
import ./private/answers

export chronos, results
export answers.Answer, answers.answer

type
  Arrow*[A, B] = proc(a: A): Answer[B] {.gcsafe, raises: [].}
    ## An async arrow from `A` to `B`. A lambda with the pragma
    ## `{.async: (raises: []).}` and the return type
    ## `Future[Result[B, string]]` is an `Arrow[A, B]`.

  SyncArrow*[A, B] = proc(a: A): Result[B, string] {.gcsafe, raises: [].}
    ## A sync arrow from `A` to `B`. A lambda that returns
    ## `Result[B, string]` is a `SyncArrow[A, B]`.

# --- Answers ------------------------------------------------------------------

template failWith(B: typedesc, e: string): untyped =
  answer(Result[B, string].err(e))

proc answerOf*[A, B](f: SyncArrow[A, B], a: A): Answer[B] {.inline.} =
  ## Runs an arrow of one of the two kinds, and gives an `Answer`. Generic
  ## code can thus use the two kinds in the same way.
  answer(f(a))

proc answerOf*[A, B](f: Arrow[A, B], a: A): Answer[B] {.inline.} =
  f(a)

template isSync(f: typed): bool =
  typeof(f) is SyncArrow

# --- Making arrows ------------------------------------------------------------

proc arr*[A, B](f: proc(a: A): B {.gcsafe, raises: [].}): SyncArrow[A, B] =
  ## Makes a sync arrow from a pure function that can not fail.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    ok(f(a))

proc toAsync*[A, B](f: SyncArrow[A, B]): Arrow[A, B] =
  ## Changes a sync arrow into an async arrow. Each call makes one completed
  ## future. Use it for an operation that takes only async arrows, as `within`
  ## and `both` do. `>>>` and `orElse` take a sync arrow directly.
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    answer(f(a))

proc catching*[A, B](
    f: proc(a: A): Future[Result[B, string]] {.gcsafe, raises: [].}
): Arrow[A, B] =
  ## Makes an async arrow from an async proc that can raise. An exception
  ## becomes `err(message)`, and a cancellation becomes `err("cancelled")`.
  ## This adapter makes one more future for each call. For zero overhead,
  ## write the arrow with `{.async: (raises: []).}`.
  result = proc(a: A): Future[Result[B, string]] {.async: (raises: []), gcsafe.} =
    # `awaitne` does not raise. See `waitStage`.
    let fut = f(a)
    discard awaitne fut
    if fut.cancelled():
      return err("cancelled")
    if fut.failed():
      return err(fut.error.msg)
    return fut.value()

# --- Helpers ------------------------------------------------------------------
# The procs named `...Slow` run only when an async stage must wait. A fast
# path in each combinator handles a stage that completes immediately. `G` is
# the concrete type of an arrow parameter, sync or async. The slow paths wait
# with `waitStage`, so a run that gets a cancel starts no new stage. They give
# a value from a future to the next stage in place, with `value().get`, so
# the next stage gets it without a copy.

proc thenSlow[B, C, G](
    fb: Answer[B], g: G
): Future[Result[C, string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if fb.failed:
    return err(fb.failure)
  when G is SyncArrow[B, C]:
    return g(fb.value().get)
  else:
    let fc = g(fb.value().get)
    waitStage(fc, cancelled)
    if cancelled:
      return err("cancelled")
    return outcome(fc)

proc runThen[B, C, G](fb: Answer[B], g: G): Answer[C] {.inline.} =
  ## Continues with `g` after `fb`. When `fb` is complete, this proc calls `g`
  ## directly, and the value goes to `g` without a copy. An async `g` gives
  ## the answer of the composition. A sync `g` gives a result, and this proc
  ## puts it in one completed future.
  if fb.completed():
    if fb.value().isErr:
      return failWith(C, fb.value().error)
    return answerOf(g, fb.value().get)
  thenSlow[B, C, G](fb, g)

proc orElseSecond[B](
    e: string, fc: Answer[B]
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fc, cancelled)
  if cancelled:
    return err("cancelled")
  if fc.failed:
    return err(joinErrors(e, fc.failure))
  return outcome(fc)

proc runSecond[A, B, G](e: string, g: G, a: A): Answer[B] =
  ## Runs `g`, the second stage of `orElse`, after the first stage gave the
  ## error text `e`. An `ok` of `g` is the answer. An `err` of `g` gets the
  ## two error texts. When an async `g` answers `ok` immediately, this proc
  ## gives the future of `g`.
  when G is SyncArrow[A, B]:
    let rc = g(a)
    if rc.isErr:
      return failWith(B, joinErrors(e, rc.error))
    answer(rc)
  else:
    let fc = g(a)
    if not fc.finished():
      return orElseSecond[B](e, fc)
    if fc.failed:
      return failWith(B, joinErrors(e, fc.failure))
    fc

proc orElseSlow[A, B, G](
    fb: Answer[B], g: G, a: A
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if not fb.failed:
    return outcome(fb)
  when G is SyncArrow[A, B]:
    let rc = g(a)
    if rc.isErr:
      return err(joinErrors(fb.failure, rc.error))
    return rc
  else:
    let fc = g(a)
    waitStage(fc, cancelled)
    if cancelled:
      return err("cancelled")
    if fc.failed:
      return err(joinErrors(fb.failure, fc.failure))
    return outcome(fc)

# --- Composition --------------------------------------------------------------

template composeImpl(A, B, C: typedesc, f, g: typed): untyped =
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[A, C] = proc(a: A): Result[C, string] {.gcsafe, raises: [].} =
        g(?f(a))
    elif isSync(f):
      let r: Arrow[A, C] = proc(a: A): Answer[C] {.gcsafe, raises: [].} =
        let rb = f(a)
        if rb.isErr:
          return failWith(C, rb.error)
        g(rb.get)
    else:
      let r: Arrow[A, C] = proc(a: A): Answer[C] {.gcsafe, raises: [].} =
        runThen[B, C, typeof(g)](f(a), g)
    r

proc `>>>`*[A, B, C](f: SyncArrow[A, B], g: SyncArrow[B, C]): SyncArrow[A, C] =
  ## Composes `f` and then `g` (Kleisli composition). The first `err` stops
  ## the chain. The compiler makes sure that the output type of `f` is the
  ## input type of `g`.
  composeImpl(A, B, C, f, g)

proc `>>>`*[A, B, C](f: SyncArrow[A, B], g: Arrow[B, C]): Arrow[A, C] =
  composeImpl(A, B, C, f, g)

proc `>>>`*[A, B, C](f: Arrow[A, B], g: SyncArrow[B, C]): Arrow[A, C] =
  composeImpl(A, B, C, f, g)

proc `>>>`*[A, B, C](f: Arrow[A, B], g: Arrow[B, C]): Arrow[A, C] =
  composeImpl(A, B, C, f, g)

# --- Fallback -----------------------------------------------------------------

template orElseImpl(A, B: typedesc, f, g: typed): untyped =
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[A, B] = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
        let rb = f(a)
        if rb.isOk:
          return rb
        let rc = g(a)
        if rc.isOk:
          return rc
        err(joinErrors(rb.error, rc.error))
    elif isSync(f):
      let r: Arrow[A, B] = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
        let rb = f(a)
        if rb.isOk:
          return answer(rb)
        runSecond[A, B, typeof(g)](rb.error, g, a)
    else:
      let r: Arrow[A, B] = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
        let fb = f(a)
        if not fb.finished():
          return orElseSlow[A, B, typeof(g)](fb, g, a)
        if not fb.failed:
          return fb
        runSecond[A, B, typeof(g)](fb.failure, g, a)
    r

proc orElse*[A, B](f: SyncArrow[A, B], g: SyncArrow[A, B]): SyncArrow[A, B] =
  ## Runs `f`. If `f` gives `err`, runs `g` on the same input. The first `ok`
  ## is the answer, and `g` does not run after an `ok` from `f`. When `f` and
  ## `g` give `err`, the answer has the error text of `f`, then `" | "`, then
  ## the error text of `g`. `a.orElse(b).orElse(c)` tries the stages in
  ## sequence until one gives `ok`.
  ##
  ## `orElse` does not go back. In `f.orElse(g) >>> h`, an `err` from `h` after
  ## an `ok` from `f` does not start `g`.
  orElseImpl(A, B, f, g)

proc orElse*[A, B](f: SyncArrow[A, B], g: Arrow[A, B]): Arrow[A, B] =
  orElseImpl(A, B, f, g)

proc orElse*[A, B](f: Arrow[A, B], g: SyncArrow[A, B]): Arrow[A, B] =
  orElseImpl(A, B, f, g)

proc orElse*[A, B](f: Arrow[A, B], g: Arrow[A, B]): Arrow[A, B] =
  orElseImpl(A, B, f, g)
