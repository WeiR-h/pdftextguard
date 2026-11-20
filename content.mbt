///|
priv struct Graphics {
  ctm : Matrix
  font : Bytes?
  size : Double
  spacing : Double
  scale : Double
  leading : Double
  rise : Double
  mode : Int32
}

///|
priv struct GlyphUse {
  family : Bytes
  outline : String
  pose : Matrix
  advance : Double
  mapping : Mapping?
  cmap_valid : Bool
  site : UseSite
}

///|
priv struct PageScan {
  glyphs : Array[GlyphUse]
  diagnostics : Array[Diagnostic]
  bounds : Array[Double]
  mut blocked : Bool
  mut syntax_error : Bool
}

///|
priv struct ContentScan {
  doc : Document
  side : String
  page : Int32
  resources : @syntax.PdfObject
  output : PageScan
  fonts : Map[Bytes, Font]
  stack : Array[Graphics]
  mut graphics : Graphics
  mut in_text : Bool
  mut text : Matrix
  mut line : Matrix
  mut marked_depth : Int32
  mut stream : ObjectRef?
  mut stream_index : Int32
  mut decoded_offset : Int32?
  glyph_budget : Int32
}

///|
fn Token::as_number(self : Token) -> Double raise GuardError {
  match self.kind {
    Integer(n) => n.to_double()
    Real(n) => n
    _ => raise Invalid("expected numeric content operand")
  }
}

///|
fn Token::as_name(self : Token) -> Bytes raise GuardError {
  match self.kind {
    Name(n) => n
    _ => raise Invalid("expected a name operand")
  }
}

///|
fn Token::as_string(self : Token) -> Bytes raise GuardError {
  match self.kind {
    Hex(s) | Literal(s) => s
    _ => raise Invalid("expected a text-showing string")
  }
}

///|
fn arg_count(
  op : String,
  args : Array[Token],
  n : Int32,
) -> Unit raise GuardError {
  if args.length() != n {
    raise Invalid("unexpected operand count for \{op}")
  }
}

///|
fn ContentScan::require_text(
  self : ContentScan,
  op : String,
) -> Unit raise GuardError {
  if !self.in_text {
    raise Invalid("\{op} outside a text object")
  }
}

///|
fn ContentScan::move_line(self : ContentScan, x : Double, y : Double) -> Unit {
  self.line = self.line.translate(x, y)
  self.text = self.line
}

///|
fn ContentScan::active_font(self : ContentScan) -> Font raise GuardError {
  let resource = match self.graphics.font {
    Some(name) if self.graphics.size > 0 => name
    _ => raise Invalid("text shown without a positive-size active font")
  }
  if self.fonts.get(resource) is Some(font) {
    return font
  }
  if self.fonts.length() >= 64 {
    raise Unsupported("page has too many used fonts")
  }
  let font = self.doc.font(self.resources, resource)
  self.fonts.set(resource, font)
  font
}

///|
fn append_cmap_diagnostics(
  page : PageScan,
  side : String,
  font : Font,
  site : UseSite,
) -> Unit {
  if font.cmap_reported || font.cmap.issues.is_empty() {
    return
  }
  font.cmap_reported = true
  for issue in font.cmap.issues {
    if issue.unsupported {
      page.blocked = true
    } else {
      page.syntax_error = true
    }
    let code = if issue.unsupported {
      "cmap_unsupported"
    } else {
      "cmap_syntax"
    }
    let d = note(code, side, issue.message, page=site.page)
    page.diagnostics.push({
      ..d,
      baseline: if side == "baseline" {
        Some(site)
      } else {
        None
      },
      candidate: if side == "candidate" {
        Some(site)
      } else {
        None
      },
      cmap: Some({
        font_resource: font.resource,
        font_object: font.object,
        cmap_object: font.cmap_object,
        span: issue.span,
        declared: issue.declared,
        observed: issue.observed,
      }),
    })
  }
}

