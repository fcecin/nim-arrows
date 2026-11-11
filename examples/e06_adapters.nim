## Code that is not an arrow yet.
##
## * `catching` makes an arrow from async code that can raise.
## * A lambda with the shape of a sync arrow is a sync arrow.
## * `answer` gives a completed answer in an arrow that is not an async proc.
## * `toAsync` puts a sync arrow where an operation takes only async arrows.
## * `mapErr` changes the error text.
## * `answerOf` runs an arrow of one of the two kinds.
##
## Run it with `nim c -r examples/e06_adapters.nim`.

import std/tables
import ../arrows

RequestBroker:
  proc PeerQuery(topic: string): Future[Result[seq[string], string]] {.async.}

proc oldLookup(topic: string): Future[Result[seq[string], string]] {.async.} =
  ## Code that does not use brokers. It raises for a topic without a name.
  if topic.len == 0:
    raise newException(ValueError, "the topic has no name")
  await sleepAsync(chronos.milliseconds(5))
  return ok(@["old-" & topic])

proc show[A, B](name: string, f: SyncArrow[A, B] | Arrow[A, B], a: A) =
  ## Runs an arrow of one of the two kinds, and shows its answer.
  echo name, ": ", waitFor answerOf(f, a)

proc main() =
  discard PeerQuery.setProvider(
    proc(topic: string): Future[Result[seq[string], string]] {.async.} =
      return ok(@["remote-" & topic])
  )

  # Async code that can raise becomes an arrow. An exception becomes `err`.
  let lookup = catching[string, seq[string]](oldLookup)
  show("old code", lookup, "/news")
  show("old code, no name", lookup, "")

  # A cache is a sync arrow. It is a lambda with the correct shape.
  let known = {"/chat": @["peer-a", "peer-b"]}.toTable
  let cache: SyncArrow[string, seq[string]] = proc(
      topic: string
  ): Result[seq[string], string] =
    if topic in known:
      ok(known.getOrDefault(topic))
    else:
      err("not in the cache")
  show("cache", cache, "/chat")
  show("cache, then the port", cache.orElse(PeerQuery.arrow), "/news")

  # An arrow that is not an async proc gives a completed answer with `answer`.
  let quick: Arrow[string, seq[string]] = proc(topic: string): Answer[seq[string]] =
    if topic in known:
      return answer(Result[seq[string], string].ok(known.getOrDefault(topic)))
    PeerQuery.request(topic)
  show("quick, from the cache", quick, "/chat")
  show("quick, from the port", quick, "/news")

  # `within` takes only async arrows, so the cache goes through `toAsync`.
  show("cache with a time limit", toAsync(cache).within(chronos.seconds(1)), "/chat")

  # `mapErr` changes the error text.
  let named = cache.mapErr(
    proc(e: string): string =
      "peers of the topic: " & e
  )
  show("cache with a clear error", named, "/none")

main()
