## The README. Its code blocks compile and run here. A test makes sure that
## each code block of `README.md` is in this file. The blocks are in this file
## without their `import` line.

import std/strutils
import ./helpers

type
  Envelope = object
    topic: string

  Stamped = object
    env: Envelope

RequestBroker:
  proc RelayPublish(msg: string): Future[Result[string, string]] {.async.}

RequestBroker:
  proc LightpushPublish(msg: string): Future[Result[string, string]] {.async.}

# The first code block of the README.

# Each broker is an edge. It is a plain nim-brokers declaration.
RequestBroker(sync):
  proc Validate(env: Envelope): Result[Envelope, string]
RequestBroker:
  proc Stamp(env: Envelope): Future[Result[Stamped, string]] {.async.}
RequestBroker:
  proc Publish(msg: Stamped): Future[Result[string, string]] {.async.}
RequestBroker:
  proc Send(env: Envelope): Future[Result[string, string]] {.async.}

# One line makes a new edge from three edges. The compiler checks the types at
# each seam.
discard Send.provide(Validate.arrow >>> Stamp.arrow >>> Publish.arrow)

# Middleware around an edge, with no change to its provider.
let relay = RelayPublish.arrow.retry(3, 5.milliseconds, 2).within(200.milliseconds)
let sendAny = relay.orElse(LightpushPublish.arrow)

# The second code block of the README.

let route: Arrow[string, string] = proc(
    msg: string
): Future[Result[string, string]] {.async: (raises: []).} =
  if msg.len <= 16:
    return await RelayPublish.request(msg)
  return await LightpushPublish.request(msg)

proc nimBlocks(md: string): seq[string] =
  ## The `nim` code blocks of a Markdown text, without their `import` lines.
  var inNim, inOther = false
  var lines: seq[string]
  for line in md.splitLines:
    if line.startsWith("```"):
      if inNim:
        result.add(lines.join("\n"))
        lines.setLen(0)
        inNim = false
      elif inOther:
        inOther = false
      elif line.strip == "```nim":
        inNim = true
      else:
        inOther = true
    elif inNim and not line.startsWith("import "):
      lines.add(line)

suite "README":
  test "each code block of the README is in this file":
    const readme = staticRead("../README.md")
    const self = staticRead("test_readme.nim")
    let blocks = nimBlocks(readme)
    check blocks.len == 2
    for b in blocks:
      check b.strip in self

  test "the second code block selects the edge from the message":
    discard RelayPublish.setProvider(
      proc(msg: string): Future[Result[string, string]] {.async.} =
        return ok("relay: " & msg)
    )
    discard LightpushPublish.setProvider(
      proc(msg: string): Future[Result[string, string]] {.async.} =
        return ok("lightpush: " & msg)
    )
    check run(route, "short").get == "relay: short"
    check run(route, "a message with more than 16 characters").get ==
      "lightpush: a message with more than 16 characters"
    check run(sendAny, "m").get == "relay: m"
    RelayPublish.clearProvider()
    LightpushPublish.clearProvider()

  test "an edge without a provider gives err":
    check run(route, "short").isErr
    check run(sendAny, "m").isErr
