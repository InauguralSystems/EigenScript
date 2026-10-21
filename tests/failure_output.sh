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
        # Match colored reports without changing their captured lines. TSan
        # uses WARNING for races; ASan and LSan use ERROR (optionally pid-prefixed).
        clean = $0
        gsub(/\033\[[0-9;]*m/, "", clean)
        if (!san_first && clean ~ /^[[:space:]]*(==[0-9]+==)?[[:space:]]*(ERROR|WARNING|FATAL): (AddressSanitizer|LeakSanitizer|ThreadSanitizer)(:|[[:space:]])/)
            san_first = NR
        # Bound malformed or frame-free reports too, while still reading stdin.
        if (san_first && head_count < 40 && frames < 8) {
            head[++head_count] = $0
            san_last = NR
            if (clean ~ /^[[:space:]]*#[0-9]+[[:space:]]/) frames++
        }
    }
    END {
        print "  --- assertion excerpts (first 5; complete lines) ---"
        for (i = 1; i <= shown; i++) print assertions[i]
        first = NR > 20 ? NR - 19 : 1
        # A report already wholly in the tail needs no extra window. Otherwise
        # print its head, count the gap, and suppress any overlapping tail lines.
        if (san_first && san_first < first) {
            print "  --- sanitizer excerpt (first 8 stack frames; at most 40 complete lines) ---"
            for (i = 1; i <= head_count; i++) print head[i]
            elided = first - san_last - 1
            printf "  --- %d captured lines elided ---\n", (elided > 0 ? elided : 0)
            if (first <= san_last) first = san_last + 1
        }
        print "  --- captured tail (last 20 complete lines) ---"
        for (i = first; i <= NR; i++) print tail[(i - 1) % 20]
        printf "  --- captured %d lines; %d assertion matches; displayed %d assertions ---\n", NR, matches, shown
    }'
}
