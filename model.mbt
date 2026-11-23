///|
pub let version : String = "0.0.11"

///|
#derive(@json.ToJson)
pub struct ObjectRef {
  number : Int32
  generation : Int32
}

///|
pub extend ObjectRef with @json.ToJson::{to_json}

///|
#derive(@json.ToJson)
pub struct FormCall {
  resource : String
  caller_object : ObjectRef?
  operator_offset : Int32
  form_object : ObjectRef
}

///|
pub extend FormCall with @json.ToJson::{to_json}

///|
#derive(@json.ToJson)
pub struct UseSite {
  page : Int32
  content_object : ObjectRef?
  stream_index : Int32
  operator : String
  operator_offset : Int32
  string_offset : Int32
  byte_index : Int32
  font_resource : String
  font_object : ObjectRef?
  descendant_object : ObjectRef?
  font_file_object : ObjectRef?
  cmap_object : ObjectRef?
  code : String
  cid : Int32
  gid : Int32
  origin_x : Double
  origin_y : Double
  display_origin_x : Double?
  display_origin_y : Double?
  unicode : Array[String]?
  rule : CMapSpan?
  form_path : Array[FormCall]?
}

///|
pub extend UseSite with @json.ToJson::{to_json}

///|
#derive(@json.ToJson)
pub struct StreamSite {
  page : Int32
  content_object : ObjectRef?
  stream_index : Int32
  decoded_offset : Int32?
  form_path : Array[FormCall]?
}

///|
pub extend StreamSite with @json.ToJson::{to_json}

///|
#derive(@json.ToJson)
pub struct CMapDiagnostic {
  font_resource : String
  font_object : ObjectRef?
  cmap_object : ObjectRef?
  span : CMapSpan
  declared : Int32?
  observed : Int32?
}

///|
pub extend CMapDiagnostic with @json.ToJson::{to_json}

///|
#derive(@json.ToJson)
pub struct Diagnostic {
  code : String
  side : String
  message : String
  page : Int32?
  stream : StreamSite?
  baseline : UseSite?
  candidate : UseSite?
  cmap : CMapDiagnostic?
}

///|
pub extend Diagnostic with @json.ToJson::{to_json}

///|
#derive(@json.ToJson)
pub struct Report {
  schema_version : Int32
  tool_version : String
  outcome : String
  exit_code : Int32
  coverage : String
  baseline_pages : Int32
  candidate_pages : Int32
  baseline_glyphs : Int32
  candidate_glyphs : Int32
  aligned_glyphs : Int32
  position_aligned_pages : Int32
  compared_glyphs : Int32
  mismatched_occurrences : Int32
  diagnostics_omitted : Int32
  diagnostics : Array[Diagnostic]
}

///|
pub extend Report with @json.ToJson::{to_json}

///|
fn note(
  code : String,
  side : String,
  message : String,
  page? : Int32,
) -> Diagnostic {
  {
    code,
    side,
    message,
    page,
    stream: None,
    baseline: None,
    candidate: None,
    cmap: None,
  }
}

///|
fn guard_message(error : GuardError) -> String {
  match error {
    Unsupported(message) => message
    Invalid(message) => message
  }
}

///|
fn guard_code(error : GuardError) -> String {
  match error {
    Unsupported(_) => "unsupported"
    Invalid(_) => "invalid_input"
  }
}

///|
fn unicode_labels(values : Array[Int32]) -> Array[String] {
  values.map(value => "U+" + display_hex(value, 4))
}

///|
priv struct Matrix {
  a : Double
  b : Double
  c : Double
  d : Double
  x : Double
  y : Double
}

///|
let identity : Matrix = { a: 1, b: 0, c: 0, d: 1, x: 0, y: 0, }

///|
fn Matrix::multiply(left : Matrix, right : Matrix) -> Matrix {
  {
    a: left.a * right.a + left.c * right.b,
    b: left.b * right.a + left.d * right.b,
    c: left.a * right.c + left.c * right.d,
    d: left.b * right.c + left.d * right.d,
    x: left.a * right.x + left.c * right.y + left.x,
    y: left.b * right.x + left.d * right.y + left.y,
  }
}

///|
fn Matrix::translate(self : Matrix, x : Double, y : Double) -> Matrix {
  {
    ..self,
    x: self.a * x + self.c * y + self.x,
    y: self.b * x + self.d * y + self.y,
  }
}

///|
fn near(a : Double, b : Double) -> Bool {
  (a - b).abs() <= 0.01
}

///|
fn same_pose(a : Matrix, b : Matrix) -> Bool {
  near(a.a, b.a) &&
  near(a.b, b.b) &&
  near(a.c, b.c) &&
  near(a.d, b.d) &&
  near(a.x, b.x) &&
  near(a.y, b.y)
}

///|
fn guard_matrix(matrix : Matrix) -> Unit raise GuardError {
  for v in [matrix.a, matrix.b, matrix.c, matrix.d, matrix.x, matrix.y] {
    if !v.is_finite() || v.abs() > 1_000_000.0 {
      raise Unsupported("text coordinates exceed the supported range")
    }
  }
}
