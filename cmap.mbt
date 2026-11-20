///|
/// Byte spans are half open and relative to the decoded ToUnicode stream.
#derive(@json.ToJson)
pub struct CMapSpan {
  operator : String
  decoded_offset : Int32
  decoded_end : Int32
  value_offset : Int32?
  range_index : Int32?
}

///|
pub extend CMapSpan with @json.ToJson::{to_json}

///|
priv struct Mapping {
  scalars : Array[Int32]
  rule : CMapSpan
}

///|
priv struct CMapIssue {
  message : String
  span : CMapSpan
  declared : Int32?
  observed : Int32?
  unsupported : Bool
}

///|
priv struct CMap {
  entries : Map[Int32, Mapping]
  issues : Array[CMapIssue]
}

///|
priv suberror CMapError {
  BadCMap(CMapIssue)
}

///|
fn cmap_error(
  message : String,
  start : Int32,
  end : Int32,
  operator : String,
  unsupported~ : Bool = false,
) -> CMapError {
  BadCMap({
    message,
    span: {
      operator,
      decoded_offset: start,
      decoded_end: end,
      value_offset: None,
      range_index: None,
    },
    declared: None,
    observed: None,
    unsupported,
  })
}

///|
priv struct CMapReader {
  tokens : Array[Token]
  mut at : Int32
  size : Int32
}

///|
fn CMapReader::take(self : CMapReader, op : String) -> Token raise CMapError {
  match self.tokens.get(self.at) {
    Some(token) => {
      self.at += 1
      token
    }
    None =>
      raise cmap_error("unterminated CMap block", self.size, self.size, op)
  }
}

///|
fn CMapReader::hex(
  self : CMapReader,
  op : String,
) -> (Bytes, Token) raise CMapError {
  let token = self.take(op)
  match token.kind {
    Hex(bytes) => (bytes, token)
    _ =>
      raise cmap_error(
        "expected a hexadecimal string",
        token.start,
        token.end,
        op,
      )
  }
}

///|
fn code_value(
  bytes : Bytes,
  token : Token,
  op : String,
) -> Int32 raise CMapError {
  if bytes.length() != 2 {
    raise cmap_error(
      "Identity-H CMap sources must contain two bytes",
      token.start,
      token.end,
      op,
    )
  }
  (bytes[0].to_int() << 8) | bytes[1].to_int()
}

///|
fn CMapReader::code(
  self : CMapReader,
  op : String,
) -> (Int32, Token) raise CMapError {
  let (bytes, token) = self.hex(op)
  (code_value(bytes, token, op), token)
}

///|
fn utf16_scalars(bytes : Bytes) -> Array[Int32]? {
  if bytes.length() == 0 || bytes.length() % 2 != 0 {
    return None
  }
  let scalars : Array[Int32] = []
  let mut i = 0
  while i < bytes.length() {
    let high = (bytes[i].to_int() << 8) | bytes[i + 1].to_int()
    i += 2
    if high >= 0xD800 && high <= 0xDBFF {
      if i + 1 >= bytes.length() {
        return None
      }
      let low = (bytes[i].to_int() << 8) | bytes[i + 1].to_int()
      if low < 0xDC00 || low > 0xDFFF {
        return None
      }
      scalars.push(0x10000 + ((high - 0xD800) << 10) + low - 0xDC00)
      i += 2
    } else if high >= 0xDC00 && high <= 0xDFFF {
      return None
    } else {
      scalars.push(high)
    }
  }
  Some(scalars)
}

///|
fn parse_mapping(
  bytes : Bytes,
  token : Token,
  op : String,
) -> Array[Int32] raise CMapError {
  if bytes.length() > 256 {
    raise cmap_error(
      "ToUnicode destination exceeds the 256-byte limit",
      token.start,
      token.end,
      op,
      unsupported=true,
    )
  }
  match utf16_scalars(bytes) {
    Some(value) => value
    None =>
      raise cmap_error(
        "destination is not a valid UTF-16BE sequence",
        token.start,
        token.end,
        op,
      )
  }
}

///|
fn put_mapping(
  mappings : Map[Int32, Mapping],
  code : Int32,
  scalars : Array[Int32],
  rule : CMapSpan,
) -> Unit raise CMapError {
  if mappings.contains(code) {
    raise cmap_error(
      "duplicate source code <\{display_hex(code, 4)}>",
      rule.decoded_offset,
      rule.decoded_end,
      rule.operator,
    )
  }
  mappings.set(code, { scalars, rule, })
}

