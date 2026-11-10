## The laws of the category, `Arrow`, `ArrowChoice`, `ArrowZero`,
## `ArrowPlus` and `ArrowApply`. The laws run with stages of the three flavors
## (see `helpers`), on inputs that give `ok` and `err`. The laws about `arr`
## use pure functions.

import ./helpers

let pf = proc(x: int): int {.gcsafe, raises: [].} =
  x + 1
let pg = proc(x: int): int {.gcsafe, raises: [].} =
  x * 2

const pairs =
  [(fst: -4, snd: "a"), (fst: 0, snd: "b"), (fst: 3, snd: "c"), (fst: 7, snd: "d")]

proc fstOf(p: Pair[int, string]): int {.gcsafe, raises: [].} =
  p.fst

proc swapIt[X, Y](p: Pair[X, Y]): Pair[Y, X] {.gcsafe, raises: [].} =
  (fst: p.snd, snd: p.fst)

proc assoc(
    p: Pair[Pair[int, string], bool]
): Pair[int, Pair[string, bool]] {.gcsafe, raises: [].} =
  (fst: p.fst.fst, snd: (fst: p.fst.snd, snd: p.snd))

let nested = [
  (fst: (fst: -2, snd: "x"), snd: true),
  (fst: (fst: 5, snd: "y"), snd: false),
  (fst: (fst: 9, snd: "z"), snd: true),
]

let eithers = @[
  toLeft[int, string](-4),
  toLeft[int, string](0),
  toLeft[int, string](7),
  toLeft[int, string](10),
  toRight[int, string]("r"),
]

proc assocsum(
    e: Either[Either[int, string], bool]
): Either[int, Either[string, bool]] {.gcsafe, raises: [].} =
  if e.isRight:
    toRight[int, Either[string, bool]](toRight[string, bool](e.right))
  elif e.left.isRight:
    toRight[int, Either[string, bool]](toLeft[string, bool](e.left.right))
  else:
    toLeft[int, Either[string, bool]](e.left.left)

let nestedEithers = @[
  toLeft[Either[int, string], bool](toLeft[int, string](-1)),
  toLeft[Either[int, string], bool](toLeft[int, string](8)),
  toLeft[Either[int, string], bool](toRight[int, string]("s")),
  toRight[Either[int, string], bool](true),
]

suite "the slow-path flavor":
  test "later does not complete immediately":
    let fut = later(plus1)(1)
    check not fut.completed()
    check (waitFor fut) == Result[int, string].ok(2)

suite "Category laws":
  test "identity: idArrow >>> f == f == f >>> idArrow":
    eachFlavor(f, pickyBase):
      sameOn(idArrow[int]() >>> f, f, ints)
      sameOn(f >>> idArrow[int](), f, ints)

  test "associativity: (f >>> g) >>> h == f >>> (g >>> h)":
    eachFlavor(f, pickyBase):
      eachFlavor(g, times2):
        eachFlavor(h, showBase):
          sameOn((f >>> g) >>> h, f >>> (g >>> h), ints)

  test "<<< is >>> in the opposite direction":
    eachFlavor(f, pickyBase):
      eachFlavor(g, showBase):
        sameOn(g <<< f, f >>> g, ints)

