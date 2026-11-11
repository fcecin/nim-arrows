## A port that a different broker context provides.
##
## A broker context is the address of a set of providers. In this example,
## two nodes have their own contexts. One shared service provides `Publish`
## in a third context.
##
## The composition provides the port `Send` in the context of each node. The
## arrow of `Send` changes an `Envelope` into a `Stamped` message. Then it
## goes to the shared `Publish`, with a time limit and a name. A node calls
## `Send` in its own context, and it does not know the shared context.
##
## Run it with `nim c -r examples/e05_links.nim`.

import ../arrows

type
  Envelope = object
    topic: string
    payload: string

  Stamped = object
    env: Envelope
    origin: string

RequestBroker:
  proc Publish(msg: Stamped): Future[Result[string, string]] {.async.}

RequestBroker:
  proc Send(env: Envelope): Future[Result[string, string]] {.async.}

proc startShared(shared: BrokerContext) =
  discard Publish.setProvider(
    shared,
    proc(msg: Stamped): Future[Result[string, string]] {.async.} =
      return ok(msg.origin & " published " & msg.env.payload & " on " & msg.env.topic),
  )

proc link(node: BrokerContext, name: string, shared: BrokerContext) =
  ## Makes `Send` in the context `node` from `Publish` in the context `shared`.
  let stamp = arr(
    proc(env: Envelope): Stamped =
      Stamped(env: env, origin: name)
  )
  let publish = Publish.arrow(shared).within(chronos.seconds(1)).label("shared publish")
  doAssert Send.provide(node, stamp >>> publish).isOk

proc main() =
  let shared = NewBrokerContext()
  let alice = NewBrokerContext()
  let bob = NewBrokerContext()
  startShared(shared)
  link(alice, "alice", shared)
  link(bob, "bob", shared)

  echo waitFor Send.request(alice, Envelope(topic: "/chat", payload: "hi"))
  echo waitFor Send.request(bob, Envelope(topic: "/chat", payload: "hello"))

  # The shared service stops. Each node gets an error with the name of the link.
  Publish.clearProvider(shared)
  echo waitFor Send.request(alice, Envelope(topic: "/chat", payload: "late"))

main()
