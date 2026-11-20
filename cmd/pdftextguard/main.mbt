///|
#external
priv type FileRead

///|
extern "js" fn read_file(path : String) -> FileRead =
  #| (path) => {
  #|   const fs = process.getBuiltinModule("fs");
  #|   try {
  #|     if (!fs.statSync(path).isFile()) return {error: "input must be a regular file"};
  #|     const fd = fs.openSync(path, "r");
  #|     try {
  #|       const info = fs.fstatSync(fd);
  #|       if (!info.isFile() || info.size > 32 * 1024 * 1024) {
  #|         return {error: "input must be a regular PDF of at most 32 MiB"};
  #|       }
  #|       const bytes = new Uint8Array(info.size);
  #|       let at = 0;
  #|       while (at < bytes.length) {
  #|         const n = fs.readSync(fd, bytes, at, bytes.length - at, at);
  #|         if (!n) return {error: "input changed while it was being read"};
  #|         at += n;
  #|       }
  #|       const after = fs.fstatSync(fd);
  #|       if (after.size !== info.size || after.mtimeMs !== info.mtimeMs) {
  #|         return {error: "input changed while it was being read"};
  #|       }
  #|       return {error: "", bytes};
  #|     } finally { fs.closeSync(fd); }
  #|   } catch (err) { return {error: "cannot read input file: " + (err.code || err.name)}; }
  #| }

///|
extern "js" fn FileRead::error(self : FileRead) -> String =
  #| file => file.error

///|
extern "js" fn FileRead::bytes(self : FileRead) -> Bytes =
  #| file => file.bytes

///|
extern "js" fn exit_status(code : Int32) -> Unit =
  #| code => { process.exitCode = code; }

///|
fn usage() -> String {
  "PDFTextGuard v\{@guard.version}\nUsage: pdftextguard check <baseline.pdf> <candidate.pdf> [--json]\nExit: 0 pass, 1 regression, 2 inconclusive or input error."
}

///|
fn ref_label(object : @guard.ObjectRef?) -> String {
  match object {
    Some(obj) => "\{obj.number} \{obj.generation} R"
    None => "direct"
  }
}

///|
fn print_site(label : String, site : @guard.UseSite) -> Unit {
  let rule = match site.rule {
    Some(rule) =>
      "\{rule.operator} bytes \{rule.decoded_offset}..\{rule.decoded_end}"
    None => "no explicit rule"
  }
  let unicode = match site.unicode {
    Some(values) => @json.to_json(values).stringify()
    None => "unmapped"
  }
  println(
    "  \{label}: page \{site.page}, \{site.operator} @\{site.operator_offset} in \{ref_label(site.content_object)}, font \{ref_label(site.font_object)}, cmap \{ref_label(site.cmap_object)}, <\{site.code}> GID \{site.gid} -> \{unicode} (\{rule})",
  )
  if site.form_path is Some(path) {
    for call in path {
      println(
        "    via \{call.resource} Do @\{call.operator_offset} in \{ref_label(call.caller_object)} -> \{ref_label(Some(call.form_object))}",
      )
    }
  }
}

///|
fn emit(report : @guard.Report, json : Bool) -> Unit {
  if json {
    println(@json.to_json(report).stringify(indent=2))
  } else {
    println(
      "\{report.outcome.to_upper()} | \{report.aligned_glyphs} aligned | \{report.compared_glyphs} checked | \{report.mismatched_occurrences} mapping changes",
    )
    for item in report.diagnostics {
      println("* \{item.code} [\{item.side}] \{item.message}")
      if item.cmap is Some(detail) {
        let location = "  CMap \{ref_label(detail.cmap_object)}, \{detail.span.operator} @\{detail.span.decoded_offset}"
        match (detail.declared, detail.observed) {
          (Some(declared), Some(observed)) =>
            println("\{location}: declared \{declared}, observed \{observed}")
          _ => println(location)
        }
      }
      if item.stream is Some(stream) {
        println(
          "  page \{stream.page}, content stream \{stream.stream_index + 1}, object \{ref_label(stream.content_object)}",
        )
      }
      if item.baseline is Some(site) {
        print_site("baseline", site)
      }
      if item.candidate is Some(site) {
        print_site("candidate", site)
      }
    }
    if report.diagnostics_omitted > 0 {
      println("  \{report.diagnostics_omitted} additional diagnostics omitted")
    }
  }
  exit_status(report.exit_code)
}

///|
fn main {
  let argv = @env.args()
  let args = argv[2:]
  if args.length() == 0 ||
    (args.length() == 1 && (args[0] == "--help" || args[0] == "-h")) {
    println(usage())
    return
  }
  if args.length() == 1 && args[0] == "--version" {
    println("PDFTextGuard v\{@guard.version}")
    return
  }
  let output_json = args.length() == 4 && args[3] == "--json"
  if (args.length() != 3 && !output_json) || args[0] != "check" {
    emit(
      @guard.input_error("command", usage()),
      args.any(arg => arg == "--json"),
    )
    return
  }
  let baseline = read_file(args[1])
  if !baseline.error().is_empty() {
    emit(@guard.input_error("baseline", baseline.error()), output_json)
    return
  }
  let candidate = read_file(args[2])
  if !candidate.error().is_empty() {
    emit(@guard.input_error("candidate", candidate.error()), output_json)
    return
  }
  emit(@guard.check(baseline.bytes(), candidate.bytes()), output_json)
}