suite "Arrow laws (Hughes)":
  test "arr id == idArrow":
    sameOn(
      arr(
        proc(x: int): int =
          x
      ),
      idArrow[int](),
      ints,
    )

  test "arr (f then g) == arr f >>> arr g":
    sameOn(
      arr(
        proc(x: int): int =
          pg(pf(x))
      ),
      arr(pf) >>> arr(pg),
      ints,
    )

  test "first (arr f) == arr (first f)":
    sameOn(
      first[int, int, string](arr(pf)),
      arr(
        proc(p: Pair[int, string]): Pair[int, string] =
          (fst: pf(p.fst), snd: p.snd)
      ),
      pairs,
    )

  test "first (f >>> g) == first f >>> first g":
    eachFlavor(f, pickyBase):
      eachFlavor(g, showBase):
        sameOn(
          first[int, string, string](f >>> g),
          first[int, int, string](f) >>> first[int, string, string](g),
          pairs,
        )

  test "first f >>> arr fst == arr fst >>> f":
    eachFlavor(f, pickyBase):
      sameOn(first[int, int, string](f) >>> arr(fstOf), arr(fstOf) >>> f, pairs)

  test "first f >>> arr (id *** g) == arr (id *** g) >>> first f":
    let idg = arr(
      proc(p: Pair[int, string]): Pair[int, string] =
        (fst: p.fst, snd: p.snd & "!")
    )
    eachFlavor(f, pickyBase):
      sameOn(
        first[int, int, string](f) >>> idg, idg >>> first[int, int, string](f), pairs
      )

  test "first (first f) >>> arr assoc == arr assoc >>> first f":
    eachFlavor(f, pickyBase):
      sameOn(
        first[Pair[int, string], Pair[int, string], bool](first[int, int, string](f)) >>>
          arr(assoc),
        arr(assoc) >>> first[int, int, Pair[string, bool]](f),
        nested,
      )

  test "f *** g == first f >>> second g":
    eachFlavor(f, pickyBase):
      eachFlavor(g, showBase):
        let pairsIn = [(fst: -1, snd: 1), (fst: 4, snd: 7), (fst: 9, snd: 2)]
        sameOn(
          f *** g, first[int, int, int](f) >>> second[int, string, int](g), pairsIn
        )

  test "f &&& g == arr dup >>> (f *** g)":
    let dup = arr(
      proc(x: int): Pair[int, int] =
        (fst: x, snd: x)
    )
    eachFlavor(f, pickyBase):
      eachFlavor(g, showBase):
        sameOn(f &&& g, dup >>> (f *** g), ints)

  test "second f == arr swap >>> first f >>> arr swap":
    eachFlavor(f, pickyBase):
      sameOn(
        second[int, int, string](f),
        arr(swapIt[string, int]) >>> first[int, int, string](f) >>>
          arr(swapIt[int, string]),
        [(fst: "a", snd: -2), (fst: "b", snd: 5)],
      )

suite "ArrowChoice laws":
  test "left (arr f) == arr (left f)":
    sameOn(
      left[int, int, string](arr(pf)),
      arr(
        proc(e: Either[int, string]): Either[int, string] =
          if e.isRight:
            e
          else:
            toLeft[int, string](pf(e.left))
      ),
      eithers,
    )

  test "left (f >>> g) == left f >>> left g":
    eachFlavor(f, pickyBase):
      eachFlavor(g, times2):
        sameOn(
          left[int, int, string](f >>> g),
          left[int, int, string](f) >>> left[int, int, string](g),
          eithers,
        )

  test "f >>> arr toLeft == arr toLeft >>> left f":
    let inl = arr(
      proc(x: int): Either[int, string] =
        toLeft[int, string](x)
    )
    eachFlavor(f, pickyBase):
      sameOn(f >>> inl, inl >>> left[int, int, string](f), ints)

  test "left f >>> arr (id +++ g) == arr (id +++ g) >>> left f":
    let idg = arr(
      proc(e: Either[int, string]): Either[int, string] =
        if e.isRight:
          toRight[int, string](e.right & "!")
        else:
          e
    )
    eachFlavor(f, pickyBase):
      sameOn(
        left[int, int, string](f) >>> idg, idg >>> left[int, int, string](f), eithers
      )

  test "left (left f) >>> arr assocsum == arr assocsum >>> left f":
    eachFlavor(f, pickyBase):
      sameOn(
        left[Either[int, string], Either[int, string], bool](left[int, int, string](f)) >>>
          arr(assocsum),
        arr(assocsum) >>> left[int, int, Either[string, bool]](f),
        nestedEithers,
      )

  test "right f == arr mirror >>> left f >>> arr mirror":
    let mirrorIn = arr(
      proc(e: Either[string, int]): Either[int, string] =
        if e.isRight:
          toLeft[int, string](e.right)
        else:
          toRight[int, string](e.left)
    )
    let mirrorOut = arr(
      proc(e: Either[int, string]): Either[string, int] =
        if e.isRight:
          toLeft[string, int](e.right)
        else:
          toRight[string, int](e.left)
    )
    let ins = @[
      toRight[string, int](-4),
      toRight[string, int](5),
      toRight[string, int](10),
      toLeft[string, int]("l"),
    ]
    eachFlavor(f, pickyBase):
      sameOn(
        right[int, int, string](f),
        mirrorIn >>> left[int, int, string](f) >>> mirrorOut,
        ins,
      )

  test "f +++ g == left f >>> right g":
    let sg: SyncArrow[string, string] = proc(s: string): Result[string, string] =
      if s == "bad":
        err("bad string")
      else:
        ok(s & s)
    let ins = eithers & @[toRight[int, string]("bad")]
    eachFlavor(f, pickyBase):
      eachFlavor(g, sg):
        sameOn(
          f +++ g, left[int, int, string](f) >>> right[string, string, int](g), ins
        )

  test "f ||| g == (f +++ g) >>> arr untag":
    let sg: SyncArrow[string, int] = proc(s: string): Result[int, string] =
      ok(s.len)
    let untag = arr(
      proc(e: Either[int, int]): int =
        if e.isRight: e.right else: e.left
    )
    eachFlavor(f, pickyBase):
      eachFlavor(g, sg):
        sameOn(f ||| g, (f +++ g) >>> untag, eithers)

