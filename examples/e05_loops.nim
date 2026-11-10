## Loops and feedback around broker edges.
##
## * `iterate` routes a message hop by hop through the edge `NextHop`. A hop
##   limit stops a route that goes in a circle.
## * `feedback` links each send to the acknowledgment of the send before it.
##   The sends start at the same time, but each send waits for its turn, so
##   the chain stays correct.
## * `feedback` with the last ids drops a duplicate message.
##
## Run: nim c -r examples/e05_loops.nim

import ../arrows

type
  Route = object
    at, dst: string
    path: seq[string]

  Linked = object
    body, prev: string

RequestBroker:
  proc NextHop(at: string, dst: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc Publish(m: Linked): Future[Result[string, string]] {.async.}

proc link(at: string): string =
  case at
  of "a": "b"
  of "b": "c"
  of "c": "d"
  of "x": "y"
  of "y": "x"
  else: ""

proc startProviders() =
  discard NextHop.setProvider(
    proc(at: string, dst: string): Future[Result[string, string]] {.async.} =
      await sleepAsync(chronos.milliseconds(1))
      if link(at).len == 0:
        return err("no link from " & at)
      return ok(link(at))
  )
  let delay = new int
  delay[] = 40
  discard Publish.setProvider(
    proc(m: Linked): Future[Result[string, string]] {.async.} =
      # Each send is faster than the send before it. Without the order of
      # `feedback`, the later sends would finish first.
      delay[] -= 10
      await sleepAsync(chronos.milliseconds(max(1, delay[])))
      return ok("ack(" & m.body & ")")
  )

proc main() =
  startProviders()

  # A `while` loop over an edge. The body reads like imperative code.
  let hop: Arrow[Route, Either[Route, seq[string]]] = proc(
      r: Route
  ): Future[Result[Either[Route, seq[string]], string]] {.async: (raises: []).} =
    if r.at == r.dst:
      return finishWith(r.path)
    let next = (await NextHop.request(r.at, r.dst)).valueOr:
      return err(error)
    return again(Route(at: next, dst: r.dst, path: r.path & next))
  let route = iterate(hop, limit = 8)
  echo "a to d: ", waitFor route(Route(at: "a", dst: "d", path: @["a"]))
  echo "x to d: ", waitFor route(Route(at: "x", dst: "d", path: @["x"]))
  echo "a to z: ", waitFor route(Route(at: "a", dst: "z", path: @["a"]))

  # Each send carries the acknowledgment of the send before it.
  let sendStep: Arrow[Pair[string, string], Pair[string, string]] = proc(
      p: Pair[string, string]
  ): Future[Result[Pair[string, string], string]] {.async: (raises: []).} =
    let ack = (await Publish.request(Linked(body: p.fst, prev: p.snd))).valueOr:
      return err(error)
    return ok((fst: p.fst & " after " & p.snd, snd: ack))
  let chained = feedback("genesis", sendStep)
  let sends = @[chained("m1"), chained("m2"), chained("m3")]
  for s in sends:
    echo "sent ", waitFor s

  # The state is the last four ids. A small state is cheap to copy.
  let dedupStep: SyncArrow[Pair[string, seq[string]], Pair[string, seq[string]]] = proc(
      p: Pair[string, seq[string]]
  ): Result[Pair[string, seq[string]], string] =
    if p.fst in p.snd:
      return err("duplicate " & p.fst)
    var recent = p.snd & p.fst
    if recent.len > 4:
      recent.delete(0)
    ok((fst: p.fst, snd: recent))
  let dedup = feedback(newSeq[string](), dedupStep)
  for id in ["k1", "k2", "k1", "k3", "k2"]:
    echo id, ": ", dedup(id)

main()
