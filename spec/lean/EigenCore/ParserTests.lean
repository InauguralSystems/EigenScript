import EigenCore.Parser

namespace EigenCore.Tests

private def parses (source : String) : Bool :=
  match parse source with
  | .ok _ => true
  | .error _ => false

example : parses "f of [m - 1]" := by native_decide
example : parses "f of [[1, 2], g of [x]]" := by native_decide
example : parses "print of (f of [1])" := by native_decide
example : parses "print of (1 < 2) + 1" := by native_decide
example : parses "print of [1 < 2] == [true]" := by native_decide
example : parses "print of \"a < b\" == \"a < b\"" := by native_decide

end EigenCore.Tests
