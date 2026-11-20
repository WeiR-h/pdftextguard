///|
priv enum PageAlignment {
  DrawingOrder
  UniquePositions(Array[Int32])
}

///|
priv struct PositionIndex {
  cells : Map[(Int32, Int32), Array[Int32]]
}

///|
fn cell(coordinate : Double) -> Int32 {
  (coordinate * 50.0).floor().to_int()
}

///|
fn PositionIndex::first_near(
  self : PositionIndex,
  pose : Matrix,
  accept : (Int32) -> Bool,
) -> Int32? {
  // Search only cells touched by the tolerance window. Slightly widen the
  // search to include points at floating-point cell boundaries; accept still
  // checks the exact pose tolerance.
  let reach = 0.0100000001
  for x in cell(pose.x - reach)..<=cell(pose.x + reach) {
    for y in cell(pose.y - reach)..<=cell(pose.y + reach) {
      if self.cells.get((x, y)) is Some(bucket) {
        for index in bucket {
          if accept(index) {
            return Some(index)
          }
        }
      }
    }
  }
  None
}

///|
fn index_positions(uses : Array[GlyphUse]) -> Result[PositionIndex, GlyphUse] {
  let index : PositionIndex = { cells: Map([]), }
  for i, glyph in uses {
    if index.first_near(glyph.pose, j => {
        uses[j].same_shape(glyph) && same_pose(uses[j].pose, glyph.pose)
      })
      is Some(_) {
      return Err(glyph)
    }
    let key = (cell(glyph.pose.x), cell(glyph.pose.y))
    match index.cells.get(key) {
      Some(items) => {
        // Bound pathological numbers of layered draws at identical origins.
        if items.length() >= 64 {
          return Err(glyph)
        }
        items.push(i)
      }
      None => index.cells.set(key, [i])
    }
  }
  Ok(index)
}

///|
fn compatible_use(old : GlyphUse, current : GlyphUse) -> Bool {
  old.same_shape(current) &&
  same_pose(old.pose, current.pose) &&
  near(old.advance, current.advance)
}

///|
fn exact_pose(a : Matrix, b : Matrix) -> Bool {
  a.x == b.x &&
  a.y == b.y &&
  a.a == b.a &&
  a.b == b.b &&
  a.c == b.c &&
  a.d == b.d
}

///|
fn alignment_note(
  findings : Findings,
  page : Int32,
  code : String,
  text : String,
  baseline : GlyphUse?,
  candidate : GlyphUse?,
) -> Unit {
  findings.block({
    ..note(code, "both", text, page~),
    baseline: baseline.map(g => g.site()),
    candidate: candidate.map(g => g.site()),
  })
}

///|
fn assign_unique_positions(
  baseline : Array[GlyphUse],
  candidate : Array[GlyphUse],
  positions : PositionIndex,
  page : Int32,
  findings : Findings,
) -> PageAlignment? {
  let claimed = FixedArray::make(candidate.length(), false)
  let matching : Array[Int32] = Array(capacity=baseline.length())
  let mut reordered = false
  for i, old in baseline {
    let mut only = -1
    let repeated = positions.first_near(old.pose, j => {
      if !compatible_use(old, candidate[j]) {
        false
      } else if only >= 0 {
        true
      } else {
        only = j
        false
      }
    })
    if repeated is Some(j) {
      alignment_note(
        findings,
        page,
        "ambiguous_alignment",
        "more than one compatible glyph at the baseline origin",
        Some(old),
        Some(candidate[j]),
      )
      return None
    }
    if only < 0 {
      alignment_note(
        findings,
        page,
        "unaligned_glyph",
        "no compatible glyph at the baseline origin",
        Some(old),
        None,
      )
      return None
    }
    if claimed[only] {
      alignment_note(
        findings,
        page,
        "ambiguous_alignment",
        "two baseline glyphs would match the same candidate occurrence",
        Some(old),
        Some(candidate[only]),
      )
      return None
    }
    claimed[only] = true
    reordered = reordered || only != i
    matching.push(only)
  }
  Some(if reordered { UniquePositions(matching) } else { DrawingOrder })
}

///|
fn align_page(
  baseline : PageScan,
  candidate : PageScan,
  page : Int32,
  findings : Findings,
  allow_reorder : Bool,
) -> PageAlignment? {
  if baseline.blocked || candidate.blocked {
    return None
  }
  if baseline.page_unit != candidate.page_unit {
    findings.block(
      note("unaligned_page", "both", "page UserUnit differs", page~),
    )
    return None
  }
  if !same_bounds(baseline.bounds, candidate.bounds) {
    findings.block(note("unaligned_page", "both", "page boxes differ", page~))
    return None
  }
  let old = baseline.glyphs
  let new_ = candidate.glyphs
  if old.length() != new_.length() {
    findings.block(
      note(
        "unaligned_page",
        "both",
        "drawn glyph counts differ (\{old.length()} vs \{new_.length()})",
        page~,
      ),
    )
    return None
  }
  let mut exact = true
  for i, previous in old {
    let current = new_[i]
    if !compatible_use(previous, current) {
      if !allow_reorder {
        alignment_note(
          findings,
          page,
          "unaligned_glyph",
          "font family, glyph outline, drawing order or position differs at occurrence \{i + 1}",
          Some(previous),
          Some(current),
        )
        return None
      }
      exact = false
      break
    }
    exact = exact && exact_pose(previous.pose, current.pose)
  }
  // With identical poses and shapes in order, overlap on either side is
  // equivalent, so build one index. Offset or reorder cases check both
  // files and require an unambiguous one-to-one association.
  match index_positions(old) {
    Err(glyph) => {
      alignment_note(
        findings,
        page,
        "ambiguous_alignment",
        "overlapping indistinguishable baseline glyphs or crowded origins",
        Some(glyph),
        None,
      )
      return None
    }
    Ok(_) => ()
  }
  if exact {
    return Some(DrawingOrder)
  }
  match index_positions(new_) {
    Err(glyph) => {
      alignment_note(
        findings,
        page,
        "ambiguous_alignment",
        "overlapping indistinguishable candidate glyphs or crowded origins",
        None,
        Some(glyph),
      )
      None
    }
    Ok(positions) =>
      assign_unique_positions(old, new_, positions, page, findings)
  }
}
