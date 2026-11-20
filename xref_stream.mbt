///|
fn structural_integer(
  object : @syntax.PdfObject,
  key : Bytes,
) -> Int32 raise GuardError {
  match field(object, key) {
    Some(PdfInteger(value)) if value >= 0 => value
    _ => raise Invalid("missing or invalid structural PDF integer")
  }
}

///|
fn read_object_slice(
  view : BytesView,
) -> @syntax.PdfParsedIndirectObject raise GuardError {
  let cursor = @pdfcore.byte_cursor_of_view(view)
  let tokens = @syntax.pdf_cursor_lex_tokens(cursor) catch {
    _ => raise Invalid("cannot read indexed PDF object")
  }
  let (prefix, _, complete) = @syntax.pdf_parse_indirect_object_segment_at(
    tokens, 0,
  ) catch {
    _ => raise Invalid("malformed indexed PDF object")
  }
  if complete {
    return prefix
  }
  let start = cursor.position()
  let first = if start + 8 <= view.length() &&
    view[start:start + 8] == b"stream\r\n" {
    start + 8
  } else if start + 7 <= view.length() && view[start:start + 7] == b"stream\n" {
    start + 7
  } else {
    raise Invalid("unterminated indexed PDF object")
  }
  let length = structural_integer(prefix.object, b"Length")
  if length > view.length() - first {
    raise Invalid("indexed PDF stream exceeds its object bounds")
  }
  let tail = @pdfcore.byte_cursor_of_view(view[first + length:])
  @syntax.pdf_cursor_drop_whitespace(tail)
  let markers = tail.remaining_view()
  if markers.length() < 9 || markers[0:9] != b"endstream" {
    raise Invalid("indexed PDF stream length misses endstream")
  }
  let suffix = @pdfcore.byte_cursor_of_view(markers[9:])
  @syntax.pdf_cursor_drop_whitespace(suffix)
  let ending = suffix.remaining_view()
  if ending.length() < 6 || ending[0:6] != b"endobj" {
    raise Invalid("indexed PDF stream is missing endobj")
  }
  {
    ..prefix,
    object: @syntax.pdf_stream(
      prefix.object,
      @syntax.StreamGot(view[first:first + length].to_owned()),
    ),
  }
}

///|
fn structural_bytes(
  object : @syntax.PdfObject,
  limit : Int32,
) -> Bytes raise GuardError {
  if !(object is PdfStreamObject(_)) {
    raise Invalid("expected cross-reference or object stream")
  }
  if field(object, b"DecodeParms") is Some(params) && !(params is PdfNull) {
    raise Unsupported("structural PDF stream parameters")
  }
  let bytes = object.stream_bytes() catch {
    _ => raise Invalid("cannot read structural PDF stream")
  }
  match field(object, b"Filter") {
    None | Some(PdfNull) if bytes.length() <= limit => bytes
    None | Some(PdfNull) =>
      raise Unsupported("structural PDF stream exceeds its size limit")
    Some(PdfNameObject(name)) if pdf_name_payload(name) == b"FlateDecode" =>
      inflate_bounded(bytes, limit)
    _ => raise Unsupported("structural PDF stream filter")
  }
}

///|
fn xref_entries(
  object : @syntax.PdfObject,
) -> (Array[@pdfreader.PdfClassicXRefEntry], Int32) raise GuardError {
  let size = structural_integer(object, b"Size")
  if size > 50_000 {
    raise Unsupported("PDF exceeds the object count limit")
  }
  let (pairs, widths) = (
    @pdfreader.pdf_xref_stream_index_pairs(object),
    @pdfreader.pdf_xref_stream_widths(object),
  ) catch {
    _ => raise Invalid("malformed cross-reference stream metadata")
  }
  let mut previous_end = 0
  let mut count = 0
  for pair in pairs {
    if pair.0 < previous_end ||
      pair.0 > size ||
      pair.1 < 0 ||
      pair.1 > size - pair.0 {
      raise Invalid("invalid cross-reference stream index")
    }
    previous_end = pair.0 + pair.1
    count += pair.1
  }
  let (kind, offset, generation) = widths
  if kind < 0 ||
    kind > 1 ||
    offset < 1 ||
    offset > 4 ||
    generation < 0 ||
    generation > 2 {
    raise Unsupported("cross-reference stream field width")
  }
  let expected = count * (kind + offset + generation)
  let data = structural_bytes(object, expected)
  if data.length() != expected {
    raise Invalid("cross-reference stream length differs from its index")
  }
  if kind == 1 {
    let row_width = kind + offset + generation
    for i in 0..<count {
      if data[i * row_width].to_int() > 2 {
        raise Unsupported("unknown cross-reference stream entry type")
      }
    }
  }
  let entries = @pdfreader.pdf_xref_stream_entries(data[:], widths, pairs[:]) catch {
    _ => raise Invalid("cannot decode cross-reference stream entries")
  }
  (entries, expected)
}

