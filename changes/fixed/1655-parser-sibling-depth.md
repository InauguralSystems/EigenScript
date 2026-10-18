- Flat list and dictionary literals no longer exhaust the parser nesting limit
  by accumulating operator-chain depth across sibling elements. Deeply nested
  expressions and long operator chains remain bounded by the existing limit.
