## Middleware around edges, with no change to the providers.
##
## The relay provider fails two times and then works. The lightpush provider
## always works, but it is slower. The composition adds retries with a
## growing pause, a time limit, error labels, a fallback and a timer. The
## providers stay plain nim-brokers code.
##
## Run: nim c -r examples/e02_middleware.nim

import ../arrows

RequestBroker:
  proc RelayPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc LightpushPublish(msg: string): Future[Result[string, string]] {.async.}

proc startProviders(relayFailures: int) =
  let calls = new int
  discard RelayPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      inc calls[]
      if calls[] <= relayFailures:
        return err("no relay peers (call " & $calls[] & ")")
      return ok("relay sent " & msg)
  )
  discard LightpushPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      await sleepAsync(chronos.milliseconds(20))
      return ok("lightpush sent " & msg)
  )

proc main() =
  let report = proc(d: Duration) {.gcsafe, raises: [].} =
    echo "  send took ", d
  let trace = tap(
    proc(m: string) {.gcsafe, raises: [].} =
      echo "  sending ", m
  )
  let relay = RelayPublish.arrow
    .retry(3, chronos.milliseconds(5), 2)
    .within(chronos.milliseconds(200))
    .label("relay")
  let lightpush =
    LightpushPublish.arrow.within(chronos.milliseconds(200)).label("lightpush")
  let send = timed(trace >>> (relay <+> lightpush), report)

  echo "relay fails two times, and the third try works:"
  startProviders(relayFailures = 2)
  echo "  ", waitFor send("m1")

  echo "relay fails all three tries, and lightpush answers:"
  RelayPublish.clearProvider()
  LightpushPublish.clearProvider()
  startProviders(relayFailures = 10)
  echo "  ", waitFor send("m2")

  echo "no provider at all:"
  RelayPublish.clearProvider()
  LightpushPublish.clearProvider()
  echo "  ", waitFor send("m3")

main()
