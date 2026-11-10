## Node B. It provides `Pong` and calls `Ping`. It imports edge modules only.

import ../../arrows
import ./edge_ping, ./edge_pong

proc startB*(): Result[void, string] =
  ## Makes `Pong` a provider. `Pong(0)` is 0. `Pong(n)` is `Ping(n - 1) + 1`.
  let split = arr(
    proc(n: int): Either[int, int] =
      if n == 0:
        toLeft[int, int](0)
      else:
        toRight[int, int](n - 1)
  )
  let step =
    Ping.arrow >>>
    arr(
      proc(x: int): int =
        x + 1
    )
  Pong.provide(split >>> (idArrow[int]() ||| step))
