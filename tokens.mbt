///|
priv suberror GuardError {
  Unsupported(String)
  Invalid(String)
}

///|
priv enum TokenKind {
  Integer(Int32)
  Real(Double)
  Name(Bytes)
  Hex(Bytes)
  Literal(Bytes)
  Word(String)
  Atom
  ArrayOpen
  ArrayClose
  DictOpen
  DictClose
}

///|
priv struct Token {
  kind : TokenKind
  start : Int32
  end : Int32
}

///|
priv struct Lexer {
  data : BytesView
  mut pos : Int32
}

///|
fn is_space(b : Int32) -> Bool {
  b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32
}

///|
fn is_delimiter(b : Int32) -> Bool {
  b == 40 ||
  b == 41 ||
  b == 60 ||
  b == 62 ||
  b == 91 ||
  b == 93 ||
  b == 123 ||
  b == 125 ||
  b == 47 ||
  b == 37
}

///|
fn hex_digit(b : Int32) -> Int32 {
  if b >= 48 && b <= 57 {
    b - 48
  } else if b >= 65 && b <= 70 {
    b - 55
  } else if b >= 97 && b <= 102 {
    b - 87
  } else {
    -1
  }
}

///|
fn decimal_digit(b : Int32) -> Bool {
  b >= 48 && b <= 57
}

///|
fn Lexer::peek(self : Lexer, ahead~ : Int32 = 0) -> Int32 {
  if self.pos + ahead < self.data.length() {
    self.data[self.pos + ahead].to_int()
  } else {
    -1
  }
}

///|
fn Lexer::skip_space(self : Lexer) -> Unit {
  while self.pos < self.data.length() {
    let b = self.peek()
    if is_space(b) {
      self.pos += 1
    } else if b == 37 {
      while self.pos < self.data.length() &&
            self.peek() != 10 &&
            self.peek() != 13 {
        self.pos += 1
      }
    } else {
      return
    }
  }
}

///|
fn Lexer::hex_string(self : Lexer, strict : Bool) -> TokenKind raise GuardError {
  self.pos += 1
  let bytes : Array[Byte] = []
  let mut lead = -1
  while self.pos < self.data.length() {
    let b = self.peek()
    self.pos += 1
    if b == 62 {
      if lead >= 0 {
        if strict {
          raise Invalid("odd number of hexadecimal digits in CMap string")
        }
        bytes.push((lead << 4).to_byte())
      }
      return Hex(Bytes::from_array(bytes))
    }
    if !is_space(b) {
      let digit = hex_digit(b)
      if digit < 0 {
        raise Invalid("invalid hexadecimal digit")
      }
      if lead < 0 {
        lead = digit
      } else {
        bytes.push(((lead << 4) | digit).to_byte())
        lead = -1
      }
    }
  }
  raise Invalid("unterminated hexadecimal string")
}

///|
fn Lexer::pdf_primitive(
  self : Lexer,
  is_name : Bool,
) -> TokenKind raise GuardError {
  let start = self.pos
  let cursor = @pdfcore.byte_cursor_of_view(self.data[start:])
  let value = try {
    if is_name {
      @syntax.pdf_cursor_lex_name(cursor)
    } else {
      @syntax.pdf_cursor_lex_literal_string(cursor)
    }
  } catch {
    _ => raise Invalid("invalid PDF name or literal string")
  }
  self.pos += cursor.position()
  match value {
    LexName(name) => Name(pdf_name_payload(name).to_owned())
    LexString(bytes) => Literal(bytes)
    _ => raise Invalid("invalid PDF name or literal string")
  }
}

///|
fn classify_regular(raw : BytesView) -> TokenKind raise GuardError {
  let word = @utf8.decode_lossy(raw)
  let first = raw[0].to_int()
  if decimal_digit(first) || first == 43 || first == 45 || first == 46 {
    let mut dots = 0
    let mut digits = 0
    for i in 0..<raw.length() {
      let b = raw[i].to_int()
      if decimal_digit(b) {
        digits += 1
      } else if b == 46 {
        dots += 1
      } else if i != 0 || (b != 43 && b != 45) {
        raise Invalid("invalid PDF number")
      }
    }
    if digits == 0 || dots > 1 || raw.length() > 32 {
      raise Invalid("invalid PDF number")
    }
    try {
      if dots == 0 {
        Integer(@string.parse_int(word))
      } else {
        let n = @string.parse_double(word)
        if !n.is_finite() {
          raise Invalid("non-finite PDF number")
        }
        Real(n)
      }
    } catch {
      _ => raise Invalid("PDF number is out of range")
    }
  } else if word == "true" || word == "false" || word == "null" {
    Atom
  } else {
    Word(word)
  }
}

///|
fn Lexer::next(self : Lexer, cmap~ : Bool = false) -> Token? raise GuardError {
  self.skip_space()
  let start = self.pos
  if start == self.data.length() {
    return None
  }
  let kind = match self.peek() {
    40 => self.pdf_primitive(false)
    47 => self.pdf_primitive(true)
    60 =>
      if self.peek(ahead=1) == 60 {
        self.pos += 2
        DictOpen
      } else {
        self.hex_string(cmap)
      }
    62 => {
      if self.peek(ahead=1) != 62 {
        raise Invalid("unexpected '>'")
      }
      self.pos += 2
      DictClose
    }
    91 => {
      self.pos += 1
      ArrayOpen
    }
    93 => {
      self.pos += 1
      ArrayClose
    }
    b if is_delimiter(b) => raise Invalid("unexpected PDF delimiter")
    _ => {
      while self.pos < self.data.length() &&
            !is_space(self.peek()) &&
            !is_delimiter(self.peek()) {
        self.pos += 1
      }
      classify_regular(self.data[start:self.pos])
    }
  }
  Some({ kind, start, end: self.pos, })
}

///|
fn name_string(bytes : Bytes) -> String {
  @utf8.decode_lossy(bytes)
}

///|
fn pdf_name_payload(name : @pdfcore.PdfName) -> BytesView {
  // The pdflite 0.4.2 lexer includes the delimiter slash in parsed names.
  let raw = name.view()
  if !raw.is_empty() && raw[0] == b'/' {
    raw[1:]
  } else {
    raw
  }
}

///|
fn display_hex(n : Int32, minimum : Int32) -> String {
  let hex = n.to_string(radix=16).to_upper()
  let pad = minimum - hex.length()
  if pad > 0 {
    "0".repeat(pad) + hex
  } else {
    hex
  }
}
