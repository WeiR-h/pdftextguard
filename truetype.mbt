///|
// Outline keys compare font units, metrics, contours and component transforms.
// They deliberately omit GIDs, table layout and TrueType hint programs.
priv struct TrueType {
  glyf : BytesView
  loca : BytesView
  hmtx : BytesView
  glyph_count : Int32
  long_loca : Bool
  metric_count : Int32
  units_per_em : Int32
  signatures : Map[Int32, String]
  outline_budget : Ref[Int32]
}

///|
fn sfnt_view(
  bytes : BytesView,
  start : Int32,
  len : Int32,
) -> BytesView raise GuardError {
  if start < 0 ||
    len < 0 ||
    start > bytes.length() ||
    len > bytes.length() - start {
    raise Invalid("truncated TrueType table or glyph")
  }
  bytes[start:start + len]
}

///|
fn u8(bytes : BytesView, at : Int32) -> Int32 raise GuardError {
  match bytes.get(at) {
    Some(b) => b.to_int()
    None => raise Invalid("truncated TrueType glyph")
  }
}

///|
fn u16(bytes : BytesView, at : Int32) -> Int32 raise GuardError {
  (u8(bytes, at) << 8) | u8(bytes, at + 1)
}

///|
fn i16(bytes : BytesView, at : Int32) -> Int32 raise GuardError {
  let value = u16(bytes, at)
  if value >= 32768 {
    value - 65536
  } else {
    value
  }
}

///|
fn i8(bytes : BytesView, at : Int32) -> Int32 raise GuardError {
  let value = u8(bytes, at)
  if value >= 128 {
    value - 256
  } else {
    value
  }
}

///|
fn u32_index(bytes : BytesView, at : Int32) -> Int32 raise GuardError {
  let hi = u16(bytes, at)
  let lo = u16(bytes, at + 2)
  if hi > 32767 {
    raise Invalid("TrueType offset exceeds the supported range")
  }
  (hi << 16) | lo
}

///|
fn parse_truetype(
  bytes : Bytes,
  outline_budget : Ref[Int32],
) -> TrueType raise GuardError {
  let input : BytesView = bytes[:]
  if input.length() < 12 ||
    (input[:4] != b"\x00\x01\x00\x00" && input[:4] != b"true") {
    raise Unsupported("FontFile2 is not a static TrueType sfnt")
  }
  let table_count = u16(input, 4)
  if table_count == 0 || table_count > 256 {
    raise Invalid("invalid TrueType table count")
  }
  let tables : Map[Bytes, BytesView] = Map([])
  for i in 0..<table_count {
    let record = 12 + 16 * i
    let name = sfnt_view(input, record, 4).to_owned()
    let offset = u32_index(input, record + 8)
    let length = u32_index(input, record + 12)
    if tables.contains(name) {
      raise Invalid("duplicate TrueType table")
    }
    tables.set(name, sfnt_view(input, offset, length))
  }
  if tables.contains(b"fvar") ||
    tables.contains(b"gvar") ||
    tables.contains(b"COLR") ||
    tables.contains(b"SVG ") ||
    tables.contains(b"CBDT") ||
    tables.contains(b"sbix") ||
    tables.contains(b"EBDT") ||
    tables.contains(b"CFF ") {
    raise Unsupported("variable, color or bitmap TrueType font")
  }
  let table = fn(tag : Bytes) -> BytesView raise GuardError {
    match tables.get(tag) {
      Some(view) => view
      None => raise Invalid("missing TrueType table \{name_string(tag)}")
    }
  }
  let head = table(b"head")
  let maxp = table(b"maxp")
  let hhea = table(b"hhea")
  let hmtx = table(b"hmtx")
  let glyf = table(b"glyf")
  let loca = table(b"loca")
  let format = i16(head, 50)
  let units_per_em = u16(head, 18)
  let glyph_count = u16(maxp, 4)
  let metric_count = u16(hhea, 34)
  if (format != 0 && format != 1) ||
    units_per_em < 16 ||
    units_per_em > 16384 ||
    glyph_count == 0 ||
    metric_count == 0 ||
    metric_count > glyph_count {
    raise Invalid("invalid TrueType header, glyph count or horizontal metrics")
  }
  let loca_entry_size = if format == 1 { 4 } else { 2 }
  if loca.length() < (glyph_count + 1) * loca_entry_size ||
    hmtx.length() < metric_count * 4 + (glyph_count - metric_count) * 2 {
    raise Invalid("truncated TrueType glyph offsets or metrics")
  }
  {
    glyf,
    loca,
    hmtx,
    glyph_count,
    long_loca: format == 1,
    metric_count,
    units_per_em,
    signatures: Map([]),
    outline_budget,
  }
}

///|
fn TrueType::glyph_offset(
  self : TrueType,
  index : Int32,
) -> Int32 raise GuardError {
  if self.long_loca {
    u32_index(self.loca, index * 4)
  } else {
    u16(self.loca, index * 2) * 2
  }
}

///|
fn append_int(out : StringBuilder, n : Int32) -> Unit {
  out.write_string(n.to_string())
  out.write_char(',')
}

///|
fn parse_points(
  data : BytesView,
  flags : Array[Int32],
  start : Int32,
  short_bit : Int32,
  same_bit : Int32,
) -> (Array[Int32], Int32) raise GuardError {
  let coords : Array[Int32] = Array(capacity=flags.length())
  let mut p = start
  let mut previous = 0
  for flag in flags {
    let same_or_positive = (flag & same_bit) != 0
    if (flag & short_bit) != 0 {
      let delta = u8(data, p)
      p += 1
      previous += if same_or_positive { delta } else { -delta }
    } else if !same_or_positive {
      previous += i16(data, p)
      p += 2
    }
    if previous < -32768 || previous > 32767 {
      raise Invalid("TrueType contour position overflow")
    }
    coords.push(previous)
  }
  (coords, p)
}