///|
fn ContentScan::show_string(
  self : ContentScan,
  op : String,
  op_at : Int32,
  token : Token,
) -> Unit raise GuardError {
  let data = token.as_string()
  if data.length() % 2 != 0 {
    raise Invalid("odd string length for an Identity-H font")
  }
  if data.is_empty() {
    return
  }
  self.require_text(op)
  let gs = self.graphics
  if gs.mode >= 3 {
    raise Unsupported("invisible or clipping text rendering mode")
  }
  if gs.scale <= 0.0 || gs.scale > 1000.0 {
    raise Unsupported("nonpositive or excessive horizontal text scale")
  }
  let font = self.active_font()
  if data.length() / 2 > self.glyph_budget - self.output.glyphs.length() {
    raise Unsupported("PDF exceeds the 100,000 text glyph limit")
  }
  for i = 0; i < data.length(); i = i + 2 {
    let cid = (data[i].to_int() << 8) | data[i + 1].to_int()
    let gid = font.gid(cid)
    let outline = font.ttf.signature(gid, 0)
    let pose = gs.ctm
      .multiply(self.text)
      .multiply({
        a: gs.size * gs.scale,
        b: 0,
        c: 0,
        d: gs.size,
        x: 0,
        y: gs.rise,
      })
    guard_matrix(pose)
    if (pose.a * pose.d - pose.b * pose.c).abs() < 0.000000001 {
      raise Unsupported("degenerate text transform")
    }
    let width = font.widths.get(cid).unwrap_or(font.default_width)
    // Tw applies to a single-byte 0x20 code, never to Identity-H two-byte codes.
    let advance = (width * gs.size / 1000.0 + gs.spacing) * gs.scale
    let mapping = if font.cmap.issues.is_empty() {
      font.cmap.entries.get(cid)
    } else {
      None
    }
    let site : UseSite = {
      page: self.page,
      content_object: self.stream,
      stream_index: self.stream_index,
      operator: op,
      operator_offset: op_at,
      string_offset: token.start,
      byte_index: i,
      font_resource: font.resource,
      font_object: font.object,
      descendant_object: font.descendant,
      font_file_object: font.file,
      cmap_object: font.cmap_object,
      code: display_hex(cid, 4),
      cid,
      gid,
      origin_x: pose.x,
      origin_y: pose.y,
      unicode: mapping.map(m => unicode_labels(m.scalars)),
      rule: mapping.map(m => m.rule),
    }
    append_cmap_diagnostics(self.output, self.side, font, site)
    self.output.glyphs.push({
      family: font.family,
      outline,
      pose,
      advance,
      mapping,
      cmap_valid: font.cmap.issues.is_empty(),
      site,
    })
    self.text = self.text.translate(advance, 0)
  }
}

///|
fn ContentScan::show_array(
  self : ContentScan,
  op_at : Int32,
  args : Array[Token],
) -> Unit raise GuardError {
  if args.length() < 2 ||
    !(args[0].kind is ArrayOpen) ||
    !(args[args.length() - 1].kind is ArrayClose) {
    raise Invalid("TJ requires a single array")
  }
  for i in 1..<(args.length() - 1) {
    let token = args[i]
    match token.kind {
      Real(_) | Integer(_) => {
        let delta = -token.as_number() *
          self.graphics.size *
          self.graphics.scale /
          1000.0
        self.text = self.text.translate(delta, 0)
      }
      Hex(_) | Literal(_) => self.show_string("TJ", op_at, token)
      _ => raise Invalid("invalid TJ array element")
    }
  }
}

///|
fn content_matrix(op : String, args : Array[Token]) -> Matrix raise GuardError {
  arg_count(op, args, 6)
  {
    a: args[0].as_number(),
    b: args[1].as_number(),
    c: args[2].as_number(),
    d: args[3].as_number(),
    x: args[4].as_number(),
    y: args[5].as_number(),
  }
}

