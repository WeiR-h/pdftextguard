///|
fn ContentScan::form_trace(self : ContentScan) -> Array[FormCall]? {
  if self.form_path.is_empty() {
    None
  } else {
    Some(self.form_path)
  }
}

///|
fn ContentScan::stream_site(self : ContentScan) -> StreamSite {
  {
    page: self.page,
    content_object: self.stream,
    stream_index: self.stream_index,
    decoded_offset: self.decoded_offset,
    form_path: self.form_trace(),
  }
}

///|
fn ContentScan::require_closed(self : ContentScan) -> Unit raise GuardError {
  if self.in_text || !self.stack.is_empty() || self.marked_depth != 0 {
    raise Invalid("unclosed text, graphics or marked-content state")
  }
}

///|
fn Document::form_matrix(
  self : Document,
  form : @syntax.PdfObject,
) -> Matrix raise GuardError {
  let nums = match field(form, b"Matrix") {
    None => return identity
    Some(value) => self.array(value).map(v => self.number(v))
  }
  if nums.length() != 6 {
    raise Invalid("Form Matrix must have six PDF numbers")
  }
  { a: nums[0], b: nums[1], c: nums[2], d: nums[3], x: nums[4], y: nums[5], }
}

///|
fn ContentScan::invoke_xobject(
  self : ContentScan,
  name : Bytes,
  operator_offset : Int32,
) -> Unit raise GuardError {
  if self.in_text {
    raise Invalid("Do inside a text object")
  }
  let raw = self.raw_resource(b"XObject", name)
  let object = self.doc.resolve(raw)
  if !(object is PdfStreamObject(_)) {
    raise Invalid("XObject must be a stream")
  }
  if field(object, b"OC") is Some(_) {
    raise Unsupported("optional-content XObject")
  }
  match self.doc.name(required_field(object, b"Subtype")) {
    b"Image" => ()
    b"Form" => self.draw_form(raw, object, name, operator_offset)
    _ => raise Unsupported("unsupported XObject subtype")
  }
}

///|
fn ContentScan::draw_form(
  self : ContentScan,
  raw : @syntax.PdfObject,
  object : @syntax.PdfObject,
  name : Bytes,
  operator_offset : Int32,
) -> Unit raise GuardError {
  let form_object = match self.doc.reference(raw) {
    Some(ref_) => ref_
    None => raise Invalid("Form XObject must refer to a stream object")
  }
  if self.form_path.any(call => call.form_object.number == form_object.number) {
    raise Unsupported("recursive Form XObject invocation")
  }
  if self.form_path.length() >= 16 || self.doc.form_calls >= 10000 {
    raise Unsupported("Form XObject expansion exceeds the call limit")
  }
  self.doc.form_calls += 1
  if field(object, b"Ref") is Some(_) || field(object, b"F") is Some(_) {
    raise Unsupported("Form references external content")
  }
  if field(object, b"FormType") is Some(value) && self.doc.int(value) != 1 {
    raise Unsupported("unsupported FormType")
  }
  let box = self.doc.array(required_field(object, b"BBox"))
  let bounds = box.map(value => self.doc.number(value))
  if bounds.length() != 4 || bounds[0] >= bounds[2] || bounds[1] >= bounds[3] {
    raise Invalid("Form BBox must be a nonempty rectangle")
  }
  let ctm = self.graphics.ctm.multiply(self.doc.form_matrix(object))
  guard_matrix(ctm)
  let scope = match field(object, b"Resources") {
    // Legacy forms without their own dictionary inherit from the page;
    // an explicit local dictionary replaces the page resources.
    None => self.page_scope
    Some(raw_resources) => {
      let resources = self.doc.resolve(raw_resources)
      if !(resources is PdfDictionary(_)) {
        raise Invalid("Form Resources must be a dictionary")
      }
      { resources, fonts: Map([]), }
    }
  }
  let call : FormCall = {
    resource: "/" + name_string(name),
    caller_object: self.stream,
    operator_offset,
    form_object,
  }
  let child : ContentScan = {
    ..self,
    scope,
    stack: [],
    graphics: { ..self.graphics, ctm, },
    in_text: false,
    text: identity,
    line: identity,
    marked_depth: 0,
    form_path: [..self.form_path, call],
  }
  errdefer {
    if self.nested_error.val is None {
      self.nested_error.val = Some(child.stream_site())
    }
  }
  child.read_stream(raw, self.stream_index)
  child.require_closed()
}
