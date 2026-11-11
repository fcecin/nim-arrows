## A port that an arrow through three ports provides.
##
## `Validate`, `Stamp` and `Publish` are request brokers. Each one has a plain
## nim-brokers provider. One line makes an arrow through the three ports, and
## makes that arrow the provider of a fourth port, `Send`. The compiler makes
## sure that the output type of each arrow is the input type of the next arrow.
##
## A caller of `Send` sees a broker. It does not see the composition. The
## three providers do not see it either.
##
## Run it with `nim c -r examples/e01_ports.nim`.

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

proc main() =
  startProviders()
  doAssert Send.provide(Validate.arrow >>> Stamp.arrow >>> Publish.arrow).isOk

  echo waitFor Send.request(Envelope(topic: "/news/1", payload: "hello"))
  echo waitFor Send.request(Envelope(topic: "/news/1", payload: "again"))
  echo waitFor Send.request(Envelope(topic: "", payload: "lost"))

main()
