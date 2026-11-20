///|
let max_file_bytes : Int32 = 32 * 1024 * 1024

///|
priv struct Document {
  pdf : @pdf.PdfDocument
  generations : Map[Int32, Int32]
  mut decoded_bytes : Int32
  outline_budget : Ref[Int32]
  fonts : Map[Int32, FontData]
  decoded_streams : Map[Int32, Bytes]
  mut content_bytes : Int32
  mut form_calls : Int32
}

///|
fn read_document(data : Bytes) -> Document raise GuardError {
  if data.length() > max_file_bytes {
    raise Unsupported("PDF exceeds the 32 MiB input limit")
  }
  let xref = @pdfreader.pdf_read_startxref_position(data) catch {
    _ => raise Invalid("missing or invalid startxref")
  }
  if xref < 0 || xref >= data.length() {
    raise Invalid("startxref outside the PDF")
  }
  let marker = data.get_view(start=xref, end=xref + 4)
  let (pdf, decoded_bytes) = if marker is Some(bytes) && bytes == b"xref" {
    (read_classic_document(data, xref), 0)
  } else {
    read_stream_document(data, xref)
  }
  if pdf.is_encrypted() {
    raise Unsupported("encrypted PDF")
  }
  if pdf.object_count() > 50_000 {
    raise Unsupported("PDF exceeds the object count limit")
  }
  let generations : Map[Int32, Int32] = Map([])
  for entry in pdf.parsed_object_entries() {
    generations.set(entry.0, entry.1)
  }
  {
    pdf,
    generations,
    decoded_bytes,
    outline_budget: Ref(16 * 1024 * 1024),
    fonts: Map([]),
    decoded_streams: Map([]),
    content_bytes: 0,
    form_calls: 0,
  }
}

///|
fn check_trailer(trailer : @syntax.PdfObject) -> Unit raise GuardError {
  if field(trailer, b"Prev") is Some(_) || field(trailer, b"XRefStm") is Some(_) {
    raise Unsupported("incremental PDF or hybrid cross-reference data")
  }
  if field(trailer, b"Encrypt") is Some(_) {
    raise Unsupported("encrypted PDF")
  }
}

///|
fn read_classic_document(
  data : Bytes,
  xref : Int32,
) -> @pdf.PdfDocument raise GuardError {
  let cursor = @pdfcore.byte_cursor_of_view(data[xref:])
  let (entries, trailer) = try {
    let entries = @pdfreader.pdf_cursor_read_classic_xref_entries(cursor)
    (entries, @pdfreader.pdf_cursor_read_trailer_dictionary(cursor))
  } catch {
    _ =>
      raise Invalid("cannot read the classic cross-reference table or trailer")
  }
  if entries.length() > 50_000 {
    raise Unsupported("PDF exceeds the object count limit")
  }
  check_trailer(trailer)
  @pdf.pdf_read_classic_document_from_bytes(data) catch {
    _ =>
      raise Invalid(
        "cannot read PDF objects or cross-reference data with pdflite",
      )
  }
}

///|
fn Document::reference(
  self : Document,
  value : @syntax.PdfObject,
) -> ObjectRef? {
  match value {
    PdfIndirect(number) =>
      self.generations.get(number).map(generation => { number, generation, })
    _ => None
  }
}

///|
fn Document::resolve(
  self : Document,
  value : @syntax.PdfObject,
) -> @syntax.PdfObject raise GuardError {
  match value {
    PdfIndirect(number) => {
      if !self.generations.contains(number) {
        raise Invalid("unresolved PDF object \{number}")
      }
      match self.pdf.lookup_object_or_null(number) {
        PdfIndirect(_) => raise Unsupported("indirect-to-indirect PDF object")
        resolved => resolved
      }
    }
    _ => value
  }
}

///|
fn field(
  value : @syntax.PdfObject,
  key : Bytes,
) -> @syntax.PdfObject? raise GuardError {
  let items = match value {
    PdfDictionary(items) => items
    PdfStreamObject(stream) => return field(stream.dictionary, key)
    _ => raise Invalid("expected PDF dictionary at /\{name_string(key)}")
  }
  let mut found = None
  for entry in items {
    if pdf_name_payload(entry.0) == key {
      if found is Some(_) {
        raise Invalid("duplicate /\{name_string(key)} in PDF dictionary")
      }
      found = Some(entry.1)
    }
  }
  found
}

///|
fn required_field(
  value : @syntax.PdfObject,
  key : Bytes,
) -> @syntax.PdfObject raise GuardError {
  match field(value, key) {
    Some(result) => result
    None => raise Invalid("missing /\{name_string(key)} in PDF dictionary")
  }
}

