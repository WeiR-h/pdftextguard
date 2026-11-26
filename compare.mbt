///|
priv struct PageFindings {
  codes : Array[String]
  mut blocked : Bool
}

///|
priv struct Findings {
  entries : Array[Diagnostic]
  pages : Array[PageFindings]
  mut omitted : Int32
  mut blocked : Bool
  mut aligned : Int32
  mut compared : Int32
  mut changed : Int32
  mut position_aligned_pages : Int32
}

///|
fn Findings::record_page_code(
  self : Findings,
  page : Int32?,
  code : String,
) -> Unit {
  if page is Some(number) && number > 0 && number <= self.pages.length() {
    let codes = self.pages[number - 1].codes
    if !codes.contains(code) {
      codes.push(code)
    }
  }
}

///|
fn Findings::add(self : Findings, entry : Diagnostic) -> Unit {
  self.record_page_code(entry.page, entry.code)
  if self.entries.length() < 80 {
    self.entries.push(entry)
  } else {
    self.omitted += 1
  }
}

///|
fn Findings::block(self : Findings, entry : Diagnostic) -> Unit {
  self.blocked = true
  if entry.page is Some(page) && page > 0 && page <= self.pages.length() {
    self.pages[page - 1].blocked = true
  }
  self.add(entry)
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
fn compare_page(
  baseline : PageScan,
  candidate : PageScan,
  page : Int32,
  findings : Findings,
  allow_reorder : Bool,
) -> Unit {
  let alignment = match
    align_page(baseline, candidate, page, findings, allow_reorder) {
    None => return
    Some(alignment) => alignment
  }
  if alignment is UniquePositions(_) {
    findings.position_aligned_pages += 1
  }
  findings.aligned += baseline.glyphs.length()
  for i, old in baseline.glyphs {
    let j = match alignment {
      DrawingOrder => i
      UniquePositions(indices) => indices[i]
    }
    let current = candidate.glyphs[j]
    if old.trace.cmap_valid && current.trace.cmap_valid {
      match (old.glyph.mapping, current.glyph.mapping) {
        (Some(previous), Some(current_mapping)) if previous.scalars ==
          current_mapping.scalars => findings.compared += 1
        (Some(_), _) => {
          findings.compared += 1
          findings.changed += 1
          let missing = current.glyph.mapping is None
          let code = if missing { "mapping_missing" } else { "mapping_changed" }
          if findings.entries.length() >= 80 {
            findings.record_page_code(Some(page), code)
            findings.omitted += 1
            continue
          }
          let item = if missing {
            note(
              code,
              "candidate",
              "a used code lost its explicit ToUnicode mapping",
              page~,
            )
          } else {
            note(
              code,
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
  check_impl(baseline, candidate, false)
}

///|
/// Compare explicit mappings by unique position if the drawing order changed.
/// This mode does not evaluate extraction or reading order.
pub fn check_by_position(baseline : Bytes, candidate : Bytes) -> Report {
  check_impl(baseline, candidate, true)
}

///|
fn check_impl(
  baseline : Bytes,
  candidate : Bytes,
  allow_reorder : Bool,
) -> Report {
  let old = scan_document(baseline, "baseline")
  let current = scan_document(candidate, "candidate")
  let pages : Array[PageFindings] = []
  if old.pages.length() == current.pages.length() {
    for index, page in old.pages {
      pages.push({
        codes: [],
        blocked: page.blocked || page.syntax_error || current.pages[index].blocked,
      })
    }
  }
  let findings : Findings = {
    entries: [],
    pages,
    omitted: 0,
    blocked: old.blocked || current.blocked || old.syntax_error,
    aligned: 0,
    compared: 0,
    changed: 0,
    position_aligned_pages: 0,
  }
  for issue in old.diagnostics {
    findings.add(issue)
  }
  for issue in current.diagnostics {
    findings.add(issue)
  }
  check_baseline_mappings(old, findings)
  let page_results : Array[PageResult] = []
  if old.pages.length() != current.pages.length() {
    findings.block(
      note(
        "page_count_changed", "both", "the exports do not have the same page count",
      ),
    )
  } else {
    for i, page in old.pages {
      let next = current.pages[i]
      let aligned_before = findings.aligned
      let compared_before = findings.compared
      let changed_before = findings.changed
      compare_page(page, next, i + 1, findings, allow_reorder)
      let aligned = findings.aligned - aligned_before
      let changed = findings.changed - changed_before
      let outcome = if pages[i].blocked {
        "inconclusive"
      } else if changed > 0 || next.syntax_error {
        "regression"
      } else if aligned == 0 {
        "no_text"
      } else {
        "pass"
      }
      page_results.push({
        page: i + 1,
        outcome,
        aligned_glyphs: aligned,
        compared_glyphs: findings.compared - compared_before,
        mismatched_occurrences: changed,
        diagnostic_codes: pages[i].codes,
      })
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
    position_aligned_pages: findings.position_aligned_pages,
    compared_glyphs: findings.compared,
    mismatched_occurrences: findings.changed,
    page_results,
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
    position_aligned_pages: 0,
    compared_glyphs: 0,
    mismatched_occurrences: 0,
    page_results: [],
    diagnostics_omitted: 0,
    diagnostics: [note("input_error", side, message)],
  }
}
