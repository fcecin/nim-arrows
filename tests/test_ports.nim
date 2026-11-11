## The port discipline across modules. The port modules declare the brokers.
## The node modules import port modules only. Node A and node B call each
## other at run time, but no node module imports another node module.

import std/strutils
import ./helpers
import ./ports/[port_ping, port_pong, port_depth, node_a, node_b, router]

const nodeSources = [
  staticRead("ports/node_a.nim"),
  staticRead("ports/node_b.nim"),
  staticRead("ports/router.nim"),
]

suite "ports and nodes":
  test "no node module imports another node module":
    # The check reads the whole source, so an import on more than one line
    # can not hide a node module.
    for src in nodeSources:
      check "./node_" notin src
      check "./router" notin src
      check "ports/node_" notin src

  test "the nodes start in any order":
    check startRouter().isOk
    check startB().isOk
    check startA().isOk

  test "node A and node B call each other through the ports":
    check (waitFor Ping.request(5)).get == 5
    check (waitFor Pong.request(4)).get == 4
    check (waitFor Ping.request(0)).get == 0

  test "an arrow through other ports provides the router port":
    check (waitFor Depth.request(6)).get == "depth 6"
