## A port module. It declares the request broker `Pong`. It imports no node
## module.

import chronos, results, brokers/request_broker

export chronos, results, request_broker

RequestBroker:
  proc Pong(n: int): Future[Result[int, string]] {.async.}