///|
fn Document::name(
  self : Document,
  item : @syntax.PdfObject,
) -> Bytes raise GuardError {
  match self.resolve(item) {
    PdfNameObject(n) => pdf_name_payload(n).to_owned()
    _ => raise Invalid("expected a PDF name")
  }
}

///|
fn Document::array(
  self : Document,
  item : @syntax.PdfObject,
) -> Array[@syntax.PdfObject] raise GuardError {
  match self.resolve(item) {
    PdfArray(entries) => entries
    _ => raise Invalid("expected a PDF array")
  }
}

///|
fn Document::int(
  self : Document,
  item : @syntax.PdfObject,
) -> Int32 raise GuardError {
  match self.resolve(item) {
    PdfInteger(n) => n
    _ => raise Invalid("expected a PDF integer")
  }
}

///|
fn Document::number(
  self : Document,
  item : @syntax.PdfObject,
) -> Double raise GuardError {
  let n = match self.resolve(item) {
    PdfInteger(n) => n.to_double()
    PdfReal(n) | PdfExactReal(n) => n
    _ => raise Invalid("expected a PDF number")
  }
  if !n.is_finite() || n.abs() > 1_000_000.0 {
    raise Unsupported("PDF number exceeds the supported coordinate range")
  }
  n
}

///|
fn inflate_bounded(bytes : Bytes, limit : Int32) -> Bytes raise GuardError {
  let data : BytesView = bytes[:]
  let decoder = @zlib.Decoder()
  let buffer = @buffer.Buffer()
  let chunk : FixedArray[Byte] = FixedArray::make(16384, b'\x00')
  let mut pos = 0
  while !decoder.is_finished() {
    ignore(
      decoder.step_into(data[pos:], chunk, end=true) catch {
        _ => raise Invalid("invalid FlateDecode stream")
      },
    )
    let produced = decoder.last_produced()
    let consumed = decoder.last_consumed()
    if produced > limit - buffer.length() {
      raise Unsupported("decoded stream exceeds its size limit")
    }
    for i in 0..<produced {
      buffer.write_byte(chunk[i])
    }
    pos += consumed
    if produced == 0 && consumed == 0 && !decoder.is_finished() {
      raise Invalid("truncated FlateDecode stream")
    }
  }
  if pos != data.length() {
    raise Invalid("trailing bytes after FlateDecode stream")
  }
  buffer.to_bytes()
}

///|
fn Document::decoded_stream(
  self : Document,
  raw : @syntax.PdfObject,
  limit : Int32,
) -> Bytes raise GuardError {
  if raw is PdfIndirect(number) &&
    self.decoded_streams.get(number) is Some(cached) {
    if cached.length() > limit {
      raise Unsupported("decoded stream exceeds its size limit")
    }
    return cached
  }
  let stream = self.resolve(raw)
  if !(stream is PdfStreamObject(_)) {
    raise Invalid("expected a PDF stream for text, font or CMap data")
  }
  let bytes = stream.stream_bytes() catch {
    _ => raise Invalid("cannot read PDF stream bytes")
  }
  let filter = match field(stream, b"Filter") {
    None => None
    Some(item) =>
      match self.resolve(item) {
        PdfNull => None
        PdfNameObject(name) => Some(pdf_name_payload(name).to_owned())
        PdfArray(items) if items.length() == 1 => Some(self.name(items[0]))
        _ => raise Unsupported("unsupported PDF stream filter chain")
      }
  }
  if field(stream, b"DecodeParms") is Some(parameters) {
    let params = match self.resolve(parameters) {
      PdfArray(items) if items.length() == 1 => self.resolve(items[0])
      other => other
    }
    if !(params is PdfNull) {
      if field(params, b"Predictor") is Some(predictor) {
        if self.int(predictor) != 1 {
          raise Unsupported("PDF stream predictors")
        }
      }
    }
  }
  let budget = limit.min(64 * 1024 * 1024 - self.decoded_bytes)
  let decoded = match filter {
    None => {
      if bytes.length() > budget {
        raise Unsupported("decoded stream exceeds its size limit")
      }
      bytes
    }
    Some(name) if name == b"FlateDecode" => inflate_bounded(bytes, budget)
    Some(name) =>
      raise Unsupported("unsupported PDF stream filter /\{name_string(name)}")
  }
  self.decoded_bytes += decoded.length()
  if raw is PdfIndirect(number) {
    self.decoded_streams.set(number, decoded)
  }
  decoded
}

///|
fn Document::contents(
  self : Document,
  page : @syntax.PdfObject,
) -> Array[@syntax.PdfObject] raise GuardError {
  match field(page, b"Contents") {
    None => []
    Some(item) =>
      match self.resolve(item) {
        PdfNull => []
        PdfArray(items) => items
        PdfStreamObject(_) => [item]
        _ => raise Invalid("invalid /Contents in page dictionary")
      }
  }
}
