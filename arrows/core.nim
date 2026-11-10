## The core of `arrows`. This module holds the two arrow types, the procs that
## make arrows, composition, the product combinators, `ArrowZero`,
## `ArrowPlus` and `ArrowApply`.
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
## Each operator of this module that takes arrows accepts the two kinds in
## all combinations. When all inputs are sync arrows, the result is a sync
## arrow. In all other cases, the result is an async arrow. `toAsync` is the
## embedding of the sync kind into the async kind. This embedding keeps
## composition and identity.
##
## Cost model. A sync stage makes no future. When a combinator ends with an
## async stage, it gives the future of that stage when it can. In the other
## cases, it makes one completed future for its answer. When a stage must
## wait, a combinator of this module goes on in an async proc. That proc
## makes one future for its answer, and one or two more futures for each wait.
##
## Error model. An arrow reports a failure with `err`. It does not raise. A
## cancelled arrow also answers with `err`. Each combinator stops at the first
## `err`. A combinator that waits and gets a cancel answers `err("cancelled")`
## at once. It sends the cancel to the stage that runs, and it starts no new
## stage. When a combinator does not obey one of these rules, its
## documentation tells how it is different.

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

  Pair*[X, Y] = tuple[fst: X, snd: Y]
    ## The pair of the product combinators. `fst` is the first part, and `snd`
    ## is the second part.

# --- Answers ------------------------------------------------------------------

template failWith(B: typedesc, e: string): untyped =
  answer(Result[B, string].err(e))

template okWith(B: typedesc, v: untyped): untyped =
  answer(Result[B, string].ok(v))

proc answerOf*[A, B](f: SyncArrow[A, B], a: A): Answer[B] {.inline.} =
  answer(f(a))

proc answerOf*[A, B](f: Arrow[A, B], a: A): Answer[B] {.inline.} =
  ## Runs either kind of arrow and gives an `Answer`, so that generic code
  ## can treat the two kinds in the same way.
  f(a)

template isSync*(f: typed): bool =
  ## True when `f` is a `SyncArrow`. It is a test at compile time.
  typeof(f) is SyncArrow

# --- Making arrows ------------------------------------------------------------

proc arr*[A, B](f: proc(a: A): B {.gcsafe, raises: [].}): SyncArrow[A, B] =
  ## Makes a sync arrow from a pure function that can not fail (Hughes `arr`).
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    ok(f(a))

proc idArrow*[A](): SyncArrow[A, A] =
  ## The identity arrow. It gives its input back as `ok`.
  result = proc(a: A): Result[A, string] {.gcsafe, raises: [].} =
    ok(a)

proc zeroArrow*[A, B](reason = "zeroArrow"): SyncArrow[A, B] =
  ## The arrow that always fails (`ArrowZero`). `zeroArrow <+> f` is equal to
  ## `f`. `f <+> zeroArrow` gives the `ok` of `f`, or the `err` of
  ## `zeroArrow`.
  result = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
    err(reason)

proc toAsync*[A, B](f: SyncArrow[A, B]): Arrow[A, B] =
  ## Changes a sync arrow into an async arrow. Each call makes one completed
  ## future. The combinators do not use this proc, because they run a sync
  ## stage directly.
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    answer(f(a))

proc toAsync*[A, B](f: Arrow[A, B]): Arrow[A, B] {.inline.} =
  f

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

