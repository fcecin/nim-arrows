## Node B. It provides `Pong` and calls `Ping`. It imports edge modules only.

import ../../arrows
import ./edge_ping, ./edge_pong

proc startB*(): Result[void, string] =
  ## Makes `Pong` a provider. `Pong(0)` is 0. `Pong(n)` is `Ping(n - 1) + 1`.
  let step: Arrow[int, int] = proc(
      n: int
  ): Future[Result[int, string]] {.async: (raises: []).} =
    if n == 0:
      return ok(0)
    let below = (await Ping.request(n - 1)).valueOr:
      return err(error)
    return ok(below + 1)
  Pong.provide(step)
