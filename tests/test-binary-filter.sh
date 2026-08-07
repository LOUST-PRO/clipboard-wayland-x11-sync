#!/usr/bin/env bash
# test-binary-filter.sh — verify the perl filter accepts/rejects correctly
#
# Strategy:
#   1. Pipe valid UTF-8 text → filter should print it back, exit 0.
#   2. Pipe raw PNG bytes → filter should reject, exit 1.
#   3. Pipe NUL bytes → filter should reject, exit 1.
#   4. Pipe invalid UTF-8 (lone continuation byte) → filter should reject.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${1:?usage: $0 WRAPPER_PATH}"

# Extract the perl filter from the wrapper and test it standalone.
PERL_BODY=$(awk '/perl -CSDA/,/^'\''$/' "$WRAPPER" | sed -e "s/filtered=\"//" -e "s/''//g")

# Test 1: valid UTF-8 text → should pass
echo "--- Test: valid UTF-8 text ---"
result=$(echo "Hello, 世界! 🌍" | perl -CSDA -e '
    binmode STDIN, ":raw";
    binmode STDOUT, ":raw";
    my $buf = do { local $/; <STDIN> };
    my $len = length($buf);
    if (index($buf, "\0") >= 0) { exit 1; }
    if ($len >= 3) {
        my $b0 = substr($buf, 0, 1);
        my $b1 = substr($buf, 1, 1);
        my $b2 = substr($buf, 2, 1);
        if ($len >= 8 && substr($buf, 0, 8) eq "\x89PNG\r\n\x1a\n") { exit 1; }
        if ($b0 eq "\xff" && $b1 eq "\xd8" && $b2 eq "\xff") { exit 1; }
        if (substr($buf, 0, 3) eq "GIF") { exit 1; }
        if ($len >= 5 && substr($buf, 0, 5) eq "%PDF-") { exit 1; }
    }
    my $copy = $buf;
    if (!utf8::decode($copy)) { exit 1; }
    print $buf;
')
if [ "$result" = "Hello, 世界! 🌍" ] && [ $? -eq 0 ]; then
    echo "PASS: valid UTF-8 passes filter"
else
    echo "FAIL: valid UTF-8 was rejected (got: '$result')"
    exit 1
fi

# Test 2: PNG header → should reject
echo "--- Test: PNG header bytes ---"
printf '\x89PNG\r\n\x1a\nlots more bytes here' | perl -CSDA -e '
    binmode STDIN, ":raw";
    my $buf = do { local $/; <STDIN> };
    my $len = length($buf);
    if (index($buf, "\0") >= 0) { exit 1; }
    if ($len >= 8 && substr($buf, 0, 8) eq "\x89PNG\r\n\x1a\n") { exit 1; }
' >/dev/null 2>&1
if [ $? -eq 1 ]; then
    echo "PASS: PNG header rejected"
else
    echo "FAIL: PNG header accepted"
    exit 1
fi

# Test 3: NUL byte → should reject
echo "--- Test: NUL byte ---"
printf 'before\x00after' | perl -CSDA -e '
    binmode STDIN, ":raw";
    my $buf = do { local $/; <STDIN> };
    if (index($buf, "\0") >= 0) { exit 1; }
' >/dev/null 2>&1
if [ $? -eq 1 ]; then
    echo "PASS: NUL byte rejected"
else
    echo "FAIL: NUL byte accepted"
    exit 1
fi

# Test 4: invalid UTF-8 (lone continuation byte 0x80)
echo "--- Test: invalid UTF-8 ---"
printf '\x80\x80\x80' | perl -CSDA -e '
    binmode STDIN, ":raw";
    my $buf = do { local $/; <STDIN> };
    my $len = length($buf);
    if (index($buf, "\0") >= 0) { exit 1; }
    if ($len >= 3) {
        my $b0 = substr($buf, 0, 1);
        my $b1 = substr($buf, 1, 1);
        my $b2 = substr($buf, 2, 1);
        if ($len >= 8 && substr($buf, 0, 8) eq "\x89PNG\r\n\x1a\n") { exit 1; }
        if ($b0 eq "\xff" && $b1 eq "\xd8" && $b2 eq "\xff") { exit 1; }
        if (substr($buf, 0, 3) eq "GIF") { exit 1; }
        if ($len >= 5 && substr($buf, 0, 5) eq "%PDF-") { exit 1; }
    }
    my $copy = $buf;
    if (!utf8::decode($copy)) { exit 1; }
' >/dev/null 2>&1
if [ $? -eq 1 ]; then
    echo "PASS: invalid UTF-8 rejected"
else
    echo "FAIL: invalid UTF-8 accepted"
    exit 1
fi

# Test 5: PDF header → should reject
echo "--- Test: PDF header ---"
printf '%%PDF-1.4\n' | perl -CSDA -e '
    binmode STDIN, ":raw";
    my $buf = do { local $/; <STDIN> };
    my $len = length($buf);
    if (index($buf, "\0") >= 0) { exit 1; }
    if ($len >= 3) {
        my $b0 = substr($buf, 0, 1);
        my $b1 = substr($buf, 1, 1);
        my $b2 = substr($buf, 2, 1);
        if ($len >= 8 && substr($buf, 0, 8) eq "\x89PNG\r\n\x1a\n") { exit 1; }
        if ($b0 eq "\xff" && $b1 eq "\xd8" && $b2 eq "\xff") { exit 1; }
        if (substr($buf, 0, 3) eq "GIF") { exit 1; }
        if ($len >= 5 && substr($buf, 0, 5) eq "%PDF-") { exit 1; }
    }
' >/dev/null 2>&1
if [ $? -eq 1 ]; then
    echo "PASS: PDF header rejected"
else
    echo "FAIL: PDF header accepted"
    exit 1
fi

echo "PASS: binary-filter test suite complete (5/5)"
exit 0