///|
fn CMapReader::bfchar(
  self : CMapReader,
  mappings : Map[Int32, Mapping],
) -> Unit raise CMapError {
  let op = "bfchar"
  let (code, source) = self.code(op)
  let (bytes, dest) = self.hex(op)
  let scalars = parse_mapping(bytes, dest, op)
  put_mapping(mappings, code, scalars, {
    operator: op,
    decoded_offset: source.start,
    decoded_end: dest.end,
    value_offset: Some(dest.start),
    range_index: None,
  })
}

///|
fn CMapReader::bfrange(
  self : CMapReader,
  mappings : Map[Int32, Mapping],
) -> Unit raise CMapError {
  let op = "bfrange"
  let (first, source) = self.code(op)
  let (last, upper) = self.code(op)
  if last < first {
    raise cmap_error("descending source range", source.start, upper.end, op)
  }
  let target = self.take(op)
  match target.kind {
    Hex(start) => {
      // The PDF ToUnicode integer form only increments the last destination
      // byte. Reject overflow instead of letting it carry into the prefix.
      let bytes = start.to_array()
      if bytes.length() > 256 {
        raise cmap_error(
          "ToUnicode destination exceeds the 256-byte limit",
          target.start,
          target.end,
          op,
          unsupported=true,
        )
      }
      if bytes.is_empty() ||
        bytes[bytes.length() - 1].to_int() + last - first > 255 {
        raise cmap_error(
          "sequential bfrange destination overflows its final byte",
          target.start,
          target.end,
          op,
        )
      }
      for code in first..<=last {
        let scalars = parse_mapping(Bytes::from_array(bytes), target, op)
        put_mapping(mappings, code, scalars, {
          operator: op,
          decoded_offset: source.start,
          decoded_end: target.end,
          value_offset: Some(target.start),
          range_index: Some(code - first),
        })
        if code != last {
          let i = bytes.length() - 1
          bytes[i] = (bytes[i].to_int() + 1).to_byte()
        }
      }
    }
    ArrayOpen => {
      let values : Array[(Array[Int32], Token)] = Array(
        capacity=last - first + 1,
      )
      for _ in first..<=last {
        let (bytes, dest) = self.hex(op)
        values.push((parse_mapping(bytes, dest, op), dest))
      }
      let end = self.take(op)
      if !(end.kind is ArrayClose) {
        raise cmap_error(
          "bfrange array length does not match its source range",
          source.start,
          end.end,
          op,
        )
      }
      for i, value in values {
        put_mapping(mappings, first + i, value.0, {
          operator: op,
          decoded_offset: source.start,
          decoded_end: end.end,
          value_offset: Some(value.1.start),
          range_index: Some(i),
        })
      }
    }
    _ =>
      raise cmap_error(
        "expected a bfrange destination or array",
        target.start,
        target.end,
        op,
      )
  }
}

