## The router node. It makes the new edge `Depth` from the edge `Ping`. It
## imports edge modules only.

import ../../arrows
import ./edge_ping, ./edge_depth

proc startRouter*(): Result[void, string] =
  ## Makes `Depth` a provider. `Depth(n)` is the text of `Ping(n)`.
  Depth.provide(
    within(Ping.arrow, chronos.seconds(1)) >>>
      arr(
        proc(x: int): string =
          "depth " & $x
      )
  )
