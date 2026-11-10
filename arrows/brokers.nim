## The bridge between arrows and nim-brokers.
##
## A broker is an edge. An edge module declares the broker and its data
## types. Node modules import edge modules, and they do not import other node
## modules. Thus the import graph has no cycles, and the calls at run time can
## go in all directions.
##
## * `Edge.arrow` gives the arrow of a request broker. An async broker gives
##   an `Arrow`, and a sync broker gives a `SyncArrow`. The arrow of a
##   `RequestBroker` returns the future of the request directly, so it makes
##   no extra future. A `MultiRequestBroker` and a broker in the `mt` mode
##   return a plain `Future`, so their arrows make one more future.
## * `Edge.provide(f)` makes the arrow `f` the provider of a request broker.
##   A composition of edges can thus become a new edge.
## * `Ev.emitter` gives a stage that emits each value as an event.
## * `Ev.drive(f)` runs the arrow `f` on each event.
##
## A request signature with one parameter gives an arrow from the type of the
## parameter. A signature with more parameters gives an arrow from a named
## tuple. The tuple has one field for each parameter, with the same name.
##
## The procs that take a broker context also take a `BrokerScope`. This
## module does not import `brokers/broker_scope`, because nim-brokers 3.4.0
## does not have it. A program that uses scopes imports it.

import std/macros
import brokers/[request_broker, multi_request_broker, event_broker, broker_context]
import ./core, ./private/answers

export request_broker, multi_request_broker, event_broker, broker_context

type ErrorSink* = proc(e: string) {.gcsafe, raises: [].}
  ## Gets the error text of each failed run of `drive`.

proc asEdgeArrow*[A, B](f: Arrow[A, B]): Arrow[A, B] {.inline.} =
  f

proc asEdgeArrow*[A, B](f: SyncArrow[A, B]): SyncArrow[A, B] {.inline.} =
  f

proc asEdgeArrow*[A, B](
    f: proc(a: A): Future[Result[B, string]] {.gcsafe, raises: [].}
): Arrow[A, B] =
  ## Changes a request that returns a plain `Future` into an `Arrow`. A
  ## `MultiRequestBroker` request has this shape. This adapter makes one more
  ## future for each call.
  catching[A, B](f)

proc syncAnswerOf*[A, B](f: SyncArrow[A, B], a: A): Result[B, string] {.inline.} =
  ## Runs the sync arrow `f`. `Edge.provide` calls it for a sync broker. The
  ## overload for an `Arrow` stops the compile with an error.
  f(a)

proc syncAnswerOf*[A, B](
  f: Arrow[A, B], a: A
): Result[B, string] {.error: "a sync broker needs a SyncArrow as provider".}

# --- Macro helpers ------------------------------------------------------------
# nim-brokers does not export the provider type of a broker. The exported
# overloads of `setProvider` hold it in their `handler` parameter. The macros
# find the overload `setProvider(_: typedesc[E], handler: H)` among the
# overloads that the call site sees, and read the provider type `H`. A
# resolved symbol is usable across modules, also when it is not exported.

proc typeName(E: NimNode): string =
  let t = E.getTypeInst
  if t.kind == nnkBracketExpr and t.len == 2:
    $t[1]
  else:
    $E

proc procParams(t: NimNode): NimNode =
  var impl = t.getTypeImpl
  if impl.kind == nnkBracketExpr and impl.len == 2:
    impl = impl[1].getTypeImpl
  if impl.kind != nnkProcTy:
    return nil
  impl[0]

proc paramCount(fp: NimNode): int =
  for i in 1 ..< fp.len:
    result += fp[i].len - 2

proc findProviderType(E, setters: NimNode): NimNode =
  let target = E.getTypeInst
  var syms: seq[NimNode]
  if setters.kind in {nnkClosedSymChoice, nnkOpenSymChoice}:
    for c in setters:
      syms.add(c)
  elif setters.kind == nnkSym:
    syms.add(setters)
  for s in syms:
    let fp = procParams(s)
    if fp.isNil or fp.len != 3 or fp[1].len != 3 or fp[2].len != 3:
      continue
    if not sameType(fp[1][1], target):
      continue
    let handler = fp[2][1]
    let hp = procParams(handler)
    if hp.isNil or paramCount(hp) == 0:
      continue
    return handler
  nil

proc sigParams(sig: NimNode): seq[(string, NimNode)] =
  for i in 1 ..< sig.len:
    let d = sig[i]
    for j in 0 ..< d.len - 2:
      result.add(($d[j], d[d.len - 2]))

proc domainOf(params: seq[(string, NimNode)]): NimNode =
  if params.len == 1:
    return params[0][1]
  result = nnkTupleTy.newTree()
  for (n, t) in params:
    result.add(nnkIdentDefs.newTree(ident(n), t, newEmptyNode()))

