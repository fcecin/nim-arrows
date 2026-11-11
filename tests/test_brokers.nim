## The bridge between arrows and nim-brokers.

import std/strutils
import ./helpers

RequestBroker:
  proc Ping(n: int): Future[Result[int, string]] {.async.}

RequestBroker:
  proc Pong(n: int): Future[Result[string, string]] {.async.}

RequestBroker:
  proc Lookup(key: string, ver: int): Future[Result[string, string]] {.async.}

RequestBroker:
  proc SlowEcho(n: int): Future[Result[int, string]] {.async.}

RequestBroker:
  proc Boom(n: int): Future[Result[int, string]] {.async.}

RequestBroker(sync):
  proc Measure(s: string, extra: int): Result[int, string]

RequestBroker(sync):
  proc Twice(n: int): Result[int, string]

RequestBroker:
  proc GetCfg(): Future[Result[int, string]] {.async.}

MultiRequestBroker:
  type Vote = object
    who*: string

  proc signature*(topic: string): Future[Result[Vote, string]] {.async: (raises: []).}

EventBroker:
  type Seen = object
    n*: int

discard Ping.setProvider(
  proc(n: int): Future[Result[int, string]] {.async.} =
    ok(n + 1)
)
discard Measure.setProvider(
  proc(s: string, extra: int): Result[int, string] =
    ok(s.len + extra)
)

suite "Edge.arrow":
  test "an async broker gives an Arrow":
    let p = Ping.arrow
    check p is Arrow[int, int]
    check run(p, 1).get == 2

  test "a sync broker with two parameters gives a SyncArrow from a named tuple":
    let m = Measure.arrow
    check m is SyncArrow[tuple[s: string, extra: int], int]
    check m((s: "abc", extra: 10)).get == 13

  test "an edge arrow composes with the other arrows":
    let show = arr(
      proc(x: int): string =
        "#" & $x
    )
    check run(Ping.arrow >>> Ping.arrow >>> show, 1).get == "#3"

  test "a broker without parameters and an event type are not request edges":
    check not compiles(GetCfg.arrow)
    check not compiles(Seen.arrow)
    check not compiles(GetCfg.provide(plus1))

  test "an edge without a provider gives err":
    check run(Pong.arrow, 1).isErr

  test "an exception in a provider becomes err":
    discard Boom.setProvider(
      proc(n: int): Future[Result[int, string]] {.async.} =
        raise newException(ValueError, "provider broke")
    )
    let r = run(Boom.arrow, 1)
    check r.isErr
    check "provider broke" in r.error

  test "a context selects the provider":
    let ctx = NewBrokerContext()
    discard Ping.setProvider(
      ctx,
      proc(n: int): Future[Result[int, string]] {.async.} =
        ok(n + 100),
    )
    check run(Ping.arrow(ctx), 1).get == 101
    check run(Ping.arrow, 1).get == 2

  test "a value that is not a context gives a compile error":
    # `Ping.arrow(5)` reads as `arrow(Ping, 5)`. The arrow runs as
    # `(Ping.arrow)(5)`.
    check not compiles(Ping.arrow(5))
    check (waitFor (Ping.arrow)(5)).get == 6

  test "a MultiRequestBroker gives an arrow to a list":
    discard Vote.setProvider(
      proc(topic: string): Future[Result[Vote, string]] {.async.} =
        ok(Vote(who: "a:" & topic))
    )
    discard Vote.setProvider(
      proc(topic: string): Future[Result[Vote, string]] {.async.} =
        ok(Vote(who: "b:" & topic))
    )
    let votes = run(Vote.arrow, "t").get
    check votes.len == 2
    check votes[0].who.endsWith(":t")

