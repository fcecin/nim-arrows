## Concurrency. These operations start async arrows at the same time.
##
## * `both` runs two arrows on the same input.
## * `all` runs a list of arrows on the same input.
## * `firstOk` runs a list of arrows and keeps the first `ok` (a race).
## * `mapAll` runs one arrow on each item of a list.
##
## `mapSeq` is the sequential twin of `mapAll`. It runs the items one after
## the other.
##
## Fail fast. When one run of `both`, `all` or `mapAll` gives `err`, the
## operation cancels the runs that did not finish and gives that `err`. When
## `firstOk` gets an `ok`, it cancels the other runs. A broker request that
## gets a cancel sends the cancel to its provider. The operation does not
## wait until a cancelled run stops.
##
## When a run of `both`, `all`, `firstOk` or `mapAll` must wait, the
## operation makes one future for its answer. It puts one callback on each
## run, so the wait takes O(n) time for a list of n runs. `mapSeq` waits for
## one item at a time in an async proc.

import ./core, ./private/answers

# --- Helpers ------------------------------------------------------------------
# When a run of `all`, `firstOk` or `mapAll` must wait, the operation puts one
# callback on each run that did not finish. The callback of run `i` gets `i` as
# its `udata`, so it does not examine the list to find its run. The callbacks
# complete the answer, which is a future that this module makes. A cancel of the
# answer removes the callbacks, cancels the runs that did not finish, and
# answers `err("cancelled")`. The variable `self` is a cursor, so that a closure
# and its environment do not make a cycle.

proc cancelPending[B](futs: openArray[Answer[B]]) =
  for f in futs:
    if not f.finished():
      f.cancelSoon()

proc stopRuns[B](runs: openArray[Answer[B]], cb: CallbackFunc) =
  ## Removes `cb` from the runs that did not finish, and cancels these runs.
  for i, f in runs:
    if not f.finished():
      f.removeCallback(cb, cast[pointer](i))
      f.cancelSoon()

proc valuesOf[B](runs: openArray[Answer[B]]): Result[seq[B], string] =
  var values = newSeqOfCap[B](runs.len)
  for f in runs:
    values.add(f.value().get)
  ok(values)

proc allFailed[B](runs: openArray[Answer[B]]): Result[B, string] =
  var text = ""
  for f in runs:
    text = joinErrors(text, f.failure)
  err(text)

proc gatherSlow[B](runs: sink seq[Answer[B]]): Answer[seq[B]] =
  let res = Answer[seq[B]].init("arrows.gather", {FutureFlag.OwnCancelSchedule})
  var left = 0
  var self {.cursor.}: CallbackFunc
  proc onRun(udata: pointer) {.gcsafe, raises: [].} =
    if res.finished():
      return
    let run = runs[cast[int](udata)]
    if run.failed:
      stopRuns(runs, self)
      self = nil
      res.complete(Result[seq[B], string].err(run.failure))
      return
    dec left
    if left == 0:
      self = nil
      res.complete(valuesOf(runs))

  proc onCancel(udata: pointer) {.gcsafe, raises: [].} =
    stopRuns(runs, self)
    self = nil
    res.complete(Result[seq[B], string].err("cancelled"))

  self = onRun
  for i, f in runs:
    if not f.finished():
      inc left
      f.addCallback(onRun, cast[pointer](i))
  res.cancelCallback = onCancel
  res

proc gather[B](futs: sink seq[Answer[B]]): Answer[seq[B]] =
  var allDone = true
  for f in futs:
    if f.finished():
      if f.failed:
        cancelPending(futs)
        return answer(Result[seq[B], string].err(f.failure))
    else:
      allDone = false
  if allDone:
    return answer(valuesOf(futs))
  gatherSlow[B](futs)

proc firstOkSlow[B](runs: sink seq[Answer[B]]): Answer[B] =
  let res = Answer[B].init("arrows.firstOk", {FutureFlag.OwnCancelSchedule})
  var left = 0
  var self {.cursor.}: CallbackFunc
  proc onRun(udata: pointer) {.gcsafe, raises: [].} =
    if res.finished():
      return
    let run = runs[cast[int](udata)]
    if not run.failed:
      stopRuns(runs, self)
      self = nil
      res.complete(outcome(run))
      return
    dec left
    if left == 0:
      self = nil
      res.complete(allFailed(runs))

  proc onCancel(udata: pointer) {.gcsafe, raises: [].} =
    stopRuns(runs, self)
    self = nil
    res.complete(Result[B, string].err("cancelled"))

  self = onRun
  for i, f in runs:
    if not f.finished():
      inc left
      f.addCallback(onRun, cast[pointer](i))
  res.cancelCallback = onCancel
  res

# --- both ---------------------------------------------------------------------

proc bothSlow[B, C](fb: Answer[B], fc: Answer[C]): Answer[(B, C)] =
  # The callbacks of the two runs have `nil` as their `udata`. Each callback
  # reads the two runs.
  let res = Answer[(B, C)].init("arrows.both", {FutureFlag.OwnCancelSchedule})
  var self {.cursor.}: CallbackFunc
  proc stop() =
    if not fb.finished():
      fb.removeCallback(self, nil)
      fb.cancelSoon()
    if not fc.finished():
      fc.removeCallback(self, nil)
      fc.cancelSoon()
    self = nil

  proc onRun(udata: pointer) {.gcsafe, raises: [].} =
    if res.finished():
      return
    if fb.finished() and fb.failed:
      stop()
      res.complete(Result[(B, C), string].err(fb.failure))
    elif fc.finished() and fc.failed:
      stop()
      res.complete(Result[(B, C), string].err(fc.failure))
    elif fb.finished() and fc.finished():
      self = nil
      res.complete(Result[(B, C), string].ok((fb.value().get, fc.value().get)))

  proc onCancel(udata: pointer) {.gcsafe, raises: [].} =
    stop()
    res.complete(Result[(B, C), string].err("cancelled"))

  self = onRun
  if not fb.finished():
    fb.addCallback(onRun, nil)
  if not fc.finished():
    fc.addCallback(onRun, nil)
  res.cancelCallback = onCancel
  res

