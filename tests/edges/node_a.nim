## Node A. It provides `Ping` and calls `Pong`. It imports edge modules only.

import ../../arrows
import ./edge_ping, ./edge_pong

proc startA*(): Result[void, string] =
  ## Makes `Ping` a provider. `Ping(0)` is 0. `Ping(n)` is `Pong(n - 1) + 1`.
  let split = arr(
    proc(n: int): Either[int, int] =
      if n == 0:
        toLeft[int, int](0)
      else:
        toRight[int, int](n - 1)
  )
  let step =
    Pong.arrow >>>
    arr(
      proc(x: int): int =
        x + 1
    )
  Ping.provide(split >>> (idArrow[int]() ||| step))
