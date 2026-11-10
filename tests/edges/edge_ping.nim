## An edge module. It declares the request broker `Ping`. It imports no node
## module.

import chronos, results, brokers/request_broker

export chronos, results, request_broker

RequestBroker:
  proc Ping(n: int): Future[Result[int, string]] {.async.}
