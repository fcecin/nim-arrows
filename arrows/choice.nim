## Branching (`ArrowChoice`). The input type `Either[L, R]` selects the branch
## that runs. `left` and `right` apply an arrow to one branch only. `+++` maps
## each branch with its own arrow. `|||` joins two branches that have the same
## output type.
##
## The sync and async kinds mix as in `core`. Each operator gives a sync arrow
## only when all its arrows are sync.

import ./core, ./private/answers

type Either*[L, R] = object
  ## The input of the choice combinators. It holds a left value of type `L`
  ## in `left` or a right value of type `R` in `right`. `isRight` tells which
  ## one.
  case isRight*: bool
  of false:
    left*: L
  of true:
    right*: R

proc toLeft*[L, R](l: sink L): Either[L, R] =
  Either[L, R](isRight: false, left: l)

proc toRight*[L, R](r: sink R): Either[L, R] =
  Either[L, R](isRight: true, right: r)

proc isLeft*[L, R](e: Either[L, R]): bool =
  not e.isRight

proc `==`*[L, R](a, b: Either[L, R]): bool =
  ## Two values are equal when they have the same branch and equal contents.
  if a.isRight != b.isRight:
    return false
  if a.isRight:
    a.right == b.right
  else:
    a.left == b.left

proc `$`*[L, R](e: Either[L, R]): string =
  ## Gives `left(...)` or `right(...)` with the text of the value.
  if e.isRight:
    "right(" & $e.right & ")"
  else:
    "left(" & $e.left & ")"

# --- Helpers ------------------------------------------------------------------