///|
fn parse_cmap_tokens(reader : CMapReader, cmap : CMap) -> Unit raise CMapError {
  let ranges : Array[(Int32, Int32)] = []
  let mut started = false
  let mut ended = false
  while reader.at < reader.tokens.length() {
    let index = reader.at
    let token = reader.take("cmap")
    let op = match token.kind {
      Word(word) => word
      _ => continue
    }
    match op {
      "begincmap" => {
        if started {
          raise cmap_error(
            "duplicate begincmap operator",
            token.start,
            token.end,
            op,
          )
        }
        started = true
      }
      "endcmap" => {
        if !started || ended {
          raise cmap_error(
            "unexpected endcmap operator",
            token.start,
            token.end,
            op,
          )
        }
        ended = true
      }
      "begincodespacerange" | "beginbfchar" | "beginbfrange" => {
        if !started || ended || index == 0 {
          raise cmap_error(
            "mapping block outside CMap body",
            token.start,
            token.end,
            op,
          )
        }
        let marker = reader.tokens[index - 1]
        let declared = match marker.kind {
          Integer(n) if n >= 0 && n <= 65536 => n
          _ =>
            raise cmap_error(
              "missing or invalid CMap block count",
              marker.start,
              token.end,
              op,
            )
        }
        let end_op = match op {
          "beginbfchar" => "endbfchar"
          "beginbfrange" => "endbfrange"
          _ => "endcodespacerange"
        }
        let mut actual = 0
        while true {
          let next = reader.take(op)
          if next.kind is Word(word) && word == end_op {
            if actual != declared {
              if cmap.issues.length() >= 32 {
                raise cmap_error(
                  "too many CMap block count errors",
                  marker.start,
                  token.end,
                  op,
                )
              }
              cmap.issues.push({
                message: "declared block count differs from actual entry count",
                span: {
                  operator: op,
                  decoded_offset: marker.start,
                  decoded_end: token.end,
                  value_offset: None,
                  range_index: None,
                },
                declared: Some(declared),
                observed: Some(actual),
                unsupported: false,
              })
            }
            break
          }
          reader.at -= 1
          match op {
            "beginbfchar" => reader.bfchar(cmap.entries)
            "beginbfrange" => reader.bfrange(cmap.entries)
            _ => {
              let (lo, first) = reader.code(op)
              let (hi, last) = reader.code(op)
              if hi < lo ||
                ranges.length() >= 64 ||
                ranges.any(r => lo <= r.1 && hi >= r.0) {
                raise cmap_error(
                  "invalid or overlapping codespace range",
                  first.start,
                  last.end,
                  op,
                )
              }
              ranges.push((lo, hi))
            }
          }
          actual += 1
        }
      }
      "usecmap" =>
        raise cmap_error(
          "ToUnicode CMap inheritance is unsupported",
          token.start,
          token.end,
          op,
          unsupported=true,
        )
      "begincidchar"
      | "begincidrange"
      | "beginnotdefchar"
      | "beginnotdefrange" =>
        raise cmap_error(
          "unsupported ToUnicode mapping operator",
          token.start,
          token.end,
          op,
        )
      "endbfchar" | "endbfrange" | "endcodespacerange" =>
        raise cmap_error(
          "unexpected mapping block terminator",
          token.start,
          token.end,
          op,
        )
      _ =>
        if started &&
          !ended &&
          op != "def" &&
          op != "dict" &&
          op != "dup" &&
          op != "begin" &&
          op != "end" &&
          op != "put" {
          raise cmap_error(
            "unsupported operator in the CMap body",
            token.start,
            token.end,
            op,
            unsupported=true,
          )
        }
    }
  }
  if !started || !ended || ranges.is_empty() {
    raise cmap_error(
      "CMap must contain a body and a two-byte codespace",
      0,
      reader.size,
      "cmap",
    )
  }
  for code, mapping in cmap.entries {
    if !ranges.any(r => r.0 <= code && code <= r.1) {
      raise cmap_error(
        "source code lies outside the codespace",
        mapping.rule.decoded_offset,
        mapping.rule.decoded_end,
        mapping.rule.operator,
      )
    }
  }
}

///|
fn parse_cmap(data : Bytes) -> CMap {
  let result : CMap = { entries: Map([]), issues: [], }
  let lexer : Lexer = { data, pos: 0, }
  let tokens : Array[Token] = []
  try {
    while true {
      lexer.skip_space()
      let start = lexer.pos
      let token = lexer.next(cmap=true) catch {
        Invalid(message) | Unsupported(message) =>
          raise cmap_error(message, start, lexer.pos, "cmap")
      }
      match token {
        None => break
        Some(t) => {
          if tokens.length() >= 180_000 {
            raise cmap_error(
              "ToUnicode token limit exceeded",
              t.start,
              t.end,
              "cmap",
              unsupported=true,
            )
          }
          if t.kind is Name(name) && name == b"WMode" {
            // Some ToUnicode producers include WMode. Cardinality and
            // horizontal semantics are verified before using the map.
            match (lexer.next(cmap=true) catch { _ => None }) {
              Some(m) if m.kind is Integer(0) => {
                tokens.push(t)
                tokens.push(m)
              }
              _ =>
                raise cmap_error(
                  "only ToUnicode WMode 0 is supported",
                  t.start,
                  lexer.pos,
                  "cmap",
                  unsupported=true,
                )
            }
          } else {
            tokens.push(t)
          }
        }
      }
    }
    parse_cmap_tokens({ tokens, at: 0, size: data.length(), }, result)
  } catch {
    BadCMap(problem) => result.issues.push(problem)
  }
  result
}
