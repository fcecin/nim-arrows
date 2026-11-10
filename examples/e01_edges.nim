## From brokers to arrows.
##
## The request brokers below are edges. In a real program, each edge is in an
## edge module, and node modules import it. In this example, all the parts are
## in one file.
##
## The providers are plain nim-brokers code. They do not know about arrows.
## Only the composition site uses arrows. It makes the new edge `Send` from
## three edges. A caller of `Send` uses `Send.request` and does not know about
## arrows either.
##
## Run: nim c -r examples/e01_edges.nim

import ../arrows

type
  Envelope = object
    topic: string
    payload: string

  Stamped = object
    env: Envelope
    seqNo: int

RequestBroker(sync):
  proc Validate(env: Envelope): Result[Envelope, string]

RequestBroker:
  proc Stamp(env: Envelope): Future[Result[Stamped, string]] {.async.}

RequestBroker:
  proc Publish(msg: Stamped): Future[Result[string, string]] {.async.}

RequestBroker:
  proc Send(env: Envelope): Future[Result[string, string]] {.async.}

proc startProviders() =
  ## Three nodes, written as plain nim-brokers providers.
  discard Validate.setProvider(
    proc(env: Envelope): Result[Envelope, string] =
      if env.topic.len == 0:
        err("no topic")
      else:
        ok(env)
  )
  let counter = new int
  discard Stamp.setProvider(
    proc(env: Envelope): Future[Result[Stamped, string]] {.async.} =
      inc counter[]
      ok(Stamped(env: env, seqNo: counter[]))
  )
  discard Publish.setProvider(
    proc(msg: Stamped): Future[Result[string, string]] {.async.} =
      ok("published #" & $msg.seqNo & " on " & msg.env.topic)
  )

proc startComposer() =
  ## The composition site. The compiler checks each seam. The output type of
  ## each edge must be the input type of the next edge.
  doAssert Send.provide(Validate.arrow >>> Stamp.arrow >>> Publish.arrow).isOk

proc main() =
  startProviders()
  startComposer()
  # A caller that knows only the edge `Send`.
  echo waitFor Send.request(Envelope(topic: "/news/1", payload: "hello"))
  echo waitFor Send.request(Envelope(topic: "/news/1", payload: "again"))
  echo waitFor Send.request(Envelope(topic: "", payload: "lost"))

main()
