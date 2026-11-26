///|
extern "js" fn file_sha256(bytes : Bytes) -> String =
  #| bytes => process.getBuiltinModule("crypto").createHash("sha256").update(bytes).digest("hex")

///|
extern "js" fn markdown_text(text : String) -> String =
  #| text => text.replace(/[\p{P}\p{Cc}\p{Cf}<>=+|~$\n\r]/gu, char => "&#" + char.codePointAt(0) + ";")

///|
extern "js" fn write_markdown(path : String, text : String) -> String =
  #| (path, text) => {
  #|   const fs = process.getBuiltinModule("fs");
  #|   let fd;
  #|   try {
  #|     fd = fs.openSync(path, "wx");
  #|     try {
  #|       fs.writeFileSync(fd, text, "utf8");
  #|     } finally {
  #|       fs.closeSync(fd);
  #|     }
  #|     return "";
  #|   } catch (err) {
  #|     if (fd !== undefined) {
  #|       try { fs.unlinkSync(path); } catch {}
  #|     }
  #|     return "cannot write Markdown report: " + (err.code || err.name);
  #|   }
  #| }

///|
fn input_digest(file : FileRead?) -> String {
  match file {
    Some(file) => file_sha256(file.bytes())
    None => "unavailable"
  }
}

///|
fn span_label(span : @guard.CMapSpan) -> String {
  "\{markdown_text(span.operator)} bytes [\{span.decoded_offset}, \{span.decoded_end})"
}

///|
fn markdown_site(out : StringBuilder, label : String, site : @guard.UseSite) -> Unit {
  let unicode = match site.unicode {
    Some(values) => @json.to_json(values).stringify()
    None => "unmapped"
  }
  let rule = match site.rule {
    Some(span) => span_label(span)
    None => "no explicit rule"
  }
  out.write_string(
    "  - \{label}, page \{site.page}, font `\{ref_label(site.font_object)}`, ToUnicode `\{ref_label(site.cmap_object)}`, \{rule}, Unicode `\{unicode}`\n",
  )
}

///|
fn markdown_report(
  report : @guard.Report,
  baseline : FileRead?,
  candidate : FileRead?,
) -> String {
  let out = StringBuilder()
  out.write_string("# PDFTextGuard v\{report.tool_version}\n\n")
  out.write_string(
    "Result **\{report.outcome}** (exit \{report.exit_code}). Coverage **\{report.coverage}**.\n\n",
  )
  out.write_string(
    "| Input | Pages scanned | SHA-256 |\n| --- | ---: | --- |\n| Baseline | \{report.baseline_pages} | `\{input_digest(baseline)}` |\n| Candidate | \{report.candidate_pages} | `\{input_digest(candidate)}` |\n\n",
  )
  out.write_string(
    "Aligned \{report.aligned_glyphs} glyph occurrences, compared \{report.compared_glyphs}, found \{report.mismatched_occurrences} mapping changes.\n",
  )
  if !report.page_results.is_empty() {
    out.write_string(
      "\n## Page results\n\n| Page | Outcome | Aligned | Compared | Changes | Reason codes |\n| ---: | --- | ---: | ---: | ---: | --- |\n",
    )
    for page in report.page_results {
      let reasons = page.diagnostic_codes.join(", ")
      out.write_string(
        "| \{page.page} | \{page.outcome} | \{page.aligned_glyphs} | \{page.compared_glyphs} | \{page.mismatched_occurrences} | \{markdown_text(reasons)} |\n",
      )
    }
  }
  if !report.diagnostics.is_empty() {
    out.write_string("\n## Diagnostics\n\nDecoded CMap byte ranges use inclusive starts and exclusive ends.\n\n")
  }
  for item in report.diagnostics {
    let page = match item.page {
      Some(page) => ", page \{page}"
      None => ""
    }
    out.write_string(
      "- `\{item.code}` (\{item.side}\{page}). \{markdown_text(item.message)}\n",
    )
    if item.cmap is Some(detail) {
      out.write_string(
        "  - Font `\{ref_label(detail.font_object)}`, ToUnicode `\{ref_label(detail.cmap_object)}`, \{span_label(detail.span)}",
      )
      if (detail.declared, detail.observed) is (Some(declared), Some(observed)) {
        out.write_string(", declared \{declared}, observed \{observed}")
      }
      out.write_string("\n")
    }
    if item.baseline is Some(site) {
      markdown_site(out, "Baseline", site)
    }
    if item.candidate is Some(site) {
      markdown_site(out, "Candidate", site)
    }
  }
  if report.diagnostics_omitted > 0 {
    out.write_string("\n\{report.diagnostics_omitted} additional diagnostics omitted.\n")
  }
  out.to_string()
}

///|
fn finish(
  report : @guard.Report,
  json : Bool,
  markdown : String?,
  baseline? : FileRead,
  candidate? : FileRead,
) -> Unit {
  if markdown is Some(path) {
    let error = write_markdown(path, markdown_report(report, baseline, candidate))
    if !error.is_empty() {
      emit(@guard.input_error("report", error), json)
      return
    }
  }
  emit(report, json)
}
