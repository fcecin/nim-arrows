## Many providers of one port.
##
## Three store nodes provide the same port `StoreQuery`. Each node has its own
## broker context, which is its address. `StoreQuery.arrow(ctx)` is the arrow
## to one node. The nodes answer after different times.
##
## * `firstOk` asks all the nodes and keeps the first `ok`. The other runs get
##   a cancel.
## * `all` asks all the nodes and keeps all the answers.
## * `both` asks two nodes and gives the two answers as a tuple.
## * `mapAll` publishes a list of messages at the same time.
## * `mapSeq` publishes a list of messages one after the other.
## * A `MultiRequestBroker` has many providers in one context. Its arrow gives
##   the answers of all of them.
## * A proc with the shape of an arrow selects a port from the message.
##
## Run it with `nim c -r examples/e04_routing.nim`.

import std/[algorithm, sequtils, strutils]
import ../arrows

RequestBroker:
  proc StoreQuery(topic: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc RelayPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc LightpushPublish(msg: string): Future[Result[string, string]] {.async.}

MultiRequestBroker:
  type Health = object
    part*: string

  proc signature*(node: string): Future[Result[Health, string]] {.async: (raises: []).}

proc startStore(ctx: BrokerContext, name: string, delayMs: int) =
  discard StoreQuery.setProvider(
    ctx,
    proc(topic: string): Future[Result[string, string]] {.async.} =
      await sleepAsync(chronos.milliseconds(delayMs))
      return ok(name & " has 3 messages on " & topic),
  )

proc startPart(part: string) =
  discard Health.setProvider(
    proc(node: string): Future[Result[Health, string]] {.async.} =
      ok(Health(part: part & " of " & node))
  )

proc main() =
  let addrs = @[NewBrokerContext(), NewBrokerContext(), NewBrokerContext()]
  startStore(addrs[0], "store-a", 80)
  startStore(addrs[1], "store-b", 10)
  startStore(addrs[2], "store-c", 40)
  let stores = addrs.mapIt(StoreQuery.arrow(it))

  echo "first answer: ", waitFor firstOk(stores)("/news")
  echo "all answers: ", waitFor all(stores)("/news")
  echo "two answers: ", waitFor both(stores[0], stores[1])("/news")

  discard RelayPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      ok("relay: " & msg)
  )
  discard LightpushPublish.setProvider(
    proc(msg: string): Future[Result[string, string]] {.async.} =
      ok("lightpush: " & msg.len.intToStr & " bytes")
  )
  echo "at the same time: ", waitFor mapAll(RelayPublish.arrow)(@["m1", "m2", "m3"])
  echo "one after the other: ", waitFor mapSeq(RelayPublish.arrow)(@["m4", "m5"])

  # Two parts of one node answer the same port.
  startPart("relay")
  startPart("store")
  let names = arr(
    proc(answers: seq[Health]): seq[string] =
      sorted(answers.mapIt(it.part))
  )
  echo "answers from one port: ", waitFor (Health.arrow >>> names)("node-1")

  # A stage that selects a port is usual Nim code.
  let route: Arrow[string, string] = proc(
      msg: string
  ): Future[Result[string, string]] {.async: (raises: []).} =
    if msg.len <= 16:
      return await RelayPublish.request(msg)
    return await LightpushPublish.request(msg)
  echo waitFor route("short message")
  echo waitFor route("a much longer message for lightpush")

main()