proc isFutureType(t: NimNode): bool =
  t.kind == nnkBracketExpr and t[0].kind in {nnkSym, nnkIdent} and
    $t[0] in ["Future", "InternalRaisesFuture"]

proc noSignature(E: NimNode) =
  error(
    "arrows: `" & typeName(E) &
      "` is not a request broker with a signature that has parameters",
    E,
  )

# --- Edge.arrow ---------------------------------------------------------------

macro edgeArrowImpl(
    E: typedesc, setters: typed, ctx: typed, useCtx: static bool
): untyped =
  let P = findProviderType(E, setters)
  if P.isNil:
    noSignature(E)
  let params = sigParams(procParams(P))
  let x = ident("x")
  let c = genSym(nskParam, "ctx")
  var callArgs: seq[NimNode]
  if useCtx:
    callArgs.add(c)
  if params.len == 1:
    callArgs.add(x)
  else:
    for (n, _) in params:
      callArgs.add(newDotExpr(x, ident(n)))
  let request = newCall(newDotExpr(E, ident("request")), callArgs)
  let lambda = newProc(
    name = newEmptyNode(),
    params = [ident("auto"), newIdentDefs(x, domainOf(params))],
    body = request,
    procType = nnkLambda,
    pragmas = nnkPragma.newTree(
      ident("gcsafe"), nnkExprColonExpr.newTree(ident("raises"), nnkBracket.newTree())
    ),
  )
  if useCtx:
    # The closure must capture a proc parameter. A `let` in a top-level block
    # is a global that the block end destroys, and a closure does not capture
    # a global.
    result = quote:
      block:
        let mk = proc(`c`: BrokerContext): auto =
          asEdgeArrow(`lambda`)
        mk(`ctx`)
  else:
    result = newCall(bindSym("asEdgeArrow"), lambda)

macro arrow*(E: typedesc): untyped =
  ## Gives the arrow of the request broker `E` in the default broker context.
  ## An example is `let send = MessagingSend.arrow`.
  newCall(
    bindSym("edgeArrowImpl"),
    E,
    ident("setProvider"),
    bindSym("DefaultBrokerContext"),
    newLit(false),
  )

macro arrow*(E: typedesc, where: typed): untyped =
  ## Gives the arrow of the request broker `E` in a broker context. `where`
  ## is a `BrokerContext` or a `BrokerScope`. To run the arrow on a value,
  ## write `(E.arrow)(value)`.
  if sameType(where.getTypeInst, bindSym("BrokerContext").getTypeInst):
    return
      newCall(bindSym("edgeArrowImpl"), E, ident("setProvider"), where, newLit(true))
  let ctx = newDotExpr(where, ident("ctx"))
  let msg = newLit(
    "arrows: the `where` of `arrow` is not a `BrokerContext` or a `BrokerScope`. " &
      "To run the arrow of `" & typeName(E) & "` on a value, write `(" & typeName(E) &
      ".arrow)(value)`. A `BrokerScope` needs an import of `brokers/broker_scope`."
  )
  result = quote:
    block:
      when not compiles(`ctx`):
        {.error: `msg`.}
      edgeArrowImpl(`E`, setProvider, `ctx`, true)

# --- Edge.provide -------------------------------------------------------------

macro provideImpl(
    E: typedesc, setters: typed, where: untyped, useWhere: static bool, f: untyped
): untyped =
  let P = findProviderType(E, setters)
  if P.isNil:
    noSignature(E)
  let sig = procParams(P)
  let ret = sig[0]
  let params = sigParams(sig)
  let fv = genSym(nskParam, "f")
  var formal = @[ret]
  for (n, t) in params:
    formal.add(newIdentDefs(ident(n), t))
  let arg =
    if params.len == 1:
      ident(params[0][0])
    else:
      var t = nnkTupleConstr.newTree()
      for (n, _) in params:
        t.add(nnkExprColonExpr.newTree(ident(n), ident(n)))
      t
  let body =
    if isFutureType(ret):
      newCall(bindSym("answerOf"), fv, arg)
    else:
      newCall(bindSym("syncAnswerOf"), fv, arg)
  let lambda = newProc(
    name = newEmptyNode(),
    params = formal,
    body = body,
    procType = nnkLambda,
    pragmas = nnkPragma.newTree(ident("gcsafe")),
  )
  let mk = genSym(nskLet, "mk")
  let built = newCall(mk, f)
  let setCall =
    if useWhere:
      newCall(newDotExpr(E, ident("setProvider")), where, built)
    else:
      newCall(newDotExpr(E, ident("setProvider")), built)
  # The provider closure captures the parameter of `mk`. See the comment in
  # `edgeArrowImpl`.
  result = quote:
    block:
      let `mk` = proc(`fv`: typeof(`f`)): `P` =
        `lambda`
      `setCall`

