- Floating arithmetic now retains IEEE NaNs and infinities instead of clamping
to 1e308 or replacing NaN with zero. Float division and modulo by zero, sqrt
of a negative number, and log of zero produce IEEE results by default;
EIGS_STRICT=1 opts into non-finite result errors. Integer zero-division still
raises. Numeric ordering follows R22-1: -0.0 precedes the stable class of
integer 0 and +0.0, and NaNs sort last. Min/max propagate NaN, and structural
equality treats a stored NaN as unequal to itself without mutating it.
