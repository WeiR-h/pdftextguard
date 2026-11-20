///|
fn small_cmap(body : String) -> CMap {
  parse_cmap(
    @utf8.encode(
      "begincmap\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n" +
      body +
      "\nendcmap",
    ),
  )
}

///|
test "bfchar and both bfrange forms decode exact Unicode scalars" {
  let parsed = small_cmap(
    "1 beginbfchar\n<0001> <D83D DE00>\nendbfchar\n" +
    "2 beginbfrange\n<0002> <0003> <0061>\n" +
    "<0004> <0005> [<00660069> <00E9>]\nendbfrange",
  )
  assert_true(parsed.issues.is_empty())
  assert_eq(parsed.entries.get(1).unwrap().scalars, [0x1F600])
  assert_eq(parsed.entries.get(3).unwrap().scalars, [0x0062])
  assert_eq(parsed.entries.get(4).unwrap().scalars, [0x0066, 0x0069])
  assert_eq(parsed.entries.get(5).unwrap().rule.range_index, Some(1))
}

///|
test "count errors retain the declaration span and the actual entry count" {
  let parsed = small_cmap(
    "1 beginbfchar\n<0001> <0041>\n<0002> <0042>\nendbfchar",
  )
  let issue = parsed.issues[0]
  assert_eq(parsed.issues.length(), 1)
  assert_eq(issue.span.operator, "beginbfchar")
  assert_eq(issue.declared, Some(1))
  assert_eq(issue.observed, Some(2))
}

///|
test "duplicate codes and unpaired surrogates are syntax errors" {
  let conflict = small_cmap(
    "2 beginbfchar\n<0001> <0041>\n<0001> <0042>\nendbfchar",
  )
  assert_true(conflict.issues[0].message.contains("duplicate"))
  let bad_utf16 = small_cmap("1 beginbfchar\n<0001> <D800>\nendbfchar")
  assert_true(bad_utf16.issues[0].message.contains("UTF-16BE"))
}

///|
test "inherited CMap programs are outside coverage" {
  let parsed = small_cmap("/Parent-Map usecmap")
  assert_true(parsed.issues[0].unsupported)
}
