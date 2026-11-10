## The edge discipline across modules. The edge modules declare the brokers.
## The node modules import edge modules only. Node A and node B call each
## other at run time, but no node module imports another node module.

import std/strutils
import ./helpers
import ./edges/[edge_ping, edge_pong, edge_depth, node_a, node_b, router]

const nodeSources = [
  staticRead("edges/node_a.nim"),
  staticRead("edges/node_b.nim"),
  staticRead("edges/router.nim"),
]

suite "edges and nodes":
  test "no node module imports another node module":
    # The check reads the whole source, so an import on more than one line
    # can not hide a node module.
    for src in nodeSources:
      check "./node_" notin src
      check "./router" notin src
      check "edges/node_" notin src

  test "the nodes start in any order":
    check startRouter().isOk
    check startB().isOk
    check startA().isOk

  test "node A and node B call each other through the edges":
    check (waitFor Ping.request(5)).get == 5
    check (waitFor Pong.request(4)).get == 4
    check (waitFor Ping.request(0)).get == 0

  test "the router edge is a composition of other edges":
    check (waitFor Depth.request(6)).get == "depth 6"