///|
fn read_stream_document(
  data : Bytes,
  xref : Int32,
) -> (@pdf.PdfDocument, Int32) raise GuardError {
  let section = read_object_slice(data[xref:])
  if !@pdfreader.pdf_reader_object_is_xref_stream(section.object) {
    raise Invalid("startxref does not name a cross-reference stream")
  }
  check_trailer(section.object)
  let root = match field(section.object, b"Root") {
    Some(PdfIndirect(number)) if number > 0 => number
    _ => raise Invalid("cross-reference stream is missing an indirect catalog")
  }
  let (entries, xref_bytes) = xref_entries(section.object)
  let plain : Array[@pdfreader.PdfClassicXRefEntry] = []
  for entry in entries {
    if entry.in_use && entry.object_number == 0 {
      raise Invalid("cross-reference stream marks the free object as in use")
    }
    if entry.in_use && entry.object_stream is None {
      if entry.offset == xref &&
        entry.object_number == section.number &&
        entry.generation == section.generation {
        continue
      }
      if entry.offset <= 0 || entry.offset >= xref {
        raise Invalid("cross-reference stream points outside the object area")
      }
      plain.push(entry)
    }
  }
  plain.sort_by(fn(left, right) { left.offset.compare(right.offset) })
  let objects : Array[@syntax.PdfParsedIndirectObject] = []
  let streams : Map[Int32, @syntax.PdfObject] = Map([])
  for i, entry in plain {
    let end = if i + 1 < plain.length() { plain[i + 1].offset } else { xref }
    if end <= entry.offset {
      raise Invalid("cross-reference stream repeats an object offset")
    }
    let parsed = read_object_slice(data[entry.offset:end])
    if parsed.number != entry.object_number ||
      parsed.generation != entry.generation {
      raise Invalid("cross-reference stream object identity mismatch")
    }
    if parsed.object is PdfStreamObject(_) {
      streams.set(parsed.number, parsed.object)
    }
    objects.push(parsed)
  }
  let mut decoded = xref_bytes
  for pair in @pdfreader.pdf_reader_object_stream_groups(entries[:]) {
    let (number, members) = pair
    let stream = match streams.get(number) {
      Some(value) => value
      None => raise Invalid("missing object stream")
    }
    if !(field(stream, b"Type") is Some(PdfNameObject(name)) &&
      pdf_name_payload(name) == b"ObjStm") {
      raise Invalid("compressed reference does not name an object stream")
    }
    let count = structural_integer(stream, b"N")
    let first = structural_integer(stream, b"First")
    if count != members.length() {
      raise Unsupported(
        "object stream members differ from the cross-reference stream",
      )
    }
    let bytes = structural_bytes(
      stream,
      (64 * 1024 * 1024 - decoded).min(8 * 1024 * 1024),
    )
    decoded += bytes.length()
    let indexes = @pdfreader.pdf_object_stream_number_offsets(
      bytes[:],
      first,
      count,
    ) catch {
      _ => raise Invalid("malformed object stream header")
    }
    let mut previous_offset = -1
    for index in indexes {
      if index.1 <= previous_offset {
        raise Invalid("object stream member offsets must strictly increase")
      }
      previous_offset = index.1
    }
    let ends = @pdfreader.pdf_object_stream_end_offsets(
      indexes[:],
      bytes.length(),
      first,
    )
    for (entry, pointer) in members {
      let index = pointer.index
      if index < 0 || index >= count || indexes[index].0 != entry.object_number {
        raise Invalid("object stream member identity mismatch")
      }
      let start = indexes[index].1
      let end = ends[index]
      if start >= end || end > bytes.length() - first {
        raise Invalid("object stream member outside its bounds")
      }
      let object = @syntax.pdf_parse_object_from_view(
        bytes[first + start:first + end],
      ) catch {
        _ => raise Invalid("malformed object stream member")
      }
      objects.push({ number: entry.object_number, generation: 0, object, })
    }
  }
  if !objects.any(item => item.number == root) {
    raise Invalid("cross-reference stream catalog is missing")
  }
  let version = @pdfreader.pdf_read_header_from_bytes(data) catch {
    _ => raise Invalid("invalid PDF header")
  }
  let document = @pdf.pdf_document_of_parsed_indirect_objects(
    objects[:],
    version~,
  )
  document.set_root(root)
  if section.object is PdfStreamObject(stream) {
    document.set_trailer_dict(stream.dictionary)
  }
  (document, decoded)
}
