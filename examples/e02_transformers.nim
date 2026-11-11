## Transformers around ports, with no change to the providers.
##
## A message goes out through the port `RelayPublish`. When the relay fails,
## the message goes out through the port `LightpushPublish`. The two providers
## are plain nim-brokers code. The composition adds these behaviors around
## them.
##
## * `retry` with `retryIf` runs the relay again only for an error that can go
##   away.
## * `within` gives each arrow a time limit.
## * `label` puts the name of the port in its error text.
## * `orElse` goes to lightpush when the relay fails.
## * `recover` gives a last answer when the two ports fail.
## * `tap` and `timed` show each message and the time of each send.
##
## Run it with `nim c -r examples/e02_transformers.nim`.

import std/strutils
import ../arrows

RequestBroker:
  proc RelayPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc LightpushPublish(msg: string): Future[Result[string, string]] {.async.}

proc startProviders(runsWithoutPeers: int): ref int =
  ## Starts the two providers, and gives the counter of the relay runs. The
  ## relay has no peers for its first runs. It refuses a message of more than
  ## 8 characters.
  let relayRuns = new int
  discard RelayPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      inc relayRuns[]
      if msg.len > 8:
        return err("message too large")
      if relayRuns[] <= runsWithoutPeers:
        return err("no relay peers")
      return ok("relay sent " & msg)
  )
  discard LightpushPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      await sleepAsync(chronos.milliseconds(20))
      return ok("lightpush sent " & msg)
  )
  relayRuns

proc main() =
  let noPeers: RetryIf = proc(e: string): bool =
    "no relay peers" in e
  let relay = RelayPublish.arrow
    .retry(3, chronos.milliseconds(5), 2, noPeers)
    .within(chronos.milliseconds(200))
    .label("relay")
  let lightpush =
    LightpushPublish.arrow.within(chronos.milliseconds(200)).label("lightpush")
  let trace = tap(
    proc(m: string) {.gcsafe, raises: [].} =
      echo "  sending ", m
  )
  let queue = proc(
      m: string, e: string
  ): Result[string, string] {.gcsafe, raises: [].} =
    ok("queued " & m & ", because " & e)
  let report = proc(d: Duration) {.gcsafe, raises: [].} =
    echo "  send took ", d
  let send = timed(trace >>> relay.orElse(lightpush).recover(queue), report)

  echo "The relay has no peers for two runs. The third run sends the message:"
  var relayRuns = startProviders(runsWithoutPeers = 2)
  echo "  ", waitFor send("m1")
  echo "  relay runs: ", relayRuns[]

  echo "The relay refuses the message. No new run starts, and lightpush sends it:"
  relayRuns[] = 0
  echo "  ", waitFor send("a large message")
  echo "  relay runs: ", relayRuns[]

  echo "No port has a provider. The last answer has the two error texts:"
  RelayPublish.clearProvider()
  LightpushPublish.clearProvider()
  echo "  ", waitFor send("m3")

main()
