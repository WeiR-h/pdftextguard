///|
priv struct PageFrame {
  bounds : Array[Double]
  transform : Matrix?
  unit : Double
}

///|
fn Document::page_box(
  self : Document,
  value : @syntax.PdfObject,
) -> Array[Double] raise GuardError {
  let coords = self.array(value).map(n => self.number(n))
  if coords.length() != 4 || coords[0] >= coords[2] || coords[1] >= coords[3] {
    raise Invalid("inverted, empty or malformed PDF page box")
  }
  coords
}

///|
fn Document::page_rotation(
  self : Document,
  page : @syntax.PdfObject,
) -> Int32 raise GuardError {
  // Inspect the inherited value ourselves to distinguish malformed rotations
  // from no rotation. Valid values are integral multiples of 90 degrees.
  let mut node = page
  let seen : Map[Int32, Bool] = Map([])
  for _ in 0..<128 {
    if field(node, b"Rotate") is Some(value) {
      match self.resolve(value) {
        PdfNull => ()
        PdfInteger(n) if n % 90 == 0 => return (n % 360 + 360) % 360
        _ => raise Invalid("page Rotate must be an integer multiple of 90")
      }
    }
    match field(node, b"Parent") {
      None => return 0
      Some(PdfIndirect(number) as ref_) => {
        if seen.contains(number) {
          raise Invalid("cycle in page rotation inheritance")
        }
        seen.set(number, true)
        node = self.resolve(ref_)
      }
      _ => raise Invalid("malformed page Parent reference")
    }
  }
  raise Unsupported("page rotation inheritance exceeds the depth limit")
}

///|
fn normalize_page(
  media : Array[Double],
  crop : Array[Double],
  rotation : Int32,
  unit : Double,
) -> PageFrame raise GuardError {
  if !(unit > 0) {
    raise Invalid("UserUnit must be positive")
  }
  if unit > 75000 {
    raise Unsupported("page UserUnit exceeds the supported range")
  }
  // CropBox is limited by MediaBox. Normalize the lower left of the
  // displayed page to (0, 0) in points, keeping the y axis upward.
  let min_x = crop[0].max(media[0])
  let min_y = crop[1].max(media[1])
  let max_x = crop[2].min(media[2])
  let max_y = crop[3].min(media[3])
  if min_x >= max_x || min_y >= max_y {
    raise Invalid("CropBox and MediaBox do not intersect")
  }
  let frame = match rotation {
    0 => { ..identity, x: -min_x, y: -min_y, }
    90 => { a: 0, b: -1, c: 1, d: 0, x: -min_y, y: max_x, }
    180 => { a: -1, b: 0, c: 0, d: -1, x: max_x, y: max_y, }
    270 => { a: 0, b: 1, c: -1, d: 0, x: max_y, y: -min_x, }
    _ => raise Invalid("unsupported page rotation")
  }
  let transform = if unit == 1.0 {
    frame
  } else {
    { ..identity, a: unit, d: unit, }.multiply(frame)
  }
  guard_matrix(transform)
  let p0 = transform.translate(media[0], media[1])
  let p1 = transform.translate(media[2], media[3])
  let w = (max_x - min_x) * unit
  let h = (max_y - min_y) * unit
  let (display_w, display_h) = if rotation == 90 || rotation == 270 {
    (h, w)
  } else {
    (w, h)
  }
  if display_w > 1_000_000.0 || display_h > 1_000_000.0 {
    raise Unsupported("displayed page exceeds the coordinate limit")
  }
  {
    bounds: [
      p0.x.min(p1.x),
      p0.y.min(p1.y),
      p0.x.max(p1.x),
      p0.y.max(p1.y),
      0,
      0,
      display_w,
      display_h,
    ],
    transform: if rotation == 0 && unit == 1.0 && min_x == 0 && min_y == 0 {
      None
    } else {
      Some(transform)
    },
    unit,
  }
}
