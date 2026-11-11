# nim-arrows

**NOTE: This is experimental software.**

`arrows` gives each request broker of [nim-brokers](https://github.com/NagyZoltanPeter/nim-brokers) its arrow. An arrow is a typed connection from an `A` to a `B` that can fail. A nim-brokers request has the shape of an arrow. This library has the operations that compose arrows and put middleware around them.

```nim
import arrows

# Each broker is an edge. It is a plain nim-brokers declaration.
RequestBroker(sync):
  proc Validate(env: Envelope): Result[Envelope, string]
RequestBroker:
  proc Stamp(env: Envelope): Future[Result[Stamped, string]] {.async.}
RequestBroker:
  proc Publish(msg: Stamped): Future[Result[string, string]] {.async.}
RequestBroker:
  proc Send(env: Envelope): Future[Result[string, string]] {.async.}

# One line makes a new edge from three edges. The compiler checks the types at
# each seam.
discard Send.provide(Validate.arrow >>> Stamp.arrow >>> Publish.arrow)

# Middleware around an edge, with no change to its provider.
let relay = RelayPublish.arrow.retry(3, 5.milliseconds, 2).within(200.milliseconds)
let sendAny = relay.orElse(LightpushPublish.arrow)
```

## Edges and arrows

A request broker is an edge. A component that calls the broker and the component that provides it have only the broker and its data types in common. `Edge.arrow` gives the edge as a value. `Edge.arrow(ctx)` is the edge to the provider in the broker context `ctx`.

`f >>> g` makes one arrow from two arrows. The compiler makes sure that the output type of `f` is the input type of `g`. The composition does not connect the two providers. The component that has the composition calls `f`, and then it calls `g` with the answer of `f`.

The compiler does not make sure that an edge has a provider. nim-brokers finds the provider at the time of the call. A request to an edge without a provider gives `err`.

Each broker goes in an edge module, with its data types. A node module imports edge modules, and it does not import other node modules. Thus the imports have no cycles, but the calls can go in all directions.

```
node A ──Pong──> node B
node A <──Ping── node B
```

Node A provides `Ping` and calls `Pong`. Node B provides `Pong` and calls `Ping`. Node A and node B import only `edge_ping` and `edge_pong`. The calls make a cycle at run time, and the compiler does not see this cycle. `tests/test_edges.nim` checks this with real modules.

## The two kinds of arrow

| Type | Shape | Math |
| --- | --- | --- |
| `SyncArrow[A, B]` | `proc(a: A): Result[B, string]` | Kleisli arrow of `Result` |
| `Arrow[A, B]` | `proc(a: A): Answer[B]` | Kleisli arrow of `Future ∘ Result` |

`Answer[B]` is `Future[Result[B, string]].Raising([])`. A nim-brokers request returns this type. Thus the arrow of a `RequestBroker` returns the future of the request directly, and it makes no future of its own. A `MultiRequestBroker` and a broker in the `mt` mode return a plain `Future`, so their arrows make one more future.

A lambda with the correct shape is an arrow. `>>>` and `orElse` accept the two kinds in all combinations. When the two inputs are sync arrows, the result is a sync arrow. In the other cases, the result is an async arrow. A sync stage does not make a future.

## The operations

| Operation | Effect |
| --- | --- |
| `arr(f)` | Makes a sync arrow from a pure function. |
| `catching(f)` | Makes an async arrow from async code that can raise. An exception becomes `err`. |
| `toAsync(f)` | Makes an async arrow from a sync arrow. |
| `answer(r)` | Makes a completed `Answer` from a `Result`, for an async arrow that is not an async proc. |
| `answerOf(f, a)` | Runs an arrow of one of the two kinds, and gives an `Answer`. |
| `f >>> g` | Runs `f`, and then runs `g` on the answer of `f`. The first `err` stops the chain. |
| `f.orElse(g)` | Runs `g` on the same input when `f` gives `err`. When the two stages fail, the answer has the two error texts. |
| `tap(f)` | Calls `f` with the value, and gives the value to the next stage. |
| `ensure(pred, reason)` | Gives `err(reason)` when `pred` is false for the value. |
| `timed(f, report)` | Calls `report` with the time that `f` took. |
| `retry(f, attempts, backoff, factor, retryIf)` | Runs `f` again after an `err`, with a pause that grows. With `retryIf`, only the errors that `retryIf` accepts start a new run. |
| `recover(f, g)` | Calls `g` with the input and the error text when `f` gives `err`. `g` gives a value or a different error. |
| `mapErr(f, g)` | Changes the error text of `f` with `g`. |
| `label(f, name)` | Puts `name` before the error text of `f`. |
| `within(f, timeout)` | Cancels `f` and gives `err` when `f` does not answer in time. |
| `both(f, g)` | Starts `f` and `g` at the same time, and gives the two values as a tuple. |
| `all(fs)` | Starts all the arrows of a list at the same time, and gives the list of their values. |
| `firstOk(fs)` | Starts all the arrows of a list at the same time, and gives the first `ok`. |
| `mapAll(f)` | Starts `f` on all the items of a list at the same time. |
| `mapSeq(f)` | Runs `f` on the items of a list, one after the other. |
| `Edge.arrow`, `Edge.arrow(ctx)` | Gives the arrow of a request broker. |
| `Edge.provide(f)`, `Edge.provide(ctx, f)` | Makes the arrow `f` the provider of a request broker. |
| `Ev.emitter`, `Ev.emitter(ctx)` | Gives a stage that emits each value as the event `Ev`. |
| `Ev.drive(f, onError)`, `Ev.drive(ctx, f, onError)` | Runs the arrow `f` on each event `Ev`. `onError` gets the error text of each failed run. |

`both`, `all` and `mapAll` stop at the first `err`, and they cancel the runs that did not finish. `ctx` is a `BrokerContext` or a `BrokerScope`.

An edge with one parameter gives an arrow from the type of that parameter. An edge with more parameters gives an arrow from a named tuple. The tuple has one field for each parameter, with the same name.

The library has no operators for pairs, branches or loops. Write such a stage as a proc with the shape of an arrow. The body of the proc is usual Nim code.

```nim
let route: Arrow[string, string] = proc(
    msg: string
): Future[Result[string, string]] {.async: (raises: []).} =
  if msg.len <= 16:
    return await RelayPublish.request(msg)
  return await LightpushPublish.request(msg)
```

## Examples

`nimble examples` runs the examples and compares their output with `examples/expected`.

| File | Subject |
| --- | --- |
| `e01_edges.nim` | A new edge from three edges. |
| `e02_middleware.nim` | A retry, a time limit, a fallback and a last answer around two edges. |
| `e03_events.nim` | Events that drive a pipeline, and a pipeline that emits events. |
| `e04_routing.nim` | Many providers of one edge, with a race, a fan-out and a route. |
| `e05_links.nim` | An edge that a node gets from a different broker context. |

## Laws

`>>>` is associative, and the arrow of the identity function is its identity. Thus the arrows are a category. `arr` and `toAsync` keep composition.

`orElse` is associative. When all the stages fail, the answer has the error texts of all the stages in sequence. The groups of the stages do not change the text. A stage that fails with an empty text is the identity of `orElse`.

The suite `tests/test_laws.nim` checks these laws. Each law compares the answers of two arrows on a fixed list of inputs. The laws run with stages of three flavors. The flavors are sync, async with an immediate answer, and async with a later answer. Thus the laws include the fast paths and the slow paths.

`orElse` does not go back. In `f.orElse(g) >>> h`, an `err` from `h` after an `ok` from `f` does not start `g`. `tests/test_combinators.nim` checks this rule.

## Cost

`nimble bench` compares `arrows` with hand-written code. The values are in nanoseconds for each call, the minimum of three runs of a release build.

In the first table, each provider answers immediately.

| Workload | Hand-written | arrows |
| --- | --- | --- |
| 10 pure stages | 82 (async proc) | 101 (sync call), 151 (awaited) |
| 3 broker edges | 762 | 581 |
| 4 pure stages and 2 edges | 556 | 544 |
| Fallback, 2 edges fail | 737 | 704 |
| `label`, `retry` and `within` on one edge | 201 (bare edge) | 223 |

In the second table, each provider waits one turn of the event loop, as a provider that does input or output does.

| Workload | Hand-written | arrows |
| --- | --- | --- |
| 3 broker edges | 3400 | 4723 |
| 4 pure stages and 2 edges | 2338 | 4604 |
| `label`, `retry` and `within` on one edge | 1031 (bare edge) | 3152 |

When the providers answer immediately, `arrows` is as fast as hand-written code, or faster. A hand-written async proc makes its own future. The arrows use the futures of the requests. A pure stage costs approximately 10 ns, because it is a closure call.

When a provider waits, `arrows` is slower than hand-written code. Each combinator that waits continues in its own async proc, and that proc makes its own futures. One hand-written async proc does all its waits in one future. The difference is 1 to 2.5 microseconds for each call in these workloads.

`>>>` gives the value of a stage to the next stage without a copy. `tests/test_combinators.nim` counts the copies. `both`, `all`, `firstOk` and `mapAll` put one callback on each run, so a wait for n runs takes O(n) time.

## Errors and cancellation

An arrow reports a failure with `err`, and it does not raise. The type `Answer` makes the compiler check this. A cancelled arrow also gives `err`.

The error type is `string`. A failed request, a time limit and a cancel all give an `err` with a text. `orElse` runs its second stage after each `err` of its first stage. Without `retryIf`, `retry` starts a new run after each `err`.

A combinator that waits and gets a cancel answers `err("cancelled")` at once. It sends the cancel to the stage that runs, and it starts no new stage. Thus `within(relay.orElse(lightpush), t)` does not send through `lightpush` after the time limit, and `retry` makes no new attempt after a cancel. When a combinator gives the future of a stage as its answer, the cancel goes to that stage.

A cancel tells a stage to stop. The combinator does not wait until the stage stops. The work that the stage did before the cancel stays done. Thus an `err` from `within` does not show that the stage did nothing.

- `within(relay, t).orElse(lightpush)` sends through `lightpush` after the time limit. The relay provider can also send the same message.
- `retry(within(f, t), n)` can start a new run before the cancelled run stops.
- `firstOk` starts one run for each arrow.

Use `retry`, `orElse` and `firstOk` only with requests that are safe to do more than one time.

`within`, `firstOk`, `both`, `all` and `mapAll` cancel the runs that they stop. A broker request that gets a cancel sends the cancel to its provider. `tests/test_cancel.nim` checks the cancel contract for each combinator.

## Threads

An arrow is a closure, so use it only in the thread that made it. A broker in the multi-thread mode, `RequestBroker(mt)`, is an edge between nodes in different threads. Each thread makes its own arrow of the edge. The provider runs in the thread that set it, and that thread must keep its event loop running. `tests/test_threads.nim` checks this.

## Limits

- The error type is `string`, the same as in nim-brokers.
- An edge must have a request signature with one or more parameters.
- An arrow is a closure. A program can not read from an arrow which edges the arrow calls.
- `BrokerScope` needs nim-brokers 3.4.1 or later. A program that uses scopes imports `brokers/broker_scope`.
- With Nim 2.2.4 to 2.2.10 and ORC, an async proc does not free an exception that it catches after an `await` (Nim issue #23615, fixed in Nim 2.2.12). Thus each cancelled chronos async proc leaks its `CancelledError`, and a nim-brokers request leaks when its provider fails or gets a cancel. The combinators of `arrows` catch no exception, so they do not leak. Use Nim 2.2.12 or later, or refc.

## License

Unlicense
