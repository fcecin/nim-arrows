## The future of an async arrow, and the helpers that the modules of `arrows`
## share. `core` exports `Answer` and `answer`. The other names are internal.

import chronos, results

type Answer*[B] = InternalRaisesFuture[Result[B, string], void]
  ## The future of an async arrow. It holds `ok(value)` or `err(text)`, and it
  ## can not raise. A nim-brokers request returns this type.

proc answer*[B](r: sink Result[B, string]): Answer[B] {.inline.} =
  ## Makes a completed `Answer` that holds `r`. Use it in an async arrow that
  ## does not use the `async` pragma.
  result = Answer[B].init("arrows", {FutureFlag.OwnCancelSchedule})
  result.complete(r)

proc outcome*[B](f: Answer[B]): Result[B, string] =
  ## Gives a copy of the result of a finished future. An `Answer` that is in
  ## the cancelled state gives `err("cancelled")`.
  if f.completed():
    f.value()
  else:
    Result[B, string].err("cancelled")

proc failed*[B](f: Answer[B]): bool {.inline.} =
  ## True when the finished `f` holds `err`, or is in the cancelled state.
  not f.completed() or f.value().isErr

proc failure*[B](f: Answer[B]): string {.inline.} =
  ## The error text of a finished `f` that `failed`.
  if f.completed():
    f.value().error
  else:
    "cancelled"

proc joinErrors*(a, b: string): string =
  ## The error text of two failures, in the sequence of the stages. An empty
  ## text adds nothing.
  if a.len == 0:
    b
  elif b.len == 0:
    a
  else:
    a & " | " & b

template waitStage*(fut, cancelled: untyped) =
  ## Waits until the `Answer` `fut` finishes, in a `raises: []` async proc.
  ## `fut` must be a variable. A plain `await` sends a cancel of the proc to
  ## `fut`. But the proc does not see the cancel, and it can start a new stage
  ## after it. This template sees the cancel, sends it to `fut`, and sets the
  ## `bool` variable `cancelled` to true. The caller then returns
  ## `err("cancelled")`. (A `return` in a template does not work in an async
  ## proc, because the `async` macro does not see it.) After the wait, the
  ## caller reads `fut.value().get`, which does not copy the value.
  ##
  ## The wait uses `awaitne` and reads the state of the `join` future, so no
  ## exception goes through the async proc. With ORC, Nim 2.2.4 to 2.2.10
  ## leak each exception that a closure iterator catches after a `yield` (Nim
  ## issue #23615, fixed in Nim 2.2.12). The other waits of `arrows` use the
  ## same method.
  let joined = fut.join()
  discard awaitne joined
  if joined.cancelled():
    fut.cancelSoon()
    cancelled = true