proc leftSlow[B, D](
    fb: Answer[B]
): Future[Result[Either[B, D], string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fb, cancelled)
  if cancelled:
    return err("cancelled")
  if fb.failed:
    return err(fb.failure)
  return ok(toLeft[B, D](fb.value().get))

proc rightSlow[B, D](
    fd: Answer[D]
): Future[Result[Either[B, D], string]] {.async: (raises: []).} =
  var cancelled = false
  waitStage(fd, cancelled)
  if cancelled:
    return err("cancelled")
  if fd.failed:
    return err(fd.failure)
  return ok(toRight[B, D](fd.value().get))

proc runLeft[A, B, D, G](f: G, a: A): Answer[Either[B, D]] =
  when G is SyncArrow[A, B]:
    var rb = f(a)
    if rb.isErr:
      return answer(Result[Either[B, D], string].err(rb.error))
    answer(Result[Either[B, D], string].ok(toLeft[B, D](move(rb.value))))
  else:
    let fb = f(a)
    if fb.completed():
      if fb.value().isErr:
        return answer(Result[Either[B, D], string].err(fb.value().error))
      return answer(Result[Either[B, D], string].ok(toLeft[B, D](fb.value().get)))
    leftSlow[B, D](fb)

proc runRight[C, B, D, G](g: G, c: C): Answer[Either[B, D]] =
  when G is SyncArrow[C, D]:
    var rd = g(c)
    if rd.isErr:
      return answer(Result[Either[B, D], string].err(rd.error))
    answer(Result[Either[B, D], string].ok(toRight[B, D](move(rd.value))))
  else:
    let fd = g(c)
    if fd.completed():
      if fd.value().isErr:
        return answer(Result[Either[B, D], string].err(fd.value().error))
      return answer(Result[Either[B, D], string].ok(toRight[B, D](fd.value().get)))
    rightSlow[B, D](fd)

# --- left and right -----------------------------------------------------------

proc left*[A, B, C](f: SyncArrow[A, B]): SyncArrow[Either[A, C], Either[B, C]] =
  ## Applies `f` to a left value. A right value goes through without a change.
  result = proc(e: Either[A, C]): Result[Either[B, C], string] {.gcsafe, raises: [].} =
    if e.isRight:
      return ok(toRight[B, C](e.right))
    ok(toLeft[B, C](?f(e.left)))

proc left*[A, B, C](f: Arrow[A, B]): Arrow[Either[A, C], Either[B, C]] =
  result = proc(e: Either[A, C]): Answer[Either[B, C]] {.gcsafe, raises: [].} =
    if e.isRight:
      return answer(Result[Either[B, C], string].ok(toRight[B, C](e.right)))
    runLeft[A, B, C, Arrow[A, B]](f, e.left)

proc right*[A, B, C](f: SyncArrow[A, B]): SyncArrow[Either[C, A], Either[C, B]] =
  ## Applies `f` to a right value. A left value goes through without a change.
  result = proc(e: Either[C, A]): Result[Either[C, B], string] {.gcsafe, raises: [].} =
    if e.isRight:
      return ok(toRight[C, B](?f(e.right)))
    ok(toLeft[C, B](e.left))

proc right*[A, B, C](f: Arrow[A, B]): Arrow[Either[C, A], Either[C, B]] =
  result = proc(e: Either[C, A]): Answer[Either[C, B]] {.gcsafe, raises: [].} =
    if e.isRight:
      return runRight[A, C, B, Arrow[A, B]](f, e.right)
    answer(Result[Either[C, B], string].ok(toLeft[C, B](e.left)))

# --- +++ ----------------------------------------------------------------------

template splitChoiceImpl(A, B, C, D: typedesc, f, g: typed): untyped =
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[Either[A, C], Either[B, D]] = proc(
          e: Either[A, C]
      ): Result[Either[B, D], string] {.gcsafe, raises: [].} =
        if e.isRight:
          return ok(toRight[B, D](?g(e.right)))
        ok(toLeft[B, D](?f(e.left)))
    else:
      let r: Arrow[Either[A, C], Either[B, D]] = proc(
          e: Either[A, C]
      ): Answer[Either[B, D]] {.gcsafe, raises: [].} =
        if e.isRight:
          return runRight[C, B, D, typeof(g)](g, e.right)
        runLeft[A, B, D, typeof(f)](f, e.left)
    r

proc `+++`*[A, B, C, D](
    f: SyncArrow[A, B], g: SyncArrow[C, D]
): SyncArrow[Either[A, C], Either[B, D]] =
  ## Applies `f` to a left value and `g` to a right value. The output keeps
  ## the branch of the input.
  splitChoiceImpl(A, B, C, D, f, g)

proc `+++`*[A, B, C, D](
    f: SyncArrow[A, B], g: Arrow[C, D]
): Arrow[Either[A, C], Either[B, D]] =
  splitChoiceImpl(A, B, C, D, f, g)

proc `+++`*[A, B, C, D](
    f: Arrow[A, B], g: SyncArrow[C, D]
): Arrow[Either[A, C], Either[B, D]] =
  splitChoiceImpl(A, B, C, D, f, g)

proc `+++`*[A, B, C, D](
    f: Arrow[A, B], g: Arrow[C, D]
): Arrow[Either[A, C], Either[B, D]] =
  splitChoiceImpl(A, B, C, D, f, g)

# --- ||| ----------------------------------------------------------------------

template fanInImpl(A, B, C: typedesc, f, g: typed): untyped =
  block:
    when isSync(f) and isSync(g):
      let r: SyncArrow[Either[A, B], C] = proc(
          e: Either[A, B]
      ): Result[C, string] {.gcsafe, raises: [].} =
        if e.isRight:
          return g(e.right)
        f(e.left)
    else:
      let r: Arrow[Either[A, B], C] = proc(
          e: Either[A, B]
      ): Answer[C] {.gcsafe, raises: [].} =
        if e.isRight:
          return answerOf(g, e.right)
        answerOf(f, e.left)
    r

proc `|||`*[A, B, C](
    f: SyncArrow[A, C], g: SyncArrow[B, C]
): SyncArrow[Either[A, B], C] =
  ## Runs `f` on a left value or `g` on a right value. The two arrows have the
  ## same output type.
  fanInImpl(A, B, C, f, g)

proc `|||`*[A, B, C](f: SyncArrow[A, C], g: Arrow[B, C]): Arrow[Either[A, B], C] =
  fanInImpl(A, B, C, f, g)

proc `|||`*[A, B, C](f: Arrow[A, C], g: SyncArrow[B, C]): Arrow[Either[A, B], C] =
  fanInImpl(A, B, C, f, g)

proc `|||`*[A, B, C](f: Arrow[A, C], g: Arrow[B, C]): Arrow[Either[A, B], C] =
  fanInImpl(A, B, C, f, g)
