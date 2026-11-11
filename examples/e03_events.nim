## Events drive a pipeline, and the pipeline emits events.
##
## Each `MessageReceived` event runs a pipeline. The pipeline checks the
## message, stores it through a port, and emits `MessageStored`. A failed
## run goes to the error sink. The listener of `MessageStored` is plain
## nim-brokers code.
##
## Run it with `nim c -r examples/e03_events.nim`.

import ../arrows

EventBroker:
  type MessageReceived = object
    topic*: string
    payload*: string

EventBroker:
  type MessageStored = object
    key*: string

RequestBroker:
  proc StoreMessage(m: MessageReceived): Future[Result[string, string]] {.async.}

proc main() =
  let count = new int
  discard StoreMessage.setProvider(
    proc(m: MessageReceived): Future[Result[string, string]] {.async.} =
      inc count[]
      ok(m.topic & "#" & $count[])
  )
  discard MessageStored.listen(
    proc(e: MessageStored): Future[void] {.async: (raises: []), gcsafe.} =
      echo "stored ", e.key
  )

  let notEmpty = ensure(
    proc(m: MessageReceived): bool {.gcsafe, raises: [].} =
      m.payload.len > 0,
    "empty payload",
  )
  let toStored = arr(
    proc(key: string): MessageStored {.gcsafe, raises: [].} =
      MessageStored(key: key)
  )
  let pipeline = notEmpty >>> StoreMessage.arrow >>> toStored >>> MessageStored.emitter
  let sink: ErrorSink = proc(e: string) {.gcsafe, raises: [].} =
    echo "rejected: ", e
  doAssert MessageReceived.drive(pipeline, sink).isOk

  MessageReceived.emit(MessageReceived(topic: "/chat", payload: "hi"))
  MessageReceived.emit(MessageReceived(topic: "/chat", payload: ""))
  MessageReceived.emit(MessageReceived(topic: "/news", payload: "update"))
  waitFor sleepAsync(chronos.milliseconds(50))

main()