///|
fn ContentScan::resource(
  self : ContentScan,
  category : Bytes,
  name : Bytes,
) -> @syntax.PdfObject raise GuardError {
  let dictionary = self.doc.resolve(required_field(self.resources, category))
  self.doc.resolve(required_field(dictionary, name))
}

///|
fn ContentScan::check_marks(
  self : ContentScan,
  op : String,
  args : Array[Token],
) -> Unit raise GuardError {
  if args.is_empty() {
    raise Invalid("missing marked-content tag")
  }
  if args[0].as_name() == b"OC" {
    raise Unsupported("optional-content text layer")
  }
  if op == "BDC" || op == "DP" {
    if args.length() < 2 {
      raise Invalid("missing marked-content properties")
    }
    match args[1].kind {
      Name(name) if args.length() == 2 => {
        let props = self.resource(b"Properties", name)
        if field(props, b"ActualText") is Some(_) {
          raise Unsupported(
            "marked-content ActualText can override font mappings",
          )
        }
      }
      DictOpen if args[args.length() - 1].kind is DictClose =>
        for t in args {
          if t.kind is Name(n) && n == b"ActualText" {
            raise Unsupported(
              "marked-content ActualText can override font mappings",
            )
          }
        }
      _ => raise Unsupported("unhandled marked-content properties")
    }
  } else {
    arg_count(op, args, 1)
  }
  if op == "BDC" || op == "BMC" {
    self.marked_depth += 1
  }
}

///|
fn ContentScan::operator(
  self : ContentScan,
  op : String,
  op_at : Int32,
  args : Array[Token],
) -> Unit raise GuardError {
  match op {
    "q" => {
      arg_count(op, args, 0)
      if self.stack.length() >= 128 {
        raise Unsupported("excessive graphics state nesting")
      }
      self.stack.push(self.graphics)
    }
    "Q" => {
      arg_count(op, args, 0)
      match self.stack.pop() {
        Some(saved) => self.graphics = saved
        None => raise Invalid("unbalanced graphics state restore")
      }
    }
    "cm" => {
      let ctm = self.graphics.ctm.multiply(content_matrix(op, args))
      guard_matrix(ctm)
      self.graphics = { ..self.graphics, ctm, }
    }
    "BT" => {
      arg_count(op, args, 0)
      if self.in_text {
        raise Invalid("nested text objects")
      }
      self.in_text = true
      self.text = identity
      self.line = identity
    }
    "ET" => {
      self.require_text(op)
      arg_count(op, args, 0)
      self.in_text = false
    }
    "Tf" => {
      arg_count(op, args, 2)
      let name = args[0].as_name()
      let size = args[1].as_number()
      self.graphics = { ..self.graphics, font: Some(name), size, }
    }
    "Tm" => {
      self.require_text(op)
      self.text = content_matrix(op, args)
      guard_matrix(self.text)
      self.line = self.text
    }
    "Td" | "TD" => {
      self.require_text(op)
      arg_count(op, args, 2)
      let x = args[0].as_number()
      let y = args[1].as_number()
      if op == "TD" {
        self.graphics = { ..self.graphics, leading: -y, }
      }
      self.move_line(x, y)
    }
    "T*" => {
      self.require_text(op)
      arg_count(op, args, 0)
      self.move_line(0, -self.graphics.leading)
    }
    "Tc" | "Tw" | "Tz" | "TL" | "Ts" | "Tr" => {
      arg_count(op, args, 1)
      let value = args[0].as_number()
      self.graphics = match op {
        "Tc" => { ..self.graphics, spacing: value, }
        "Tz" => { ..self.graphics, scale: value / 100.0, }
        "TL" => { ..self.graphics, leading: value, }
        "Ts" => { ..self.graphics, rise: value, }
        "Tr" =>
          match args[0].kind {
            Integer(mode) if mode >= 0 && mode <= 7 =>
              { ..self.graphics, mode, }
            _ => raise Invalid("invalid text rendering mode")
          }
        _ => self.graphics
      }
    }
    "Tj" | "'" | "\"" => {
      self.require_text(op)
      let index = if op == "\"" { 2 } else { 0 }
      arg_count(op, args, index + 1)
      if index == 2 {
        ignore(args[0].as_number())
        self.graphics = { ..self.graphics, spacing: args[1].as_number(), }
      }
      if op != "Tj" {
        self.move_line(0, -self.graphics.leading)
      }
      self.show_string(op, op_at, args[index])
    }
    "TJ" => {
      self.require_text(op)
      self.show_array(op_at, args)
    }
    "BDC" | "BMC" | "DP" | "MP" => self.check_marks(op, args)
    "EMC" => {
      arg_count(op, args, 0)
      if self.marked_depth == 0 {
        raise Invalid("unbalanced marked-content end")
      }
      self.marked_depth -= 1
    }
    "gs" => {
      arg_count(op, args, 1)
      let ext = self.resource(b"ExtGState", args[0].as_name())
      if field(ext, b"Font") is Some(_) {
        raise Unsupported("ExtGState font selection")
      }
    }
    "Do" => {
      arg_count(op, args, 1)
      let xobject = self.resource(b"XObject", args[0].as_name())
      if self.doc.name(required_field(xobject, b"Subtype")) != b"Image" {
        raise Unsupported("Form or non-image XObject")
      }
    }
    "BI" => raise Unsupported("inline image in content stream")
    "w"
    | "J"
    | "j"
    | "M"
    | "d"
    | "ri"
    | "i"
    | "m"
    | "l"
    | "c"
    | "v"
    | "y"
    | "h"
    | "re"
    | "S"
    | "s"
    | "f"
    | "F"
    | "f*"
    | "B"
    | "B*"
    | "b"
    | "b*"
    | "n"
    | "W"
    | "W*"
    | "CS"
    | "cs"
    | "SC"
    | "SCN"
    | "sc"
    | "scn"
    | "G"
    | "g"
    | "RG"
    | "rg"
    | "K"
    | "k"
    | "sh"
    | "BX"
    | "EX" => ()
    _ => raise Unsupported("unhandled content operator \{op}")
  }
}