suite "Edge.provide":
  test "a composition of edges becomes a new edge":
    let show = arr(
      proc(x: int): string =
        "#" & $x
    )
    check Pong.provide(Ping.arrow >>> Ping.arrow >>> show).isOk
    check (waitFor Pong.request(1)).get == "#3"
    Pong.clearProvider()

  test "a sync arrow can provide an async broker":
    check Pong.provide(
      arr(
        proc(x: int): string =
          "s" & $x
      )
    ).isOk
    check (waitFor Pong.request(4)).get == "s4"
    Pong.clearProvider()

  test "a sync broker accepts a sync arrow":
    check Twice.provide(times2).isOk
    check Twice.request(21).get == 42

  test "a sync broker does not accept an async arrow":
    check not compiles(Twice.provide(Ping.arrow))

  test "a broker with two parameters gets its arrow from a named tuple":
    let f: SyncArrow[tuple[key: string, ver: int], string] = proc(
        x: tuple[key: string, ver: int]
    ): Result[string, string] =
      ok(x.key & "@" & $x.ver)
    check Lookup.provide(f).isOk
    check (waitFor Lookup.request("cfg", 3)).get == "cfg@3"

  test "a provider can go in a context":
    let ctx = NewBrokerContext()
    check Pong.provide(
      ctx,
      later(
        arr(
          proc(x: int): string =
            "ctx" & $x
        )
      ),
    ).isOk
    check (waitFor Pong.request(ctx, 2)).get == "ctx2"
    check (waitFor Pong.request(2)).isErr

  test "a MultiRequestBroker accepts an arrow as one provider":
    let ctx = NewBrokerContext()
    check Vote.provide(
      ctx,
      arr(
        proc(topic: string): Vote =
          Vote(who: "arrow:" & topic)
      ),
    ).isOk
    check run(Vote.arrow(ctx), "x").get == @[Vote(who: "arrow:x")]

suite "cancellation through an edge":
  test "a cancel from within goes to the provider":
    scoped:
      let finished = new int
      discard SlowEcho.setProvider(
        proc(n: int): Future[Result[int, string]] {.async.} =
          await sleepAsync(chronos.milliseconds(150))
          inc finished[]
          return ok(n)
      )
      let r = run(within(SlowEcho.arrow, chronos.milliseconds(15)), 1)
      check "timed out" in r.error
      waitFor sleepAsync(chronos.milliseconds(250))
      check finished[] == 0

suite "events":
  test "drive runs the pipeline on each event, and emitter emits":
    scoped:
      let seen = new seq[int]
      let record = tap(
        proc(s: Seen) =
          seen[].add(s.n)
      )
      let pipeline =
        arr(
          proc(s: Seen): Seen =
            Seen(n: s.n * 10)
        ) >>> record
      let handle = Seen.drive(pipeline)
      check handle.isOk
      let source =
        arr(
          proc(x: int): Seen =
            Seen(n: x)
        ) >>> Seen.emitter
      check source(4).get == Seen(n: 4)
      discard source(5)
      waitFor sleepAsync(chronos.milliseconds(20))
      check seen[] == @[40, 50]
      waitFor Seen.dropListener(handle.get)
      discard source(6)
      waitFor sleepAsync(chronos.milliseconds(20))
      check seen[] == @[40, 50]

  test "drive gives each error to the error sink":
    scoped:
      let errors = new seq[string]
      let ctx = NewBrokerContext()
      let picky = later(
        ensure(
          proc(s: Seen): bool =
            s.n > 0,
          "not positive",
        )
      )
      let sink: ErrorSink = proc(e: string) =
        errors[].add(e)
      check Seen.drive(ctx, picky, sink).isOk
      discard Seen.emitter(ctx)(Seen(n: -1))
      discard Seen.emitter(ctx)(Seen(n: 3))
      waitFor sleepAsync(chronos.milliseconds(20))
      check errors[] == @["not positive"]

  test "drive gives the err of a sync arrow and of an arrow that answers at once":
    scoped:
      let errors = new seq[string]
      let ctx = NewBrokerContext()
      let sink: ErrorSink = proc(e: string) =
        errors[].add(e)
      let picky = ensure(
        proc(s: Seen): bool =
          s.n > 0,
        "not positive",
      )
      check Seen.drive(ctx, picky.label("sync"), sink).isOk
      check Seen.drive(ctx, now(picky).label("now"), sink).isOk
      discard Seen.emitter(ctx)(Seen(n: -1))
      discard Seen.emitter(ctx)(Seen(n: 3))
      waitFor sleepAsync(chronos.milliseconds(20))
      check errors[].len == 2
      check "sync: not positive" in errors[]
      check "now: not positive" in errors[]

  test "drive takes an inline lambda of each kind":
    scoped:
      let seen = new seq[int]
      let ctx = NewBrokerContext()
      check Seen.drive(
        ctx,
        proc(s: Seen): Result[int, string] =
          seen[].add(s.n)
          ok(s.n),
      ).isOk
      check Seen.drive(
        ctx,
        proc(s: Seen): Future[Result[int, string]] {.async: (raises: []).} =
          seen[].add(s.n * 10)
          return ok(s.n),
      ).isOk
      discard Seen.emitter(ctx)(Seen(n: 2))
      waitFor sleepAsync(chronos.milliseconds(20))
      check seen[].len == 2
      check 2 in seen[]
      check 20 in seen[]
      check compiles(
        Seen.drive(
          proc(s: Seen): Result[int, string] =
            ok(s.n)
        )
      )