suite "ArrowZero and ArrowPlus laws":
  let zero = zeroArrow[int, int]()
  test "zeroArrow <+> f == f":
    eachFlavor(f, pickyBase):
      sameOn(zero <+> f, f, ints)

  test "f <+> zeroArrow == f, with the error text of zeroArrow":
    eachFlavor(f, pickyBase):
      for x in ints:
        let lhs = run(f <+> zero, x)
        let rhs = run(f, x)
        check lhs.isOk == rhs.isOk
        if rhs.isOk:
          check lhs == rhs
        else:
          check lhs.error == "zeroArrow"

  test "associativity: (f <+> g) <+> h == f <+> (g <+> h)":
    let gb: SyncArrow[int, int] = proc(x: int): Result[int, string] =
      if x mod 2 == 0:
        ok(x * 10)
      else:
        err("odd")
    eachFlavor(f, pickyBase):
      eachFlavor(g, gb):
        eachFlavor(h, times2):
          sameOn((f <+> g) <+> h, f <+> (g <+> h), ints)

  test "left zero: zeroArrow >>> f == zeroArrow":
    eachFlavor(f, showBase):
      sameOn(zero >>> f, zeroArrow[int, string](), ints)

  test "left catch: arr p <+> g == arr p":
    eachFlavor(g, pickyBase):
      sameOn(arr(pf) <+> g, arr(pf), ints)

  test "orElse is <+>":
    eachFlavor(f, pickyBase):
      eachFlavor(g, times2):
        sameOn(f.orElse(g), f <+> g, ints)

suite "ArrowApply laws":
  test "first (arr (x -> arr (y -> (x, y)))) >>> app == idArrow":
    let mk = arr(
      proc(x: int): Arrow[int, Pair[int, int]] =
        now(
          arr(
            proc(y: int): Pair[int, int] =
              (fst: x, snd: y)
          )
        )
    )
    sameOn(
      first[int, Arrow[int, Pair[int, int]], int](mk) >>> app[int, Pair[int, int]](),
      idArrow[Pair[int, int]](),
      [(fst: 1, snd: 2), (fst: -3, snd: 4)],
    )

  test "first (arr (k -> g >>> k)) >>> app == second g >>> app":
    let g = later(pickyBase)
    let pre = arr(
      proc(k: Arrow[int, int]): Arrow[int, int] =
        g >>> k
    )
    let ks = [now(times2), later(pickyBase)]
    for k in ks:
      sameOn(
        first[Arrow[int, int], Arrow[int, int], int](pre) >>> app[int, int](),
        second[int, int, Arrow[int, int]](g) >>> app[int, int](),
        [(fst: k, snd: -2), (fst: k, snd: 5), (fst: k, snd: 9)],
      )

  test "first (arr (k -> k >>> h)) >>> app == app >>> h":
    let h = later(showBase)
    let post = arr(
      proc(k: Arrow[int, int]): Arrow[int, string] =
        k >>> h
    )
    let ks = [now(times2), later(pickyBase)]
    for k in ks:
      sameOn(
        first[Arrow[int, int], Arrow[int, string], int](post) >>> app[int, string](),
        app[int, int]() >>> h,
        [(fst: k, snd: -2), (fst: k, snd: 5), (fst: k, snd: 10)],
      )

  test "appSync runs the sync arrow in the input":
    check appSync[int, int]()((fst: pickyBase, snd: 10)) == pickyBase(10)

suite "the embedding of sync arrows into async arrows":
  test "toAsync (f >>> g) == toAsync f >>> toAsync g":
    sameOn(
      toAsync(pickyBase >>> showBase), toAsync(pickyBase) >>> toAsync(showBase), ints
    )

  test "toAsync idArrow == idArrow":
    sameOn(toAsync(idArrow[int]()), idArrow[int](), ints)

  test "two sync arrows compose to a sync arrow":
    check (pickyBase >>> showBase) is SyncArrow[int, string]
    check (pickyBase >>> later(showBase)) is Arrow[int, string]
    check (later(pickyBase) >>> showBase) is Arrow[int, string]
