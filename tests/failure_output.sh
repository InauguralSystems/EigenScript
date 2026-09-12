# Display only: consume an already captured failure, never decide its verdict.
# Read all input so an early reader exit cannot break the producer's pipeline.
eigs_failure_output() {
    LC_ALL=C awk '
    {
        tail[(NR - 1) % 20] = $0
        if ($0 ~ /^[[:space:]]*(FAIL:|MISMATCH:|AssertionError)/) {
            matches++
            if (shown < 5) assertions[++shown] = $0
        }
    }
    END {
        print "  --- assertion excerpts (first 5; complete lines) ---"
        for (i = 1; i <= shown; i++) print assertions[i]
        print "  --- captured tail (last 20 complete lines) ---"
        first = NR > 20 ? NR - 19 : 1
        for (i = first; i <= NR; i++) print tail[(i - 1) % 20]
        printf "  --- captured %d lines; %d assertion matches; displayed %d assertions ---\n", NR, matches, shown
    }'
}
