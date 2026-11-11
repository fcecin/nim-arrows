## The behavior of the concurrency operations. The timing checks use waits
## that are much longer than the event loop needs, so that the checks are
## stable on a busy machine.

import ./helpers

let failing: SyncArrow[int, int] = proc(x: int): Result[int, string] =
  err("down " & $x)

proc elapsed(t0: Moment): Duration =
  Moment.now() - t0

suite "kinds":
  test "the concurrent operations and within take async arrows":
    let a = now(plus1)
    check not compiles(both(plus1, plus1))
    check not compiles(all(@[plus1]))
    check not compiles(firstOk(@[plus1]))
    check not compiles(mapAll(plus1))
    check not compiles(within(plus1, chronos.seconds(1)))
    check compiles(both(a, a))
    check compiles(within(a, chronos.seconds(1)))
    check compiles(mapSeq(plus1))

suite "both":
  test "both runs the two arrows at the same time":
    let t0 = Moment.now()
    let r = run(both(sleeper(plus1, 60), sleeper(times2, 60)), 5)
    check r.get == (6, 10)
    check elapsed(t0) < chronos.milliseconds(110)

  test "both stops at the first err and cancels the other arrow":
    let done = new int
    let t0 = Moment.now()
    let r = run(both(sleeper(failing, 10), sleeper(times2, 300, done)), 5)
    check r.error == "down 5"
    check elapsed(t0) < chronos.milliseconds(200)
    waitFor sleepAsync(chronos.milliseconds(350))
    check done[] == 0

  test "both of two completed answers gives a completed answer":
    check both(now(plus1), now(times2))(1).completed()

  test "both answers at once when the first arrow fails at once":
    let done = new int
    let fut = both(now(failing), sleeper(plus1, 100, done))(5)
    check fut.completed()
    check fut.value().error == "down 5"
    waitFor sleepAsync(chronos.milliseconds(150))
    check done[] == 0

  test "both answers at once when one arrow fails at once, and cancels the other":
    let done = new int
    let fut = both(sleeper(plus1, 100, done), now(failing))(5)
    check fut.completed()
    check fut.value().error == "down 5"
    waitFor sleepAsync(chronos.milliseconds(150))
    check done[] == 0

suite "all":
  test "all keeps the sequence of the arrows":
    let r = run(all(@[sleeper(plus1, 40), now(times2), later(pickyBase)]), 10)
    check r.get == @[11, 20, 7]

  test "all runs the arrows at the same time":
    let t0 = Moment.now()
    discard run(all(@[sleeper(plus1, 60), sleeper(plus1, 60), sleeper(plus1, 60)]), 1)
    check elapsed(t0) < chronos.milliseconds(140)

  test "all stops at the first err and cancels the others":
    let done = new int
    let r = run(
      all(@[sleeper(plus1, 300, done), sleeper(failing, 10), sleeper(plus1, 300, done)]),
      3,
    )
    check r.error == "down 3"
    waitFor sleepAsync(chronos.milliseconds(350))
    check done[] == 0

  test "all answers at once when a run fails at once, and cancels the others":
    let done = new int
    let fut = all(@[sleeper(plus1, 100, done), now(failing)])(3)
    check fut.completed()
    check fut.value().error == "down 3"
    waitFor sleepAsync(chronos.milliseconds(150))
    check done[] == 0

  test "all of an empty list gives an empty list":
    check run(all(newSeq[Arrow[int, int]]()), 1).get.len == 0

suite "firstOk":
  test "the first ok wins and the other runs get a cancel":
    let done = new int
    let t0 = Moment.now()
    let r = run(
      firstOk(@[sleeper(plus1, 300, done), sleeper(times2, 20), sleeper(failing, 5)]), 4
    )
    check r.get == 8
    check elapsed(t0) < chronos.milliseconds(200)
    waitFor sleepAsync(chronos.milliseconds(350))
    check done[] == 0

  test "an ok that is complete at once wins at once, and the others get a cancel":
    let done = new int
    let fut = firstOk(@[sleeper(plus1, 100, done), now(times2)])(4)
    check fut.completed()
    check fut.value().get == 8
    waitFor sleepAsync(chronos.milliseconds(150))
    check done[] == 0

  test "an err does not stop the race":
    check run(firstOk(@[now(failing), sleeper(plus1, 20)]), 1).get == 2

  test "when all runs fail, the err holds all the texts":
    let r = run(firstOk(@[sleeper(failing, 10), now(failing)]), 7)
    check r.error == "down 7 | down 7"

  test "an empty list gives err":
    check run(firstOk(newSeq[Arrow[int, int]]()), 1).error == "firstOk: no arrows"

  test "when all runs fail at once, the answer is complete at once":
    let fut = firstOk(@[now(failing), now(failing)])(3)
    check fut.completed()
    check fut.value().error == "down 3 | down 3"

