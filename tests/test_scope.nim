## Broker scopes. `BrokerScope` is in nim-brokers 3.4.1 and later, so this
## suite is apart from `test_brokers`.

import brokers/broker_scope
import ./helpers

RequestBroker:
  proc Label(n: int): Future[Result[string, string]] {.async.}

EventBroker:
  type Tick = object
    n*: int

suite "the procs that take a scope":
  test "a scope removes its provider when it closes":
    let scope = newBrokerScope()
    check Label.provide(
      scope,
      arr(
        proc(x: int): string =
          "scoped" & $x
      ),
    ).isOk
    check run(Label.arrow(scope), 5).get == "scoped5"
    waitFor scope.close()
    check run(Label.arrow(scope), 5).isErr

  test "drive in a scope stops when the scope closes":
    scoped:
      let seen = new seq[int]
      let scope = newBrokerScope()
      let record = tap(
        proc(t: Tick) =
          seen[].add(t.n)
      )
      check Tick.drive(scope, record).isOk
      Tick.emit(scope.ctx, Tick(n: 1))
      waitFor sleepAsync(chronos.milliseconds(20))
      waitFor scope.close()
      Tick.emit(scope.ctx, Tick(n: 2))
      waitFor sleepAsync(chronos.milliseconds(20))
      check seen[] == @[1]

  test "emitter emits in the context of a scope":
    scoped:
      let seen = new seq[int]
      let scope = newBrokerScope()
      let record = tap(
        proc(t: Tick) =
          seen[].add(t.n)
      )
      check Tick.drive(scope, record).isOk
      check Tick.emitter(scope)(Tick(n: 7)).get == Tick(n: 7)
      check Tick.emitter(scope.ctx)(Tick(n: 8)).isOk
      let inDefault = Tick.emitter
      discard inDefault(Tick(n: 9))
      waitFor sleepAsync(chronos.milliseconds(20))
      check seen[] == @[7, 8]
      check not compiles(Tick.emitter(Tick(n: 9)))
      waitFor scope.close()
