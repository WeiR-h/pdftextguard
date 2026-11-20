///|
priv struct Font {
  resource : String
  family : Bytes
  object : ObjectRef?
  descendant : ObjectRef?
  file : ObjectRef?
  cmap_object : ObjectRef?
  cmap : CMap
  ttf : TrueType
  cid_to_gid : Bytes?
  default_width : Double
  widths : Map[Int32, Double]
  mut cmap_reported : Bool
}

///|
fn strip_subset_tag(name : Bytes) -> Bytes {
  if name.length() > 7 && name[6] == b'+' {
    for i in 0..<6 {
      if name[i] < b'A' || name[i] > b'Z' {
        return name
      }
    }
    return name[7:].to_owned()
  }
  name
}

///|
fn put_width(
  widths : Map[Int32, Double],
  cid : Int32,
  width : Double,
) -> Unit raise GuardError {
  if cid < 0 ||
    cid > 65535 ||
    width < 0 ||
    width > 100_000.0 ||
    widths.contains(cid) {
    raise Invalid("invalid or overlapping CID width")
  }
  widths.set(cid, width)
}

///|
fn Document::cid_widths(
  self : Document,
  descendant : @syntax.PdfObject,
) -> Map[Int32, Double] raise GuardError {
  let widths : Map[Int32, Double] = Map([])
  let items = match field(descendant, b"W") {
    Some(raw) => self.array(raw)
    None => return widths
  }
  let mut i = 0
  while i < items.length() {
    if i + 1 >= items.length() {
      raise Invalid("truncated /W array")
    }
    let first = self.int(items[i])
    if first < 0 || first > 65535 {
      raise Invalid("invalid starting CID in /W")
    }
    match self.resolve(items[i + 1]) {
      PdfArray(values) => {
        if values.is_empty() || values.length() > 65536 - first {
          raise Invalid("invalid CID width array length")
        }
        for j, width in values {
          put_width(widths, first + j, self.number(width))
        }
        i += 2
      }
      PdfInteger(last) => {
        if last < first || last > 65535 || i + 2 >= items.length() {
          raise Invalid("invalid CID width range")
        }
        let width = self.number(items[i + 2])
        for cid in first..<=last {
          put_width(widths, cid, width)
        }
        i += 3
      }
      _ => raise Invalid("invalid /W array")
    }
  }
  widths
}

///|
fn Document::font(
  self : Document,
  resources : @syntax.PdfObject,
  resource : Bytes,
) -> Font raise GuardError {
  let fonts = self.resolve(required_field(resources, b"Font"))
  let font_raw = required_field(fonts, resource)
  let font = self.resolve(font_raw)
  if self.name(required_field(font, b"Subtype")) != b"Type0" ||
    self.name(required_field(font, b"Encoding")) != b"Identity-H" {
    raise Unsupported(
      "/\{name_string(resource)} uses a font outside Type0 Identity-H",
    )
  }
  let base_font = self.name(required_field(font, b"BaseFont"))
  let descendants = self.array(required_field(font, b"DescendantFonts"))
  if descendants.length() != 1 {
    raise Unsupported("expected one descendant for /\{name_string(resource)}")
  }
  let descendant_raw = descendants[0]
  let descendant = self.resolve(descendant_raw)
  if self.name(required_field(descendant, b"Subtype")) != b"CIDFontType2" {
    raise Unsupported("/\{name_string(resource)} is not CIDFontType2")
  }
  let descriptor = self.resolve(required_field(descendant, b"FontDescriptor"))
  let ttf_raw = match field(descriptor, b"FontFile2") {
    Some(raw) => raw
    None => raise Unsupported("TrueType font is not embedded")
  }
  let ttf = parse_truetype(
    self.decoded_stream(ttf_raw, 8 * 1024 * 1024),
    self.outline_budget,
  )
  let cid_to_gid = match field(descendant, b"CIDToGIDMap") {
    None => None
    Some(raw) =>
      match self.resolve(raw) {
        PdfNameObject(name) if pdf_name_payload(name) == b"Identity" => None
        PdfStreamObject(_) => {
          let bytes = self.decoded_stream(raw, 131072)
          if bytes.length() % 2 != 0 {
            raise Invalid("odd-length CIDToGIDMap stream")
          }
          Some(bytes)
        }
        _ => raise Unsupported("unsupported CIDToGIDMap")
      }
  }
  let cmap_raw = field(font, b"ToUnicode")
  let (cmap_object, cmap) = match cmap_raw {
    None => (None, { entries: Map([]), issues: [], })
    Some(raw) => {
      let stream = self.resolve(raw)
      if field(stream, b"UseCMap") is Some(_) {
        raise Unsupported("ToUnicode /UseCMap inheritance")
      }
      (
        self.reference(raw),
        parse_cmap(self.decoded_stream(raw, 2 * 1024 * 1024)),
      )
    }
  }
  let default_width = match field(descendant, b"DW") {
    Some(raw) => self.number(raw)
    None => 1000.0
  }
  if default_width < 0 || default_width > 100_000.0 {
    raise Invalid("invalid /DW width")
  }
  {
    resource: "/" + name_string(resource),
    family: strip_subset_tag(base_font),
    object: self.reference(font_raw),
    descendant: self.reference(descendant_raw),
    file: self.reference(ttf_raw),
    cmap_object,
    cmap,
    ttf,
    cid_to_gid,
    default_width,
    widths: self.cid_widths(descendant),
    cmap_reported: false,
  }
}

///|
fn Font::gid(self : Font, cid : Int32) -> Int32 raise GuardError {
  let gid = match self.cid_to_gid {
    None => cid
    Some(table) => {
      if cid * 2 + 1 >= table.length() {
        raise Unsupported("CID has no entry in the CIDToGIDMap stream")
      }
      (table[cid * 2].to_int() << 8) | table[cid * 2 + 1].to_int()
    }
  }
  if gid == 0 {
    raise Unsupported("used CID resolves to the missing-glyph slot")
  }
  gid
}
