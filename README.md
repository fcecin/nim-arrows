# nim-arrows

**NOTE: This is experimental software.**

`arrows` gives Hughes arrows to [nim-brokers](https://github.com/NagyZoltanPeter/nim-brokers). An arrow is a typed connection from an `A` to a `B` that can fail. A nim-brokers request is already an arrow. This library gives each request broker its arrow, and the combinators to compose them.

The library is optional. Brokers, providers and callers do not change when you use it. The arrows go only at the composition site.

```nim
import arrows

# Each broker is an edge between nodes. It is a plain nim-brokers declaration.
RequestBroker(sync):
  proc Validate(env: Envelope): Result[Envelope, string]
RequestBroker:
  proc Stamp(env: Envelope): Future[Result[Stamped, string]] {.async.}
RequestBroker:
  proc Publish(msg: Stamped): Future[Result[string, string]] {.async.}
RequestBroker:
  proc Send(env: Envelope): Future[Result[string, string]] {.async.}

# One line makes a new edge from three edges. The compiler checks each seam.
discard Send.provide(Validate.arrow >>> Stamp.arrow >>> Publish.arrow)

# Middleware around an edge, with no change to its provider.
let relay = RelayPublish.arrow.retry(3, 5.milliseconds, 2).within(200.milliseconds)
let sendAny = relay <+> LightpushPublish.arrow
```

## What you get

- Composition with a type check at each seam (`>>>`, `<<<`).
- Products, branches and fallbacks (`***`, `&&&`, `+++`, `|||`, `<+>`).
- Middleware for each stage (`retry`, `within`, `timed`, `tap`, `label`, `recover`, `mapErr`, `ensure`).
- Concurrent runs that stop at the first failure (`both`, `all`, `mapAll`) and hedged requests (`firstOk`).
- A `while` loop in one run (`iterate`) and a state between runs (`feedback`).
- A bridge in two directions. `Edge.arrow` gives the arrow of a broker, and `Edge.provide(f)` makes an arrow the provider of a broker.
- Events that drive a pipeline (`Ev.drive(f)`) and a stage that emits events (`Ev.emitter`).

## Nodes, edges and arrows

A program with brokers is a graph. The nodes are the components that provide and call requests. The edges are the request brokers. A broker connects the nodes that call it to the node that provides it. A broker context is the address of a node.

The math of arrows is also a graph, a category. Its nodes are types, and its edges are the arrows. The request broker `Stamp(env: Envelope): Stamped` is an edge in the two graphs. Between nodes, it connects a caller to a provider. Between types, it goes from `Envelope` to `Stamped`. `Stamp.arrow` gives this edge as a value that you can compose. `f >>> g` joins two edges into a path, and the path is also an arrow. The compiler checks that the path connects.

Each broker goes in an edge module, with its data types. A node module imports edge modules, and it does not import other node modules. Thus the imports have no cycles, but the calls can go in all directions.

```
node A ──Pong──> node B
node A <──Ping── node B
```

Node A provides `Ping` and calls `Pong`. Node B provides `Pong` and calls `Ping`. The calls make a cycle, but node A and node B import only `edge_ping` and `edge_pong`. `tests/test_edges.nim` checks this with real modules. `Edge.arrow(ctx)` is the edge to the node at the address `ctx`.

## The two kinds of arrow

| Type | Shape | Math |
| --- | --- | --- |
| `SyncArrow[A, B]` | `proc(a: A): Result[B, string]` | Kleisli arrow of `Result` |
| `Arrow[A, B]` | `proc(a: A): Answer[B]` | Kleisli arrow of `Future ∘ Result` |

`Answer[B]` is `Future[Result[B, string]].Raising([])`. A nim-brokers request returns this type. Thus the arrow of a `RequestBroker` returns the future of the request directly, and it makes no future of its own. A `MultiRequestBroker` and a broker in the `mt` mode return a plain `Future`, so their arrows make one more future.

A lambda with the correct shape is already an arrow. `arr` makes a sync arrow from a pure function. `catching` makes an async arrow from async code that can raise.

The composition, product, choice and fallback operators accept the two kinds in all combinations. When all their inputs are sync arrows, the result is a sync arrow. In the other cases, the result is an async arrow. `both`, `all`, `firstOk`, `mapAll` and `within` take async arrows, because a sync arrow has nothing to wait for. `toAsync` changes a sync arrow into an async arrow. A sync stage does not make a future.

## The combinators

| Group | Operations |
| --- | --- |
| Basic arrows | `arr`, `idArrow`, `zeroArrow` |
| Adapters | `toAsync`, `catching`, `answer`, `answerOf` |
| Category | `>>>`, `<<<` |
| Arrow | `first`, `second`, `***`, `&&&` |
| ArrowChoice | `left`, `right`, `+++`, `\|\|\|`, with `Either`, `toLeft`, `toRight` |
| ArrowPlus | `<+>` and its name `orElse` |
| ArrowApply | `app`, `appSync` |
| Transformers | `tap`, `ensure`, `timed`, `retry`, `recover`, `mapErr`, `label`, `within` |
| Concurrency | `both`, `all`, `firstOk`, `mapAll`, `mapSeq` |
| Loops | `iterate` with `again` and `finishWith`, `feedback` |
| Brokers | `Edge.arrow`, `Edge.provide`, `Ev.emitter`, `Ev.drive` |

`***` and `&&&` run their stages in sequence. The second stage starts only after an `ok` from the first stage. This is the Kleisli definition. For concurrent runs, use `both`.

An edge with one parameter gives an arrow from the type of that parameter. An edge with more parameters gives an arrow from a named tuple. The tuple has one field for each parameter, with the same name.

Some procs take explicit generic parameters, because their arguments do not give the compiler all the types. Examples are `idArrow[int]()`, `zeroArrow[int, int]()`, `toLeft[int, string](x)` and `app[int, int]()`. In `first`, `second`, `left` and `right`, the last generic parameter is the type that goes through without a change, as in `first[int, int, string](f)`.

## Loops and feedback

In imperative code, a loop sends a value back to an earlier point. A `while` loop sends the loop variable back to the next iteration. An object sends its state back to its next call. `arrows` has the two forms.

`iterate(step)` is the `while` loop in one run. The step gives `again(v)` to run again with `v`, or `finishWith(v)` to stop with the result `v`. The first `err` stops the loop. After `limit` steps without a result, the answer is `err`. The loop does not use the stack.

```nim
let hop: Arrow[Route, Either[Route, seq[string]]] = proc(
    r: Route
): Future[Result[Either[Route, seq[string]], string]] {.async: (raises: []).} =
  if r.at == r.dst:
    return finishWith(r.path)
  let next = (await NextHop.request(r.at, r.dst)).valueOr:
    return err(error)
  return again(Route(at: next, dst: r.dst, path: r.path & next))
let route = iterate(hop, limit = 8)
```

`feedback(initial, step)` keeps a state between runs, as a Mealy machine does. Each run gives the input and the state to the step. The step gives the output and the next state. An `err` does not change the state.

```nim
let numbered = feedback(
  0,
  arr(
    proc(p: Pair[string, int]): Pair[string, int] =
      (fst: $(p.snd + 1) & ": " & p.fst, snd: p.snd + 1)
  ),
)
# numbered("hello") gives ok("1: hello"), and numbered("world") gives ok("2: world").
```

Async runs of a `feedback` arrow use the state in the order of the calls. Each run waits until the run before it is done, so each run sees the state that the run before it made. A run that gets a cancel before its turn does not run its step. A closure with a `var` also keeps a state between runs. But two async runs of such a closure can overlap, and then one run can write over the update of the other run.

The step reads the state as a part of its input. A sync step reads it without a copy. A step that is an async proc copies its input, and the `feedback` arrow copies the next state from the future of the step. A step that changes the state works on its own copy. For a large state, use a `ref` type, so that these copies are cheap. Then a step must not change the state on a path that gives `err`.

`ArrowLoop` sends an output back to an input of the same run. A strict language can not do that, because the value does not exist before the run. `feedback` is `ArrowLoop` with a delay of one run.

## Laws

The suite `tests/test_laws.nim` checks the laws of the category, `Arrow`, `ArrowChoice`, `ArrowZero`, `ArrowPlus` and `ArrowApply`. It also checks that the embedding of sync arrows into async arrows keeps composition. The laws run with stages of three flavors. The flavors are sync, async with an immediate answer, and async with a later answer. Thus the laws cover the fast paths and the slow paths. The laws about `arr` use pure functions.

`<+>` is the left-catch form of `ArrowPlus`. `zeroArrow <+> f` is equal to `f`. `f <+> zeroArrow` is equal to `f` when `f` gives `ok`. When `f` gives `err`, the error text is the text of `zeroArrow`.

The suite `tests/test_loops.nim` checks the `ArrowLoop` laws for `feedback` in their delayed form. These are the laws for no state, left tightening, right tightening, sliding, vanishing and superposing. Each law compares two sequences of runs. Right tightening needs an `h` that does not fail, because an `err` in the step keeps the state. The suite also checks the fixed-point equation of `iterate`, `iterate(s) == s >>> (iterate(s) ||| idArrow)`.

## Cost

`nimble bench` compares `arrows` with hand-written code. The "naive" column is a design with one async closure for each stage. The values are in nanoseconds for each call, the minimum of three runs of a release build.

| Workload | Hand-written | Naive | arrows |
| --- | --- | --- | --- |
| 10 pure stages | 81 (async proc) | 2126 | 112 (sync call) |
| 3 broker edges | 879 | 1406 | 676 |
| 4 pure stages and 2 edges | 655 | 1844 | 618 |
| Fallback, 2 edges fail | 865 | | 688 |
| `label`, `retry` and `within` on one edge | 236 (bare edge) | | 254 |
| `&&&` on a 1 KiB message | less than 1 | | 20 |

With broker edges, `arrows` is as fast as hand-written code, or faster. A hand-written async proc makes its own future. The arrows use the futures of the requests. A pure stage costs approximately 10 ns, because it is a closure call.

The combinators give a value to the next stage without a copy. An async proc copies its parameters, so a stage that is an async proc keeps its own copy of its input. A combinator copies a value one time in these three cases.

- A value goes from the future of a stage into a new value or a new future. Examples are a pair, an `Either`, a list, and the answer of a combinator that had to wait. Other code can also read the future of a stage, so the combinators do not take the value out of it. Hand-written code makes the same copy when it awaits a value.
- An input goes into a new output, as the second part of a pair goes through `first`. The caller keeps its input.
- An input goes to a stage after a wait, because the caller does not keep its input for the wait. Examples are `&&&`, `***` and `<+>` when their first stage waits, and `retry` and `recover` when their stage waits. A `feedback` run that waits for its turn also keeps a copy of its input. When an item of `mapSeq` waits, `mapSeq` copies the items that did not start.

`&&&` gives the same input to its two stages. When its first stage does not wait, it does not copy the input. The form `arr dup >>> (f *** g)` copies the message two times, and a call takes 892 ns. `tests/test_combinators.nim` counts the copies.

`both`, `all`, `firstOk` and `mapAll` put one callback on each run, so a wait for n runs takes O(n) time.

## Errors and cancellation

An arrow reports a failure with `err`, and it does not raise. The type `Answer` makes the compiler check this. A cancelled arrow also gives `err`.

A combinator that waits and gets a cancel answers `err("cancelled")` at once. It sends the cancel to the stage that runs, and it starts no new stage. Thus `within(relay <+> lightpush, t)` does not send through `lightpush` after the timeout, and `retry` makes no new attempt after a cancel. A combinator that gives the future of a stage, as `|||` does, sends the cancel to that stage. `feedback` waits for a step that runs, because the step must finish with the state.

`within`, `firstOk` and the fail-fast combinators cancel the runs that they stop. A cancelled broker request stops its provider. `tests/test_cancel.nim` checks the cancel contract for each combinator.

## Threads

An arrow is a closure, so use it only in the thread that made it. A broker in the multi-thread mode, `RequestBroker(mt)`, is an edge between nodes in different threads. Each thread makes its own arrow of the edge. The provider runs in the thread that set it, and that thread must keep its event loop running. `tests/test_threads.nim` checks this.

## Limits

- The error type is `string`, the same as in nim-brokers.
- An edge must have a request signature with one or more parameters.
- `BrokerScope` needs nim-brokers 3.4.1 or later. A program that uses scopes imports `brokers/broker_scope`.
- With Nim 2.2.4 to 2.2.10 and ORC, an async proc does not free an exception that it catches after an `await` (Nim issue #23615, fixed in Nim 2.2.12). Thus each cancelled chronos async proc leaks its `CancelledError`, and a nim-brokers request leaks when its provider fails or gets a cancel. The combinators of `arrows` catch no exception, so they do not leak. Use Nim 2.2.12 or later, or refc.

## License

Unlicense
