## The router node. It makes the new port `Depth` from the port `Ping`. It
## imports port modules only.

import ../../arrows
import ./port_ping, ./port_depth

proc startRouter*(): Result[void, string] =
  ## Makes `Depth` a provider. `Depth(n)` is the text of `Ping(n)`.
  Depth.provide(
    within(Ping.arrow, chronos.seconds(1)) >>>
      arr(
        proc(x: int): string =
          "depth " & $x
      )
  )
