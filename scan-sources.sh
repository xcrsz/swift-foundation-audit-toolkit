#!/bin/sh
# scan-sources.sh - Static scan for swift-foundation migration risks
#
# Usage: ./scan-sources.sh [path]
# Exit codes: 0 = clean, 1 = findings present, 2 = usage error
#
# Scans Swift sources for patterns that are likely to behave differently
# under swift-foundation on non-Darwin platforms. Findings are categorized
# by severity: AUDIT (needs human review), WARN (probable issue),
# INFO (forward-path suggestion).

set -eu

ROOT="${1:-.}"
if [ ! -d "$ROOT" ]; then
    printf 'usage: %s [path]\n' "$0" >&2
    exit 2
fi

FINDINGS_FILE=$(mktemp)
trap 'rm -f "$FINDINGS_FILE"' EXIT
echo 0 > "$FINDINGS_FILE"

RED=$(printf '\033[31m')
YEL=$(printf '\033[33m')
CYA=$(printf '\033[36m')
RST=$(printf '\033[0m')

# Detect if output is a terminal; strip color if not.
if [ ! -t 1 ]; then
    RED=""; YEL=""; CYA=""; RST=""
fi

report() {
    sev="$1"; file="$2"; line="$3"; msg="$4"
    case "$sev" in
        AUDIT) color="$RED" ;;
        WARN)  color="$YEL" ;;
        INFO)  color="$CYA" ;;
    esac
    printf '%s[%s]%s %s:%s: %s\n' "$color" "$sev" "$RST" "$file" "$line" "$msg"
    n=$(cat "$FINDINGS_FILE")
    echo $((n + 1)) > "$FINDINGS_FILE"
}

# Find Swift sources, excluding common build/vendor directories.
find_swift_sources() {
    find "$ROOT" -type f -name '*.swift' \
        ! -path '*/.build/*' \
        ! -path '*/.git/*' \
        ! -path '*/Carthage/*' \
        ! -path '*/Pods/*' \
        ! -path '*/DerivedData/*' \
        ! -path '*/node_modules/*'
}

scan_pattern() {
    severity="$1"; pattern="$2"; message="$3"
    find_swift_sources | while IFS= read -r f; do
        grep -nE "$pattern" "$f" 2>/dev/null | while IFS=: read -r lineno content; do
            # Skip comment-only matches for most patterns to cut noise.
            trimmed=$(printf '%s' "$content" | sed 's/^[[:space:]]*//')
            case "$trimmed" in
                '//'*|'/*'*|'*'*) continue ;;
            esac
            report "$severity" "$f" "$lineno" "$message"
        done
    done
}

printf '%s=== swift-foundation migration scanner ===%s\n' "$CYA" "$RST"
printf 'scanning: %s\n\n' "$ROOT"

# Category 1: NSKeyedArchiver / NSKeyedUnarchiver persistence.
# These are the most dangerous for cross-platform behavior change.
printf '%s-- Archive persistence (highest audit priority) --%s\n' "$YEL" "$RST"
scan_pattern AUDIT \
    'NSKeyedArchiver|NSKeyedUnarchiver' \
    'NSKeyed archiver usage; archive format behavior may differ cross-platform. Add round-trip tests.'

scan_pattern AUDIT \
    'archivedData\(withRootObject:|unarchiveObject\(with:' \
    'Legacy archive API; strongly consider migrating to Codable + PropertyListEncoder/JSONEncoder.'

# Category 2: Objective-C runtime dependencies.
printf '\n%s-- Objective-C runtime dependencies --%s\n' "$YEL" "$RST"
scan_pattern WARN \
    '@objc(\(|[[:space:]]|$)' \
    '@objc attribute; dynamic dispatch not available on non-Darwin with swift-foundation.'

scan_pattern WARN \
    'class[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*NSObject' \
    'NSObject subclass; semantics differ under swift-corelibs-foundation compatibility layer.'

scan_pattern WARN \
    'addObserver\(.*forKeyPath:|removeObserver\(.*forKeyPath:' \
    'KVO on Foundation types; not supported for Swift-native value types.'