proc pairAfter[B, D](
    b: sink B, fd: Answer[D]
): Future[Result[Pair[B, D], string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fd, cancelled)
  if cancelled:
    return err("cancelled")
  if fd.failed:
    return err(fd.failure)
  return ok((fst: move(b), snd: fd.value().get))

proc pairBefore[B, D](
    fb: Answer[B], d: sink D
): Future[Result[Pair[B, D], string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if fb.failed:
    return err(fb.failure)
  return ok((fst: fb.value().get, snd: move(d)))

proc withSecond[B, C, D, G](b: sink B, g: G, c: C): Answer[Pair[B, D]] =
  ## Runs `g` on `c` and pairs its value with `b`.
  when G is SyncArrow[C, D]:
    var rd = g(c)
    if rd.isErr:
      return failWith(Pair[B, D], rd.error)
    okWith(Pair[B, D], (fst: b, snd: move(rd.value)))
  else:
    let fd = g(c)
    if fd.completed():
      if fd.value().isErr:
        return failWith(Pair[B, D], fd.value().error)
      return okWith(Pair[B, D], (fst: b, snd: fd.value().get))
    pairAfter[B, D](b, fd)

proc splitSlow[B, C, D, G](
    fb: Answer[B], g: G, c: C
): Future[Result[Pair[B, D], string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if fb.failed:
    return err(fb.failure)
  let fd = answerOf(g, c)
  waitStage(fd, cancelled)
  if cancelled:
    return err("cancelled")
  if fd.failed:
    return err(fd.failure)
  return ok((fst: fb.value().get, snd: fd.value().get))

proc plusSlow[A, B, G](
    fb: Answer[B], g: G, a: A
): Future[Result[B, string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if not fb.failed:
    return outcome(fb)
  let fc = answerOf(g, a)
  waitStage(fc, cancelled)
  if cancelled:
    return err("cancelled")
  return outcome(fc)

# --- Composition (Category) ---------------------------------------------------

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

proc `<<<`*[A, B, C](g: SyncArrow[B, C], f: SyncArrow[A, B]): SyncArrow[A, C] =
  ## Composes in the opposite direction. `g <<< f` is equal to `f >>> g`.
  composeImpl(A, B, C, f, g)

proc `<<<`*[A, B, C](g: Arrow[B, C], f: SyncArrow[A, B]): Arrow[A, C] =
  composeImpl(A, B, C, f, g)

proc `<<<`*[A, B, C](g: SyncArrow[B, C], f: Arrow[A, B]): Arrow[A, C] =
  composeImpl(A, B, C, f, g)

proc `<<<`*[A, B, C](g: Arrow[B, C], f: Arrow[A, B]): Arrow[A, C] =
  composeImpl(A, B, C, f, g)

# --- Products (Arrow) ---------------------------------------------------------

proc first*[A, B, C](f: SyncArrow[A, B]): SyncArrow[Pair[A, C], Pair[B, C]] =
  ## Applies `f` to the first part of a pair. The second part does not change.
  result = proc(p: Pair[A, C]): Result[Pair[B, C], string] {.gcsafe, raises: [].} =
    ok((fst: ?f(p.fst), snd: p.snd))

proc first*[A, B, C](f: Arrow[A, B]): Arrow[Pair[A, C], Pair[B, C]] =
  result = proc(p: Pair[A, C]): Answer[Pair[B, C]] {.gcsafe, raises: [].} =
    let fb = f(p.fst)
    if fb.completed():
      if fb.value().isErr:
        return failWith(Pair[B, C], fb.value().error)
      return okWith(Pair[B, C], (fst: fb.value().get, snd: p.snd))
    pairBefore[B, C](fb, p.snd)

proc second*[A, B, C](f: SyncArrow[A, B]): SyncArrow[Pair[C, A], Pair[C, B]] =
  ## Applies `f` to the second part of a pair. The first part does not change.
  result = proc(p: Pair[C, A]): Result[Pair[C, B], string] {.gcsafe, raises: [].} =
    ok((fst: p.fst, snd: ?f(p.snd)))

proc second*[A, B, C](f: Arrow[A, B]): Arrow[Pair[C, A], Pair[C, B]] =
  result = proc(p: Pair[C, A]): Answer[Pair[C, B]] {.gcsafe, raises: [].} =
    withSecond[C, A, B, Arrow[A, B]](p.fst, f, p.snd)

template splitImpl(A, B, C, D: typedesc, f, g: typed): untyped =
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[Pair[A, C], Pair[B, D]] = proc(
          p: Pair[A, C]
      ): Result[Pair[B, D], string] {.gcsafe, raises: [].} =
        let b = ?f(p.fst)
        ok((fst: b, snd: ?g(p.snd)))
    elif isSync(f):
      let r: Arrow[Pair[A, C], Pair[B, D]] = proc(
          p: Pair[A, C]
      ): Answer[Pair[B, D]] {.gcsafe, raises: [].} =
        var rb = f(p.fst)
        if rb.isErr:
          return failWith(Pair[B, D], rb.error)
        withSecond[B, C, D, typeof(g)](move(rb.value), g, p.snd)
    else:
      let r: Arrow[Pair[A, C], Pair[B, D]] = proc(
          p: Pair[A, C]
      ): Answer[Pair[B, D]] {.gcsafe, raises: [].} =
        let fb = f(p.fst)
        if fb.completed():
          if fb.value().isErr:
            return failWith(Pair[B, D], fb.value().error)
          return withSecond[B, C, D, typeof(g)](fb.value().get, g, p.snd)
        splitSlow[B, C, D, typeof(g)](fb, g, p.snd)
    r

proc `***`*[A, B, C, D](
    f: SyncArrow[A, B], g: SyncArrow[C, D]
): SyncArrow[Pair[A, C], Pair[B, D]] =
  ## Applies `f` to the first part and `g` to the second part of a pair. `f`
  ## runs first. `g` runs only if `f` gives `ok`. For concurrent runs, use
  ## `both`.
  splitImpl(A, B, C, D, f, g)

proc `***`*[A, B, C, D](
    f: SyncArrow[A, B], g: Arrow[C, D]
): Arrow[Pair[A, C], Pair[B, D]] =
  splitImpl(A, B, C, D, f, g)

proc `***`*[A, B, C, D](
    f: Arrow[A, B], g: SyncArrow[C, D]
): Arrow[Pair[A, C], Pair[B, D]] =
  splitImpl(A, B, C, D, f, g)

proc `***`*[A, B, C, D](f: Arrow[A, B], g: Arrow[C, D]): Arrow[Pair[A, C], Pair[B, D]] =
  splitImpl(A, B, C, D, f, g)

template fanoutImpl(A, B, C: typedesc, f, g: typed): untyped =
  # The two stages get the same input value. This template does not copy the
  # input into a pair, as `arr dup >>> (f *** g)` does.
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[A, Pair[B, C]] = proc(
          a: A
      ): Result[Pair[B, C], string] {.gcsafe, raises: [].} =
        let b = ?f(a)
        ok((fst: b, snd: ?g(a)))
    elif isSync(f):
      let r: Arrow[A, Pair[B, C]] = proc(
          a: A
      ): Answer[Pair[B, C]] {.gcsafe, raises: [].} =
        var rb = f(a)
        if rb.isErr:
          return failWith(Pair[B, C], rb.error)
        withSecond[B, A, C, typeof(g)](move(rb.value), g, a)
    else:
      let r: Arrow[A, Pair[B, C]] = proc(
          a: A
      ): Answer[Pair[B, C]] {.gcsafe, raises: [].} =
        let fb = f(a)
        if fb.completed():
          if fb.value().isErr:
            return failWith(Pair[B, C], fb.value().error)
          return withSecond[B, A, C, typeof(g)](fb.value().get, g, a)
        splitSlow[B, A, C, typeof(g)](fb, g, a)
    r

proc `&&&`*[A, B, C](f: SyncArrow[A, B], g: SyncArrow[A, C]): SyncArrow[A, Pair[B, C]] =
  ## Gives the same input to `f` and `g`, and pairs the two results. `f` runs
  ## first. `g` runs only if `f` gives `ok`. For concurrent runs, use `both`.
  fanoutImpl(A, B, C, f, g)

proc `&&&`*[A, B, C](f: SyncArrow[A, B], g: Arrow[A, C]): Arrow[A, Pair[B, C]] =
  fanoutImpl(A, B, C, f, g)

proc `&&&`*[A, B, C](f: Arrow[A, B], g: SyncArrow[A, C]): Arrow[A, Pair[B, C]] =
  fanoutImpl(A, B, C, f, g)

proc `&&&`*[A, B, C](f: Arrow[A, B], g: Arrow[A, C]): Arrow[A, Pair[B, C]] =
  fanoutImpl(A, B, C, f, g)

# --- ArrowPlus ----------------------------------------------------------------

template plusImpl(A, B: typedesc, f, g: typed): untyped =
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[A, B] = proc(a: A): Result[B, string] {.gcsafe, raises: [].} =
        let rb = f(a)
        if rb.isOk:
          return rb
        g(a)
    elif isSync(f):
      let r: Arrow[A, B] = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
        let rb = f(a)
        if rb.isOk:
          return answer(rb)
        g(a)
    else:
      let r: Arrow[A, B] = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
        let fb = f(a)
        if fb.completed():
          if fb.value().isOk:
            return fb
          return answerOf(g, a)
        plusSlow[A, B, typeof(g)](fb, g, a)
    r

proc `<+>`*[A, B](f: SyncArrow[A, B], g: SyncArrow[A, B]): SyncArrow[A, B] =
  ## Runs `f`. If `f` gives `err`, runs `g` on the same input (`ArrowPlus`).
  ## The first `ok` wins, and `g` does not run after an `ok` from `f`.
  ## `zeroArrow <+> f` is equal to `f`.
  plusImpl(A, B, f, g)

proc `<+>`*[A, B](f: SyncArrow[A, B], g: Arrow[A, B]): Arrow[A, B] =
  plusImpl(A, B, f, g)

proc `<+>`*[A, B](f: Arrow[A, B], g: SyncArrow[A, B]): Arrow[A, B] =
  plusImpl(A, B, f, g)

proc `<+>`*[A, B](f: Arrow[A, B], g: Arrow[A, B]): Arrow[A, B] =
  plusImpl(A, B, f, g)

proc orElse*[A, B](f: SyncArrow[A, B], g: SyncArrow[A, B]): SyncArrow[A, B] =
  ## The same operation as `<+>`, with a name. `a.orElse(b).orElse(c)` tries
  ## the stages in sequence until one gives `ok`.
  plusImpl(A, B, f, g)

proc orElse*[A, B](f: SyncArrow[A, B], g: Arrow[A, B]): Arrow[A, B] =
  plusImpl(A, B, f, g)

proc orElse*[A, B](f: Arrow[A, B], g: SyncArrow[A, B]): Arrow[A, B] =
  plusImpl(A, B, f, g)

proc orElse*[A, B](f: Arrow[A, B], g: Arrow[A, B]): Arrow[A, B] =
  plusImpl(A, B, f, g)

# --- ArrowApply ---------------------------------------------------------------

proc app*[A, B](): Arrow[Pair[Arrow[A, B], A], B] =
  ## Runs the arrow that comes in the input (`ArrowApply`). With `app`, data
  ## can select the next stage at run time.
  result = proc(p: Pair[Arrow[A, B], A]): Answer[B] {.gcsafe, raises: [].} =
    p.fst(p.snd)

proc appSync*[A, B](): SyncArrow[Pair[SyncArrow[A, B], A], B] =
  ## The sync form of `app`.
  result = proc(p: Pair[SyncArrow[A, B], A]): Result[B, string] {.gcsafe, raises: [].} =
    p.fst(p.snd)
