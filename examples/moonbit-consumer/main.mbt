///|
extern "js" fn set_exit_code(code : Int32) -> Unit =
  #| code => { process.exitCode = code; }

///|
fn compare_files(baseline : String, candidate : String) -> @guard.Report {
  let old = @fs.read_file_to_bytes(baseline) catch {
    _ => return @guard.input_error("baseline", "cannot read baseline PDF")
  }
  let current = @fs.read_file_to_bytes(candidate) catch {
    _ => return @guard.input_error("candidate", "cannot read candidate PDF")
  }
  @guard.check(old, current)
}

///|
fn main {
  let argv = @env.args()
  let report = if argv.length() == 4 {
    compare_files(argv[2], argv[3])
  } else {
    @guard.input_error(
      "command",
      "usage: moon run --target js . -- BASELINE.pdf CANDIDATE.pdf",
    )
  }
  println(@json.to_json(report).stringify(indent=2))
  set_exit_code(report.exit_code)
}
