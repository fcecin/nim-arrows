## Shared fixtures for the test suites.
##
## Each law test runs with the three flavors of a stage.
## * `sync` is a `SyncArrow`.
## * `now` is an `Arrow` that completes immediately. It runs the fast paths.
## * `later` is an `Arrow` that waits for one turn of the event loop. It runs
##   the slow paths.

import std/unittest
import ../arrows

export arrows, unittest

proc now*[A, B](f: SyncArrow[A, B]): Arrow[A, B] =
  ## An async arrow that completes immediately.
  toAsync(f)

proc later*[A, B](f: SyncArrow[A, B]): Arrow[A, B] =
  ## An async arrow that waits for one turn of the event loop.
  result = proc(a: A): Future[Result[B, string]] {.async: (raises: []).} =
    try:
      await sleepAsync(chronos.milliseconds(0))
    except CancelledError:
      return err("cancelled")
    return f(a)

proc sleeper*[A, B](f: SyncArrow[A, B], ms: int, done: ref int = nil): Arrow[A, B] =
  ## An async arrow that waits `ms` milliseconds before it answers. When the
  ## wait completes, it adds 1 to `done`.
  result = proc(a: A): Future[Result[B, string]] {.async: (raises: []).} =
    try:
      await sleepAsync(chronos.milliseconds(ms))
    except CancelledError:
      return err("cancelled")
    if not done.isNil:
      inc done[]
    return f(a)

proc run*[A, B](f: SyncArrow[A, B], a: A): Result[B, string] =
  f(a)

proc run*[A, B](f: Arrow[A, B], a: A): Result[B, string] =
  waitFor f(a)

template eachFlavor*(name: untyped, base: typed, body: untyped) =
  ## Runs `body` three times, with `name` bound to each flavor of `base`.
  block:
    let name {.inject.} = base
    body
  block:
    let name {.inject.} = now(base)
    body
  block:
    let name {.inject.} = later(base)
    body

template sameOn*(lhs, rhs: typed, inputs: openArray) =
  ## Checks that two arrows give equal answers on all the inputs.
  for x in inputs:
    check run(lhs, x) == run(rhs, x)

# Stages with ok and err paths.
let plus1* = arr(
  proc(x: int): int =
    x + 1
)
let times2* = arr(
  proc(x: int): int =
    x * 2
)
let pickyBase*: SyncArrow[int, int] = proc(x: int): Result[int, string] =
  if x < 0:
    err("negative " & $x)
  else:
    ok(x - 3)
let showBase*: SyncArrow[int, string] = proc(x: int): Result[string, string] =
  if x == 7:
    err("seven")
  else:
    ok("#" & $x)

const ints* = [-4, -1, 0, 1, 2, 3, 6, 7, 9, 10]

template scoped*(body: untyped) =
  ## Runs `body` in a local proc. A lambda in `body` can then capture the
  ## local variables of the test, and stay GC-safe.
  proc scopedBody() =
    body

  scopedBody()

proc broken*(): Arrow[int, int] =
  ## An arrow whose `Answer` goes to the cancelled state after 10 ms. A real
  ## `Answer` completes with `err` when it gets a cancel. This arrow checks
  ## the guards for an `Answer` that is finished but not complete.
  result = proc(x: int): Answer[int] =
    let fut = Answer[int].init("broken", {FutureFlag.OwnCancelSchedule})
    proc fire(udata: pointer) {.gcsafe, raises: [].} =
      fut.cancelAndSchedule()

    discard setTimer(Moment.fromNow(chronos.milliseconds(10)), fire, nil)
    fut

template bounded*(f: Arrow, x: untyped): untyped =
  ## Runs `f` on `x` with a limit of 2 s. A run that does not finish gives
  ## `err("no answer in 2 s")`. An answer in the cancelled state gives
  ## `err("answer in the cancelled state")`.
  block:
    let fut = f(x)
    if not waitFor withTimeout(fut, chronos.seconds(2)):
      typeof(fut.value()).err("no answer in 2 s")
    elif not fut.completed():
      typeof(fut.value()).err("answer in the cancelled state")
    else:
      fut.value()
