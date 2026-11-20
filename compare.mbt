///|
priv struct Findings {
  entries : Array[Diagnostic]
  mut omitted : Int32
  mut blocked : Bool
  mut aligned : Int32
  mut compared : Int32
  mut changed : Int32
}

///|
fn Findings::add(self : Findings, entry : Diagnostic) -> Unit {
  if self.entries.length() < 80 {
    self.entries.push(entry)
  } else {
    self.omitted += 1
  }
}

///|
fn Findings::block(self : Findings, entry : Diagnostic) -> Unit {
  self.blocked = true
  self.add(entry)
}

///|
fn find_overlap(uses : Array[GlyphUse]) -> GlyphUse? {
  // Check neighboring buckets as compared origins may differ by 0.01 pt.
  let seen : Map[(Int32, Int32), Array[GlyphUse]] = Map([])
  for use_ in uses {
    let x = (use_.pose.x * 50.0).to_int()
    let y = (use_.pose.y * 50.0).to_int()
    for dx in -1..<=1 {
      for dy in -1..<=1 {
        if seen.get((x + dx, y + dy)) is Some(neighbors) {
          if neighbors.any(other => {
              other.same_shape(use_) && same_pose(other.pose, use_.pose)
            }) {
            return Some(use_)
          }
        }
      }
    }
    match seen.get((x, y)) {
      None => seen.set((x, y), [use_])
      Some(items) => {
        if items.length() >= 64 {
          return Some(use_)
        }
        items.push(use_)
      }
    }
  }
  None
}

///|
fn same_bounds(a : Array[Double], b : Array[Double]) -> Bool {
  if a.length() != b.length() {
    return false
  }
  for i, extent in a {
    if !near(extent, b[i]) {
      return false
    }
  }
  true
}

///|
fn align_page(
  baseline : PageScan,
  candidate : PageScan,
  page : Int32,
  findings : Findings,
) -> Bool {
  if baseline.blocked || candidate.blocked {
    return false
  }
  if !same_bounds(baseline.bounds, candidate.bounds) {
    findings.block(note("unaligned_page", "both", "page boxes differ", page~))
    return false
  }
  if baseline.glyphs.length() != candidate.glyphs.length() {
    findings.block(
      note(
        "unaligned_page",
        "both",
        "drawn glyph counts differ (\{baseline.glyphs.length()} vs \{candidate.glyphs.length()})",
        page~,
      ),
    )
    return false
  }
  for i, previous in baseline.glyphs {
    let current = candidate.glyphs[i]
    if !previous.same_shape(current) ||
      !same_pose(previous.pose, current.pose) ||
      !near(previous.advance, current.advance) {
      let item = note(
        "unaligned_glyph",
        "both",
        "font family, glyph outline, drawing order or position differs at occurrence \{i + 1}",
        page~,
      )
      findings.block({
        ..item,
        baseline: Some(previous.site()),
        candidate: Some(current.site()),
      })
      return false
    }
  }
  let overlap_baseline = find_overlap(baseline.glyphs)
  let overlap_candidate = find_overlap(candidate.glyphs)
  if overlap_baseline is Some(_) || overlap_candidate is Some(_) {
    let item = note(
      "ambiguous_alignment",
      "both",
      "overlapping indistinguishable glyph occurrences",
      page~,
    )
    findings.block({
      ..item,
      baseline: overlap_baseline.map(g => g.site()),
      candidate: overlap_candidate.map(g => g.site()),
    })
    return false
  }
  true
}

///|
fn compare_page(
  baseline : PageScan,
  candidate : PageScan,
  page : Int32,
  findings : Findings,
) -> Unit {
  if !align_page(baseline, candidate, page, findings) {
    return
  }
  findings.aligned += baseline.glyphs.length()
  for i, old in baseline.glyphs {
    let current = candidate.glyphs[i]
    if old.trace.cmap_valid && current.trace.cmap_valid {
      match (old.glyph.mapping, current.glyph.mapping) {
        (Some(previous), Some(current_mapping)) if previous.scalars ==
          current_mapping.scalars => findings.compared += 1
        (Some(_), _) => {
          findings.compared += 1
          findings.changed += 1
          if findings.entries.length() >= 80 {
            findings.omitted += 1
            continue
          }
          let item = if current.glyph.mapping is None {
            note(
              "mapping_missing",
              "candidate",
              "a used code lost its explicit ToUnicode mapping",
              page~,
            )
          } else {
            note(
              "mapping_changed",
              "both",
              "the same drawn glyph now maps to different Unicode scalars",
              page~,
            )
          }
          findings.add({
            ..item,
            baseline: Some(old.site()),
            candidate: Some(current.site()),
          })
        }
        (None, _) => ()
      }
    }
  }
}

///|
fn check_baseline_mappings(
  baseline : DocumentScan,
  findings : Findings,
) -> Unit {
  for page in baseline.pages {
    for glyph in page.glyphs {
      if glyph.trace.cmap_valid && glyph.glyph.mapping is None {
        let site = glyph.site()
        let item = note(
          "baseline_unmapped",
          "baseline",
          "baseline has a used code without explicit ToUnicode",
          page=site.page,
        )
        findings.block({ ..item, baseline: Some(site), })
        break
      }
    }
  }
}

///|
/// Compare the text layer of two exports of the same source document.
/// Exit code 2 indicates unverifiable coverage, including an invalid baseline.
pub fn check(baseline : Bytes, candidate : Bytes) -> Report {
  let old = scan_document(baseline, "baseline")
  let current = scan_document(candidate, "candidate")
  let findings : Findings = {
    entries: [],
    omitted: 0,
    blocked: old.blocked || current.blocked || old.syntax_error,
    aligned: 0,
    compared: 0,
    changed: 0,
  }
  for issue in old.diagnostics {
    findings.add(issue)
  }
  for issue in current.diagnostics {
    findings.add(issue)
  }
  check_baseline_mappings(old, findings)
  if old.pages.length() != current.pages.length() {
    findings.block(
      note(
        "page_count_changed", "both", "the exports do not have the same page count",
      ),
    )
  } else {
    for i, page in old.pages {
      compare_page(page, current.pages[i], i + 1, findings)
    }
  }
  if findings.aligned == 0 && !findings.blocked {
    findings.block(
      note(
        "no_supported_text", "both", "no comparable supported glyphs were drawn",
      ),
    )
  }
  let (outcome, exit_code, coverage) = if findings.blocked {
    ("inconclusive", 2, "incomplete")
  } else if findings.changed > 0 || current.syntax_error {
    ("regression", 1, "complete")
  } else {
    ("pass", 0, "complete")
  }
  {
    schema_version: 1,
    tool_version: version,
    outcome,
    exit_code,
    coverage,
    baseline_pages: old.page_count,
    candidate_pages: current.page_count,
    baseline_glyphs: old.total_glyphs,
    candidate_glyphs: current.total_glyphs,
    aligned_glyphs: findings.aligned,
    compared_glyphs: findings.compared,
    mismatched_occurrences: findings.changed,
    diagnostics_omitted: findings.omitted,
    diagnostics: findings.entries,
  }
}

///|
pub fn input_error(side : String, message : String) -> Report {
  {
    schema_version: 1,
    tool_version: version,
    outcome: "inconclusive",
    exit_code: 2,
    coverage: "incomplete",
    baseline_pages: 0,
    candidate_pages: 0,
    baseline_glyphs: 0,
    candidate_glyphs: 0,
    aligned_glyphs: 0,
    compared_glyphs: 0,
    mismatched_occurrences: 0,
    diagnostics_omitted: 0,
    diagnostics: [note("input_error", side, message)],
  }
}
