## The laws of the library. `>>>` is associative, and the arrow of the
## identity function is its identity. `arr` and `toAsync` keep composition.
## `orElse` is associative, and a stage that fails with an empty text is its
## identity. The laws run with stages of the three flavors (see `helpers`), on
## inputs that give `ok` and `err`. Each law compares the answers of two
## arrows on a fixed list of inputs.

import ./helpers

let pf = proc(x: int): int {.gcsafe, raises: [].} =
  x + 1
let pg = proc(x: int): int {.gcsafe, raises: [].} =
  x * 2
let same = arr(
  proc(x: int): int =
    x
)
let oddFails: SyncArrow[int, int] = proc(x: int): Result[int, string] =
  if x mod 2 == 0:
    ok(x * 10)
  else:
    err("odd")
let minusOneFails: SyncArrow[int, int] = proc(x: int): Result[int, string] =
  if x == -1:
    err("minus one")
  else:
    ok(x * 2)
let silent: SyncArrow[int, int] = proc(x: int): Result[int, string] =
  err("")

suite "the slow-path flavor":
  test "later does not complete immediately":
    let fut = later(plus1)(1)
    check not fut.completed()
    check (waitFor fut).get == 2

suite "the laws of >>>":
  test "identity: arr id >>> f == f == f >>> arr id":
    eachFlavor(id, same):
      eachFlavor(f, pickyBase):
        sameOn(id >>> f, f, ints)
        sameOn(f >>> id, f, ints)

  test "associativity: (f >>> g) >>> h == f >>> (g >>> h)":
    eachFlavor(f, pickyBase):
      eachFlavor(g, times2):
        eachFlavor(h, showBase):
          sameOn((f >>> g) >>> h, f >>> (g >>> h), ints)

  test "arr keeps composition: arr (f then g) == arr f >>> arr g":
    sameOn(
      arr(
        proc(x: int): int =
          pg(pf(x))
      ),
      arr(pf) >>> arr(pg),
      ints,
    )

  test "an err stops the chain: f >>> g == f when f gives err":
    eachFlavor(f, silent):
      eachFlavor(g, times2):
        sameOn(f >>> g, f, ints)

suite "the laws of orElse":
  test "associativity: f.orElse(g).orElse(h) == f.orElse(g.orElse(h))":
    # On -1, the three stages fail. The two groups give the same error text.
    check run(pickyBase.orElse(oddFails).orElse(minusOneFails), -1).error ==
      "negative -1 | odd | minus one"
    eachFlavor(f, pickyBase):
      eachFlavor(g, oddFails):
        eachFlavor(h, minusOneFails):
          sameOn(f.orElse(g).orElse(h), f.orElse(g.orElse(h)), ints)

  test "identity: a stage that fails with an empty text changes nothing":
    eachFlavor(zero, silent):
      eachFlavor(f, pickyBase):
        sameOn(zero.orElse(f), f, ints)
        sameOn(f.orElse(zero), f, ints)

  test "an ok of the first stage is the answer: arr p .orElse g == arr p":
    eachFlavor(g, pickyBase):
      sameOn(arr(pf).orElse(g), arr(pf), ints)

suite "toAsync":
  test "toAsync keeps composition: toAsync (f >>> g) == toAsync f >>> toAsync g":
    sameOn(
      toAsync(pickyBase >>> showBase), toAsync(pickyBase) >>> toAsync(showBase), ints
    )

  test "toAsync keeps orElse: toAsync (f.orElse g) == (toAsync f).orElse (toAsync g)":
    sameOn(
      toAsync(pickyBase.orElse(oddFails)),
      toAsync(pickyBase).orElse(toAsync(oddFails)),
      ints,
    )

  test "the result is a sync arrow only when the two inputs are sync arrows":
    check (pickyBase >>> showBase) is SyncArrow[int, string]
    check (pickyBase >>> later(showBase)) is Arrow[int, string]
    check (later(pickyBase) >>> showBase) is Arrow[int, string]
    check (later(pickyBase) >>> later(showBase)) is Arrow[int, string]
    check pickyBase.orElse(oddFails) is SyncArrow[int, int]
    check pickyBase.orElse(later(oddFails)) is Arrow[int, int]
    check later(pickyBase).orElse(oddFails) is Arrow[int, int]
    check later(pickyBase).orElse(later(oddFails)) is Arrow[int, int]
