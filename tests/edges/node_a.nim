## Node A. It provides `Ping` and calls `Pong`. It imports edge modules only.

import ../../arrows
import ./edge_ping, ./edge_pong

proc startA*(): Result[void, string] =
  ## Makes `Ping` a provider. `Ping(0)` is 0. `Ping(n)` is `Pong(n - 1) + 1`.
  let step: Arrow[int, int] = proc(
      n: int
  ): Future[Result[int, string]] {.async: (raises: []).} =
    if n == 0:
      return ok(0)
    let below = (await Pong.request(n - 1)).valueOr:
      return err(error)
    return ok(below + 1)
  Ping.provide(step)
