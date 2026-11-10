## Routing, hedged requests and fan-out.
##
## Three store nodes provide the same edge `StoreQuery`. Each node has its own
## broker context, which is its address. The nodes have different delays.
##
## * `|||` selects a route from the shape of the message.
## * `firstOk` sends the query to all the store nodes and keeps the first
##   `ok`. The slower runs get a cancel.
## * `all` asks all the nodes and keeps all the answers.
## * `mapAll` publishes a batch of messages at the same time.
##
## Run: nim c -r examples/e04_routing.nim

import std/[sequtils, strutils]
import ../arrows

RequestBroker:
  proc StoreQuery(topic: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc RelayPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc LightpushPublish(msg: string): Future[Result[string, string]] {.async.}

proc startStore(ctx: BrokerContext, name: string, delayMs: int) =
  discard StoreQuery.setProvider(
    ctx,
    proc(topic: string): Future[Result[string, string]] {.async.} =
      await sleepAsync(chronos.milliseconds(delayMs))
      return ok(name & " has 3 messages on " & topic),
  )

proc main() =
  discard RelayPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      ok("relay: " & msg)
  )
  discard LightpushPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      ok("lightpush: " & msg.len.intToStr & " bytes")
  )

  # Routes from the shape of the message.
  let classify = arr(
    proc(msg: string): Either[string, string] {.gcsafe, raises: [].} =
      if msg.len <= 16:
        toLeft[string, string](msg)
      else:
        toRight[string, string](msg)
  )
  let route = classify >>> (RelayPublish.arrow ||| LightpushPublish.arrow)
  echo waitFor route("short message")
  echo waitFor route("a much longer message for lightpush")

  # Three store nodes, each at its own address.
  let addrs = @[NewBrokerContext(), NewBrokerContext(), NewBrokerContext()]
  startStore(addrs[0], "store-a", 80)
  startStore(addrs[1], "store-b", 10)
  startStore(addrs[2], "store-c", 40)
  let nodes = addrs.mapIt(StoreQuery.arrow(it))

  let hedged = firstOk(nodes)
  echo "first answer: ", waitFor hedged("/news")

  let everyone = all(nodes)
  echo "all answers: ", waitFor everyone("/news")

  let batch = mapAll(RelayPublish.arrow)
  echo "batch: ", waitFor batch(@["m1", "m2", "m3"])

main()
