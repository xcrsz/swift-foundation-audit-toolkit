#!/usr/bin/env swift
// url-parser-probe.swift - Test URL parsing for strings that behaved
// differently under the old permissive parser vs swift-foundation's
// stricter RFC 3986 conformance.
//
// Usage: swift url-parser-probe.swift
//
// Prints a table showing which URL strings currently parse and which
// do not. If you have a corpus of URLs from logs or persisted data,
// pipe them in via stdin instead:
//
//   cat urls.txt | swift url-parser-probe.swift --stdin

import Foundation

// URLs that have historically been accepted by the old NSURL-backed
// parser but may now fail under stricter conformance. Extend this set
// with strings from your own code or log files.
let suspicious: [String] = [
    // Spaces (should be percent-encoded).
    "http://example.com/path with spaces",
    "http://example.com/search?q=hello world",

    // Backslashes.
    "http://example.com\\path",

    // Unicode in host (needs IDN encoding).
    "http://例え.jp/path",
    "http://café.example.com/",

    // Brackets in path.
    "http://example.com/path[0]",

    // Pipe character.
    "http://example.com/a|b",

    // Caret.
    "http://example.com/a^b",

    // Double-slash after scheme.
    "http:example.com/path",

    // Empty host.
    "http:///path",

    // File URLs with spaces.
    "file:///Users/me/My Documents/file.txt",

    // Control characters (always invalid, but old parser sometimes accepted).
    "http://example.com/\u{0009}tab",

    // Percent-encoded that's valid.
    "http://example.com/path%20with%20encoded%20spaces",

    // Port boundary cases.
    "http://example.com:/path",
    "http://example.com:99999/path",

    // Query-only.
    "?just=a&query=string",

    // Fragment-only.
    "#fragment",
]

// Read candidates from stdin if requested.
var candidates = suspicious
if CommandLine.arguments.contains("--stdin") {
    candidates = []
    while let line = readLine() {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { candidates.append(trimmed) }
    }
}

var parsed = 0
var failed = 0
var suspicious_parsed = 0

print("")
print("=== URL parser probe ===")
print("")

for candidate in candidates {
    let displayLimit = 60
    let display = candidate.count > displayLimit
        ? String(candidate.prefix(displayLimit)) + "..."
        : candidate

    if let url = URL(string: candidate) {
        parsed += 1
        // Further check: does .path / .path() round-trip?
        let path = url.path
        let pathEncoded = url.path(percentEncoded: true)
        let pathDecoded = url.path(percentEncoded: false)
        let mismatch = pathEncoded != pathDecoded ? " (encoding varies)" : ""
        print("  [OK]   \(display)\(mismatch)")
        print("         .path=\(path)")
        if pathEncoded != path {
            print("         .path(pctEnc:true)=\(pathEncoded)")
            suspicious_parsed += 1
        }
    } else {
        failed += 1
        print("  [FAIL] \(display)")
    }
}

print("")
print("Parsed: \(parsed), Failed: \(failed), Path-encoding mismatches: \(suspicious_parsed)")
print("")
print("NOTE: failures are expected for genuinely malformed URLs. What")
print("matters is whether any of these strings appear in your persisted")
print("data, logs, or user input. If so, add defensive handling at the")
print("parse site.")