///|
fn simple_outline(
  glyph : BytesView,
  contours : Int32,
  out : StringBuilder,
) -> Unit raise GuardError {
  out.write_char('S')
  append_int(out, contours)
  let mut last = -1
  for i in 0..<contours {
    let end = u16(glyph, 10 + 2 * i)
    if end <= last || end >= 16384 {
      raise Invalid("invalid or oversized TrueType contour")
    }
    append_int(out, end)
    last = end
  }
  let points = last + 1
  let instr = 10 + contours * 2
  let mut pos = instr + 2 + u16(glyph, instr)
  if pos > glyph.length() {
    raise Invalid("truncated TrueType instructions")
  }
  let flags : Array[Int32] = Array(capacity=points)
  while flags.length() < points {
    let flag = u8(glyph, pos)
    pos += 1
    let repeats = if (flag & 8) != 0 {
      let count = u8(glyph, pos)
      pos += 1
      count
    } else {
      0
    }
    if repeats + 1 > points - flags.length() {
      raise Invalid("invalid TrueType point flag repeat")
    }
    for _ in 0..<=repeats {
      flags.push(flag)
    }
  }
  let (xs, after_x) = parse_points(glyph, flags, pos, 0x02, 0x10)
  let (ys, _) = parse_points(glyph, flags, after_x, 0x04, 0x20)
  for i, flag in flags {
    append_int(out, flag & 1)
    append_int(out, xs[i])
    append_int(out, ys[i])
  }
}

///|
fn TrueType::composite_outline(
  self : TrueType,
  glyph : BytesView,
  depth : Int32,
  out : StringBuilder,
) -> Unit raise GuardError {
  out.write_char('C')
  let mut p = 10
  let mut component_count = 0
  let mut expanded_size = 0
  while true {
    component_count += 1
    if component_count > 64 {
      raise Unsupported("too many TrueType components")
    }
    let flags = u16(glyph, p)
    let gid = u16(glyph, p + 2)
    p += 4
    let words = (flags & 0x0001) != 0
    let xy_offsets = (flags & 0x0002) != 0
    let stride = if words { 2 } else { 1 }
    let arg = fn(at : Int32) -> Int32 raise GuardError {
      match (words, xy_offsets) {
        (true, true) => i16(glyph, at)
        (true, false) => u16(glyph, at)
        (false, true) => i8(glyph, at)
        (false, false) => u8(glyph, at)
      }
    }
    let arg1 = arg(p)
    let arg2 = arg(p + stride)
    p += stride * 2
    let mut a = 16384
    let mut b = 0
    let mut c = 0
    let mut d = 16384
    match flags & 0x00C8 {
      0 => ()
      0x0008 => {
        a = i16(glyph, p)
        d = a
        p += 2
      }
      0x0040 => {
        a = i16(glyph, p)
        d = i16(glyph, p + 2)
        p += 4
      }
      0x0080 => {
        a = i16(glyph, p)
        b = i16(glyph, p + 2)
        c = i16(glyph, p + 4)
        d = i16(glyph, p + 6)
        p += 8
      }
      _ => raise Invalid("conflicting TrueType component transform flags")
    }
    let child = self.signature(gid, depth + 1)
    expanded_size += child.length()
    if expanded_size > 500_000 {
      raise Unsupported("TrueType composite outline exceeds the size limit")
    }
    // Keep flags affecting offsets or metrics, plus point-vs-XY interpretation.
    append_int(out, flags & 0x1A06)
    append_int(out, arg1)
    append_int(out, arg2)
    append_int(out, a)
    append_int(out, b)
    append_int(out, c)
    append_int(out, d)
    out.write_char('(')
    out.write_string(child)
    out.write_char(')')
    if (flags & 0x0020) == 0 {
      if (flags & 0x0100) != 0 {
        let size = u16(glyph, p)
        ignore(sfnt_view(glyph, p + 2, size))
      }
      break
    }
  }
}

///|
fn TrueType::signature(
  self : TrueType,
  gid : Int32,
  depth : Int32,
) -> String raise GuardError {
  if gid < 0 || gid >= self.glyph_count {
    raise Invalid("CIDToGIDMap points outside the embedded font")
  }
  if depth > 16 {
    raise Unsupported("cyclic or deeply nested TrueType components")
  }
  if self.signatures.get(gid) is Some(existing) {
    return existing
  }
  let out = StringBuilder()
  let metric_gid = gid.min(self.metric_count - 1)
  append_int(out, self.units_per_em)
  append_int(out, u16(self.hmtx, metric_gid * 4))
  let lsb = if gid < self.metric_count {
    gid * 4 + 2
  } else {
    self.metric_count * 4 + (gid - self.metric_count) * 2
  }
  append_int(out, i16(self.hmtx, lsb))
  let start = self.glyph_offset(gid)
  let end = self.glyph_offset(gid + 1)
  let glyph = sfnt_view(self.glyf, start, end - start)
  let contours = if glyph.is_empty() {
    0
  } else {
    ignore(sfnt_view(glyph, 0, 10))
    i16(glyph, 0)
  }
  if contours == 0 {
    out.write_char('E')
  } else if contours > 0 {
    simple_outline(glyph, contours, out)
  } else if contours == -1 {
    self.composite_outline(glyph, depth, out)
  } else {
    raise Invalid("unsupported TrueType contour kind")
  }
  let key = out.to_string()
  if key.length() > self.outline_budget.val {
    raise Unsupported("PDF exceeds the normalized outline budget")
  }
  self.outline_budget.val -= key.length()
  self.signatures.set(gid, key)
  key
}
