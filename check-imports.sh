#!/bin/sh
# check-imports.sh - Audit Foundation imports for right-sizing.
#
# Usage: ./check-imports.sh [path]
#
# For each file that imports Foundation, determines whether it could
# plausibly be narrowed to FoundationEssentials by checking for usage
# of internationalization-dependent types. Prints a per-file summary
# with a recommendation.

set -eu

ROOT="${1:-.}"

# Types that require FoundationInternationalization (i.e. ICU data).
# If any file uses these, it needs the full import; otherwise,
# FoundationEssentials is sufficient and saves binary size.
I18N_PATTERN='Locale\(|TimeZone\(|Calendar\(|DateFormatter|NumberFormatter|MeasurementFormatter|ListFormatter|RelativeDateTimeFormatter|ByteCountFormatStyle|FormatStyle|ParseStrategy|Measurement<|Locale\.Language'

# Types that require full Foundation (XML, Networking, or legacy NS* APIs).
FULL_PATTERN='URLSession|URLSessionTask|URLSessionDataTask|URLSessionDownloadTask|URLSessionUploadTask|XMLParser|XMLDocument|XMLElement|XMLNode|NSKeyedArchiver|NSKeyedUnarchiver|NotificationCenter|OperationQueue|Operation\(\)|BlockOperation|NSLock|NSRecursiveLock|NSCondition|NSConditionLock|Bundle\(|ProcessInfo\.processInfo\.'

count_essentials=0
count_i18n=0
count_full=0
count_no_foundation=0

find "$ROOT" -type f -name '*.swift' \
    ! -path '*/.build/*' \
    ! -path '*/.git/*' \
    ! -path '*/Carthage/*' \
    ! -path '*/Pods/*' \
    ! -path '*/DerivedData/*' | while IFS= read -r f; do

    if ! grep -qE '^import Foundation[[:space:]]*$' "$f" 2>/dev/null; then
        count_no_foundation=$((count_no_foundation + 1))
        continue
    fi

    if grep -qE "$FULL_PATTERN" "$f" 2>/dev/null; then
        printf '[FULL]       %s  (uses URLSession/XML/legacy NS*)\n' "$f"
        count_full=$((count_full + 1))
    elif grep -qE "$I18N_PATTERN" "$f" 2>/dev/null; then
        printf '[I18N]       %s  (uses Locale/Calendar/Formatter)\n' "$f"
        count_i18n=$((count_i18n + 1))
    else
        printf '[ESSENTIALS] %s  (candidate for FoundationEssentials)\n' "$f"
        count_essentials=$((count_essentials + 1))
    fi
done

printf '\n'
printf 'Summary:\n'
printf '  Candidates for FoundationEssentials (smallest dep):  see [ESSENTIALS] above\n'
printf '  Need FoundationInternationalization:                 see [I18N] above\n'
printf '  Need full Foundation:                                see [FULL] above\n'
printf '\n'
printf 'Files marked [ESSENTIALS] can have their imports changed to:\n'
printf '  import FoundationEssentials\n'
printf 'which skips the ICU data payload and reduces binary size on BSD.\n'