suite "mapAll and mapSeq":
  test "mapAll runs the items at the same time and keeps their sequence":
    let t0 = Moment.now()
    let r = run(mapAll(sleeper(times2, 60)), @[1, 2, 3, 4, 5])
    check r.get == @[2, 4, 6, 8, 10]
    check elapsed(t0) < chronos.milliseconds(140)

  test "mapAll stops at the first err":
    let r = run(mapAll(later(pickyBase)), @[5, -1, 6])
    check r.error == "negative -1"

  test "mapSeq runs the items one after the other":
    scoped:
      let order = new seq[int]
      let rec = proc(x: int): Result[int, string] =
        order[].add(x)
        ok(x)
      let t0 = Moment.now()
      let r = run(mapSeq(sleeper(rec, 25)), @[3, 1, 2])
      check r.get == @[3, 1, 2]
      check order[] == @[3, 1, 2]
      check elapsed(t0) >= chronos.milliseconds(70)

  test "mapSeq stops at the first err":
    scoped:
      let count = new int
      let rec = proc(x: int): Result[int, string] =
        inc count[]
        pickyBase(x)
      check run(mapSeq(later(rec)), @[4, -2, 9]).error == "negative -2"
      check count[] == 2

  test "mapAll and mapSeq of an empty list give an empty list":
    check run(mapAll(later(plus1)), newSeq[int]()).get.len == 0
    check run(mapSeq(later(plus1)), newSeq[int]()).get.len == 0
    check mapSeq(plus1)(newSeq[int]()).get.len == 0

  test "mapSeq of a sync arrow is a sync arrow":
    let m = mapSeq(pickyBase)
    check m is SyncArrow[seq[int], seq[int]]
    check m(@[3, 4]).get == @[0, 1]
    check m(@[3, -4]).error == "negative -4"

  test "mapSeq of completed answers gives a completed answer":
    check mapSeq(now(plus1))(@[1, 2, 3]).completed()

  test "mapSeq goes on after an item in the middle or at the end waits":
    scoped:
      let order = new seq[int]
      let rec = proc(x: int): Result[int, string] =
        order[].add(x)
        ok(x * 10)
      let pick: Arrow[int, int] = proc(x: int): Answer[int] =
        if x == 2 or x == 4:
          later(rec)(x)
        else:
          now(rec)(x)
      check run(mapSeq(pick), @[1, 2, 3, 4]).get == @[10, 20, 30, 40]
      check order[] == @[1, 2, 3, 4]

suite "a long list":
  # The runs finish one at a time, one for each turn of the event loop. A
  # wait that reads all the runs at each turn takes more than 30 s for a list
  # of 20000 runs. A wait that reads one run at each turn takes less than
  # 0.5 s. Thus a slow machine also stays below the limit of 3 s.
  proc manual(futs: ref seq[Answer[int]]): Arrow[int, int] =
    ## An arrow whose answers `finishAll` completes.
    result = proc(x: int): Answer[int] =
      let f = Answer[int].init("manual", {FutureFlag.OwnCancelSchedule})
      futs[].add(f)
      f

  proc finishAll(futs: ref seq[Answer[int]], okFrom: int) {.async.} =
    ## Completes the answers one at a time. The answers before `okFrom` are
    ## `err`.
    for i in 0 ..< futs[].len:
      if i < okFrom:
        futs[][i].complete(Result[int, string].err("e" & $i))
      else:
        futs[][i].complete(Result[int, string].ok(i))
      await sleepAsync(chronos.milliseconds(0))

  test "mapAll of 20000 items waits in linear time":
    let futs = new seq[Answer[int]]
    let t0 = Moment.now()
    let res = mapAll(manual(futs))(newSeq[int](20_000))
    waitFor finishAll(futs, okFrom = 0)
    check (waitFor res).get.len == 20_000
    check Moment.now() - t0 < chronos.seconds(3)

  test "firstOk of 20000 arrows waits in linear time":
    let futs = new seq[Answer[int]]
    var arrows: seq[Arrow[int, int]]
    for i in 0 ..< 20_000:
      arrows.add(manual(futs))
    let t0 = Moment.now()
    let res = firstOk(arrows)(1)
    waitFor finishAll(futs, okFrom = 19_999)
    check (waitFor res).get == 19_999
    check Moment.now() - t0 < chronos.seconds(3)

suite "a future that is finished but not complete":
  test "all gives err and does not wait without end":
    check bounded(all(@[broken(), sleeper(plus1, 50)]), 1).error == "cancelled"

  test "both gives err and does not wait without end":
    check bounded(both(broken(), sleeper(plus1, 50)), 1).error == "cancelled"

  test "both gives err when the other arrow completes first":
    check bounded(both(broken(), now(plus1)), 1).error == "cancelled"

  test "firstOk ignores the broken run":
    check bounded(firstOk(@[broken(), sleeper(plus1, 50)]), 1).get == 2

  test "mapAll gives err and does not wait without end":
    let b = broken()
    let pick: Arrow[int, int] = proc(x: int): Answer[int] =
      if x == 0:
        b(x)
      else:
        sleeper(plus1, 30)(x)
    check bounded(mapAll(pick), @[1, 0, 2]).error == "cancelled"
