## A port module. It declares the request broker `Depth`. It imports no node
## module.

import chronos, results, brokers/request_broker

export chronos, results, request_broker

RequestBroker:
  proc Depth(n: int): Future[Result[string, string]] {.async.}