proc both*[A, B, C](f: Arrow[A, B], g: Arrow[A, C]): Arrow[A, (B, C)] =
  ## Starts `f` and `g` at the same time on the same input, and gives the two
  ## results as a tuple.
  result = proc(a: A): Answer[(B, C)] {.gcsafe, raises: [].} =
    let fb = f(a)
    let fc = g(a)
    if fb.finished() and fb.failed:
      if not fc.finished():
        fc.cancelSoon()
      return answer(Result[(B, C), string].err(fb.failure))
    if fc.finished() and fc.failed:
      if not fb.finished():
        fb.cancelSoon()
      return answer(Result[(B, C), string].err(fc.failure))
    if fb.finished() and fc.finished():
      return answer(Result[(B, C), string].ok((fb.value().get, fc.value().get)))
    bothSlow[B, C](fb, fc)

# --- all, firstOk, mapAll, mapSeq ---------------------------------------------

proc all*[A, B](arrows: seq[Arrow[A, B]]): Arrow[A, seq[B]] =
  ## Starts all the arrows at the same time on the same input. The values come
  ## in the sequence of `arrows`. An empty list gives an empty list.
  let fs = arrows
  result = proc(a: A): Answer[seq[B]] {.gcsafe, raises: [].} =
    var futs = newSeqOfCap[Answer[B]](fs.len)
    for f in fs:
      futs.add(f(a))
    gather[B](futs)

proc firstOk*[A, B](arrows: seq[Arrow[A, B]]): Arrow[A, B] =
  ## Starts all the arrows at the same time on the same input. The first `ok`
  ## is the answer, and the other runs get a cancel. When all the runs fail,
  ## the answer is an `err` that has all the error texts, as `orElse` gives
  ## them. An empty list gives `err`.
  ##
  ## Each call starts one run for each arrow. Use `firstOk` only for requests
  ## that are safe to do more than one time.
  let fs = arrows
  result = proc(a: A): Answer[B] {.gcsafe, raises: [].} =
    if fs.len == 0:
      return answer(Result[B, string].err("firstOk: no arrows"))
    var futs = newSeqOfCap[Answer[B]](fs.len)
    for f in fs:
      futs.add(f(a))
    var allDone = true
    for f in futs:
      if f.completed() and f.value().isOk:
        cancelPending(futs)
        return f
      if not f.finished():
        allDone = false
    if allDone:
      return answer(allFailed(futs))
    firstOkSlow[B](futs)

proc mapAll*[A, B](f: Arrow[A, B]): Arrow[seq[A], seq[B]] =
  ## Starts `f` on all the items of the input list at the same time. The
  ## values come in the sequence of the items.
  result = proc(items: seq[A]): Answer[seq[B]] {.gcsafe, raises: [].} =
    var futs = newSeqOfCap[Answer[B]](items.len)
    for item in items:
      futs.add(f(item))
    gather[B](futs)

proc mapSeq*[A, B](f: SyncArrow[A, B]): SyncArrow[seq[A], seq[B]] =
  ## Runs `f` on the items of the input list, one after the other. The first
  ## `err` stops the run.
  result = proc(items: seq[A]): Result[seq[B], string] {.gcsafe, raises: [].} =
    var values = newSeqOfCap[B](items.len)
    for item in items:
      values.add(?f(item))
    ok(values)

proc mapSeqSlow[A, B](
    f: Arrow[A, B], rest: sink seq[A], values: sink seq[B], pending: Answer[B]
): Future[Result[seq[B], string]] {.async: (raises: []).} =
  # `rest` holds the items after the item of `pending`. It is a copy, because
  # the caller does not keep the input list for the wait. The two `sink`
  # parameters go into the environment of this proc without a copy.
  var cancelled = false
  var fut = pending
  var i = 0
  while true:
    waitStage(fut, cancelled)
    if cancelled:
      return err("cancelled")
    if fut.failed:
      return err(fut.failure)
    values.add(fut.value().get)
    if i >= rest.len:
      return ok(move(values))
    fut = f(rest[i])
    inc i

proc mapSeq*[A, B](f: Arrow[A, B]): Arrow[seq[A], seq[B]] =
  ## Runs `f` on the items of the input list, one after the other. Each run
  ## starts after the one before it gives `ok`. The first `err` stops the run.
  result = proc(items: seq[A]): Answer[seq[B]] {.gcsafe, raises: [].} =
    var values = newSeqOfCap[B](items.len)
    for i in 0 ..< items.len:
      let fb = f(items[i])
      if not fb.finished():
        return mapSeqSlow[A, B](f, items[i + 1 .. ^1], values, fb)
      if fb.failed:
        return answer(Result[seq[B], string].err(fb.failure))
      values.add(fb.value().get)
    answer(Result[seq[B], string].ok(values))