scan_pattern WARN \
    '\.perform\(#selector|NSSelectorFromString' \
    'Runtime selector dispatch; non-Darwin behavior is best-effort.'

# Category 3: Identity semantics on value types.
printf '\n%s-- Identity vs equality on value types --%s\n' "$YEL" "$RST"
scan_pattern WARN \
    '[[:space:](]+(locale|timeZone|calendar|formatter)[A-Za-z0-9]*[[:space:]]+===' \
    'Identity comparison on Foundation value type; use == instead.'

scan_pattern WARN \
    'NSLocale\(|NSTimeZone\(|NSCalendar\(' \
    'NS-prefixed Foundation type; prefer the Swift value type (Locale/TimeZone/Calendar).'

# Category 4: URL parsing behavior change.
printf '\n%s-- URL parsing (stricter RFC 3986 conformance) --%s\n' "$YEL" "$RST"
scan_pattern WARN \
    'URL\(string:[[:space:]]*"[^"]*[[:space:]\\]' \
    'URL string literal contains whitespace or backslash; may now fail to parse. Verify.'

scan_pattern INFO \
    '\.path([^(]|$)' \
    'URL.path without parens is deprecated in favor of URL.path(percentEncoded:). Review.'

# Category 5: JSON behavior edge cases worth testing.
printf '\n%s-- JSON coding (edge cases need golden-file regeneration) --%s\n' "$YEL" "$RST"
scan_pattern INFO \
    'JSONEncoder\(\)|JSONDecoder\(\)' \
    'JSON coder usage; if output is persisted or compared byte-exact, regenerate golden files.'

scan_pattern WARN \
    'nonConformingFloatEncodingStrategy|nonConformingFloatDecodingStrategy' \
    'Non-conforming float strategy; behavior around NaN/infinity has been tightened.'

# Category 6: Date formatting on non-Darwin.
printf '\n%s-- Date/locale formatting (ICU source changed) --%s\n' "$YEL" "$RST"
scan_pattern INFO \
    'DateFormatter\(\)' \
    'Legacy DateFormatter; consider migration to Date.FormatStyle / ParseStrategy.'

scan_pattern WARN \
    'Locale\(identifier:|TimeZone\(identifier:' \
    'Locale/TimeZone identifier usage; verify behavior matches on FreeBSD (bundled ICU vs system ICU).'

# Category 7: Process and FileManager BSD-specific concerns.
printf '\n%s-- Process / FileManager (BSD-specific behavior) --%s\n' "$YEL" "$RST"
scan_pattern WARN \
    'Process\(\)|\.launchPath[[:space:]]*=|\.executableURL[[:space:]]*=' \
    'Process spawning; signal/FD inheritance behavior under posix_spawn may differ. Test on BSD.'

scan_pattern WARN \
    'FileManager.*setAttributes|FileManager.*attributesOfItem' \
    'FileManager attribute API; BSD-specific flags (chflags, ACLs) need validation.'

scan_pattern WARN \
    'FileManager.*extendedAttribute|getxattr|setxattr' \
    'Extended attribute usage; verify syntax matches FreeBSD extattr_* family.'

# Category 8: Forward-path suggestions.
printf '\n%s-- Forward-path suggestions --%s\n' "$CYA" "$RST"
find_swift_sources | while IFS= read -r f; do
    if grep -q '^import Foundation[[:space:]]*$' "$f" 2>/dev/null; then
        # Check if it actually uses internationalization.
        if ! grep -qE 'Locale|TimeZone|Calendar\(|DateFormatter|NumberFormatter|FormatStyle|Measurement' "$f" 2>/dev/null; then
            report INFO "$f" "1" "Imports Foundation but no i18n usage detected; consider FoundationEssentials."
        fi
    fi
done

FINDINGS=$(cat "$FINDINGS_FILE")
printf '\n%s=== %d finding(s) ===%s\n' "$CYA" "$FINDINGS" "$RST"

if [ "$FINDINGS" -gt 0 ]; then
    exit 1
fi
exit 0