///|
fn ContentScan::read_stream(
  self : ContentScan,
  raw : @syntax.PdfObject,
  stream_index : Int32,
) -> Unit raise GuardError {
  self.stream = self.doc.reference(raw)
  self.stream_index = stream_index
  self.decoded_offset = None
  let data = self.doc.decoded_stream(raw, 8 * 1024 * 1024)
  let lexer : Lexer = { data, pos: 0, }
  let mut args : Array[Token] = []
  let nest : Array[Bool] = [] // true for dictionary, false for array
  let mut token_count = 0
  while true {
    lexer.skip_space()
    self.decoded_offset = Some(lexer.pos)
    match lexer.next() {
      None => break
      Some(token) => {
        token_count += 1
        if token_count > 300_000 || args.length() > 16_384 || nest.length() > 32 {
          raise Unsupported(
            "content stream exceeds the operand or nesting limit",
          )
        }
        match token.kind {
          ArrayOpen => {
            nest.push(false)
            args.push(token)
          }
          DictOpen => {
            nest.push(true)
            args.push(token)
          }
          ArrayClose | DictClose => {
            let is_dict = token.kind is DictClose
            if nest.pop() != Some(is_dict) {
              raise Invalid("unbalanced content operands")
            }
            args.push(token)
          }
          Word(op) if nest.is_empty() => {
            self.operator(op, token.start, args)
            args = []
          }
          _ => args.push(token)
        }
      }
    }
  }
  if !args.is_empty() || !nest.is_empty() {
    raise Unsupported("content operand is incomplete at the stream boundary")
  }
}