macro provide*(E: typedesc, f: untyped): untyped =
  ## Makes the arrow `f` the provider of the request broker `E`, in the
  ## default broker context. The answer is the `Result` of `setProvider`. An
  ## async broker accepts the two kinds of arrow. A sync broker accepts only a
  ## `SyncArrow`.
  newCall(
    bindSym("provideImpl"),
    E,
    ident("setProvider"),
    bindSym("DefaultBrokerContext"),
    newLit(false),
    f,
  )

macro provide*(E: typedesc, where: untyped, f: untyped): untyped =
  ## Makes the arrow `f` the provider of the request broker `E`. `where` is a
  ## `BrokerContext` or a `BrokerScope`. When `where` is a scope, the scope
  ## removes the provider when it closes.
  newCall(bindSym("provideImpl"), E, ident("setProvider"), where, newLit(true), f)

# --- Events -------------------------------------------------------------------

proc emitter*[E](T: typedesc[E]): SyncArrow[E, E] =
  ## Gives a stage that emits its input as the event `E` in the default broker
  ## context, and gives the input back. The listeners run later. The stage
  ## does not wait for them.
  mixin emit
  result = proc(e: E): Result[E, string] {.gcsafe, raises: [].} =
    T.emit(e)
    ok(e)

proc emitter*[E, W](T: typedesc[E], where: W): SyncArrow[E, E] =
  ## Gives a stage that emits its input as the event `E`. `where` is a
  ## `BrokerContext` or a `BrokerScope`. See the other overload.
  mixin emit, ctx
  when W is BrokerContext:
    let brokerCtx = where
  elif compiles(where.ctx):
    let brokerCtx = where.ctx
  else:
    {.
      error:
        "arrows: the `where` of `emitter` is not a `BrokerContext` or a " &
        "`BrokerScope`. A `BrokerScope` needs an import of `brokers/broker_scope`."
    .}
  result = proc(e: E): Result[E, string] {.gcsafe, raises: [].} =
    T.emit(brokerCtx, e)
    ok(e)

proc finishedRun(): Future[void].Raising([]) =
  result = Future[void].Raising([]).init("arrows.drive", {FutureFlag.OwnCancelSchedule})
  result.complete()

proc driveHandler[E, F](f: F, onError: ErrorSink): auto =
  # The listener is not an async proc. A run that is done gives a completed
  # future. A run that waits gives a future that a callback on the run
  # completes. Thus the listener makes a smaller number of futures than an
  # async proc that awaits the run.
  when F is SyncArrow:
    result = proc(ev: E): Future[void].Raising([]) {.gcsafe, raises: [].} =
      let r = f(ev)
      if r.isErr and not onError.isNil:
        onError(r.error)
      finishedRun()
  else:
    result = proc(ev: E): Future[void].Raising([]) {.gcsafe, raises: [].} =
      let fut = f(ev)
      if fut.finished():
        if fut.failed and not onError.isNil:
          onError(fut.failure)
        return finishedRun()
      let run =
        Future[void].Raising([]).init("arrows.drive", {FutureFlag.OwnCancelSchedule})
      proc onDone(udata: pointer) {.gcsafe, raises: [].} =
        if run.finished():
          return
        if fut.failed and not onError.isNil:
          onError(fut.failure)
        run.complete()

      proc onStop(udata: pointer) {.gcsafe, raises: [].} =
        # The broker stops this listener. A stop is not an error of the run.
        fut.removeCallback(onDone, nil)
        fut.cancelSoon()
        run.complete()

      fut.addCallback(onDone, nil)
      run.cancelCallback = onStop
      run

proc drive*[E, R](T: typedesc[E], f: SyncArrow[E, R], onError: ErrorSink = nil): auto =
  ## Runs the arrow `f` on each event `E` in the default broker context. A
  ## failed run calls `onError` with the error text. A run that stops because
  ## the broker stops the listener does not call `onError`. The answer is the
  ## `Result` of `listen`, which holds the listener handle.
  mixin listen
  T.listen(driveHandler[E, SyncArrow[E, R]](f, onError))

proc drive*[E, R](T: typedesc[E], f: Arrow[E, R], onError: ErrorSink = nil): auto =
  mixin listen
  T.listen(driveHandler[E, Arrow[E, R]](f, onError))

proc drive*[E, R, W](
    T: typedesc[E], where: W, f: SyncArrow[E, R], onError: ErrorSink = nil
): auto =
  ## Runs the arrow `f` on each event `E`. `where` is a `BrokerContext` or a
  ## `BrokerScope`. See the other overload.
  mixin listen
  T.listen(where, driveHandler[E, SyncArrow[E, R]](f, onError))

proc drive*[E, R, W](
    T: typedesc[E], where: W, f: Arrow[E, R], onError: ErrorSink = nil
): auto =
  mixin listen
  T.listen(where, driveHandler[E, Arrow[E, R]](f, onError))
