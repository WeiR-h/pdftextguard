///|
priv struct DocumentScan {
  pages : Array[PageScan]
  diagnostics : Array[Diagnostic]
  mut total_glyphs : Int32
  mut page_count : Int32
  mut blocked : Bool
  mut syntax_error : Bool
}

///|
fn page_bounds(
  doc : Document,
  page : @pdfpage.PdfPage,
  raw : @syntax.PdfObject,
) -> Array[Double] raise GuardError {
  if !(page.rotate is Rotate0) {
    raise Unsupported("page rotation")
  }
  if field(raw, b"UserUnit") is Some(value) {
    if doc.number(value) != 1.0 {
      raise Unsupported("nonstandard page user units")
    }
  }
  if field(raw, b"Annots") is Some(value) {
    let resolved = doc.resolve(value)
    if !(resolved is PdfNull) && !doc.array(resolved).is_empty() {
      raise Unsupported("page annotations or widgets")
    }
  }
  let media = doc.array(page.mediabox)
  let crop = match field(page.rest, b"CropBox") {
    Some(value) => doc.array(value)
    None => media
  }
  if media.length() != 4 || crop.length() != 4 {
    raise Invalid("invalid page box")
  }
  let bounds : Array[Double] = []
  for values in [media, crop] {
    let coords = values.map(value => doc.number(value))
    if coords[0] >= coords[2] || coords[1] >= coords[3] {
      raise Invalid("inverted or empty PDF page box")
    }
    bounds.append(coords)
  }
  bounds
}

///|
fn scan_page(
  doc : Document,
  side : String,
  number : Int32,
  ref_number : Int32,
  page : @pdfpage.PdfPage,
  glyph_budget : Int32,
) -> PageScan raise GuardError {
  let raw = doc.resolve(@syntax.PdfObject::PdfIndirect(ref_number))
  let bounds = page_bounds(doc, page, raw)
  let output : PageScan = {
    bounds,
    glyphs: [],
    diagnostics: [],
    blocked: false,
    syntax_error: false,
  }
  let scope : ResourceScope = { resources: page.resources, fonts: Map([]), }
  let scan : ContentScan = {
    doc,
    side,
    page: number,
    scope,
    page_scope: scope,
    output,
    stack: [],
    graphics: {
      ctm: identity,
      font: None,
      size: 0,
      spacing: 0,
      scale: 1,
      leading: 0,
      rise: 0,
      mode: 0,
    },
    in_text: false,
    text: identity,
    line: identity,
    marked_depth: 0,
    stream: None,
    stream_index: 0,
    decoded_offset: None,
    glyph_budget,
    form_path: [],
    nested_error: Ref(None),
  }
  try {
    let streams = doc.contents(raw)
    if streams.length() > 256 {
      raise Unsupported("too many page content streams")
    }
    for i, stream in streams {
      scan.read_stream(stream, i)
    }
    scan.require_closed()
  } catch {
    error => {
      output.blocked = true
      let d = note(guard_code(error), side, guard_message(error), page=number)
      output.diagnostics.push({
        ..d,
        stream: Some(scan.nested_error.val.unwrap_or(scan.stream_site())),
      })
    }
  }
  output
}

///|
fn scan_document(bytes : Bytes, side : String) -> DocumentScan {
  let output : DocumentScan = {
    pages: [],
    diagnostics: [],
    total_glyphs: 0,
    page_count: 0,
    blocked: false,
    syntax_error: false,
  }
  try {
    let doc = read_document(bytes)
    let pages = doc.pdf.pages_of_pagetree() catch {
      _ => raise Invalid("cannot read the PDF page tree")
    }
    let page_numbers = doc.pdf.page_reference_numbers() catch {
      _ => raise Invalid("cannot resolve PDF page objects")
    }
    output.page_count = pages.length()
    if pages.length() > 128 {
      raise Unsupported("PDF exceeds the 128-page limit")
    }
    if pages.is_empty() || pages.length() != page_numbers.length() {
      raise Invalid("empty or inconsistent PDF page tree")
    }
    for i, page in pages {
      let page_scan = scan_page(
        doc,
        side,
        i + 1,
        page_numbers[i],
        page,
        100_000 - output.total_glyphs,
      ) catch {
        error =>
          {
            bounds: [],
            glyphs: [],
            blocked: true,
            syntax_error: false,
            diagnostics: [
              note(guard_code(error), side, guard_message(error), page=i + 1),
            ],
          }
      }
      output.pages.push(page_scan)
      output.diagnostics.append(page_scan.diagnostics)
      output.total_glyphs += page_scan.glyphs.length()
      output.blocked = output.blocked || page_scan.blocked
      output.syntax_error = output.syntax_error || page_scan.syntax_error
    }
  } catch {
    error => {
      output.blocked = true
      output.diagnostics.push(
        note(guard_code(error), side, guard_message(error)),
      )
    }
  }
  output
}
