#!/usr/bin/env swift
// filemanager-bsd-probe.swift - Exercise FileManager behaviors that vary
// between Linux and FreeBSD under swift-foundation.
//
// Usage: swift filemanager-bsd-probe.swift
//
// Runs a battery of probes against a scratch directory, reports which
// behaviors work, which fail, and which produce results that differ
// from documented Darwin behavior. Prints a summary table suitable for
// attaching to a bug report or an internal audit document.

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct ProbeResult {
    let name: String
    let outcome: Outcome
    let detail: String

    enum Outcome: String {
        case pass = "PASS"
        case fail = "FAIL"
        case skip = "SKIP"
        case note = "NOTE"
    }
}

var results: [ProbeResult] = []

func probe(_ name: String, _ body: () throws -> (ProbeResult.Outcome, String)) {
    do {
        let (outcome, detail) = try body()
        results.append(ProbeResult(name: name, outcome: outcome, detail: detail))
    } catch {
        results.append(ProbeResult(
            name: name, outcome: .fail, detail: "threw: \(error)"))
    }
}

let fm = FileManager.default
let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("swift-foundation-probe-\(UUID().uuidString)")

try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: scratch) }

// --- Basic creation and attribute round-trip ---

probe("create and stat regular file") {
    let url = scratch.appendingPathComponent("regular")
    try Data("hello".utf8).write(to: url)
    let attrs = try fm.attributesOfItem(atPath: url.path)
    let size = attrs[.size] as? Int ?? -1
    return size == 5 ? (.pass, "size=5") : (.fail, "size=\(size)")
}

probe("POSIX permissions round-trip") {
    let url = scratch.appendingPathComponent("perms")
    try Data().write(to: url)
    try fm.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
    let attrs = try fm.attributesOfItem(atPath: url.path)
    let perms = (attrs[.posixPermissions] as? NSNumber)?.int16Value ?? -1
    return perms == 0o640
        ? (.pass, "0o640 preserved")
        : (.fail, "got \(String(perms, radix: 8))")
}

// --- Symlinks ---

probe("symlink creation and resolution") {
    let target = scratch.appendingPathComponent("target")
    let link = scratch.appendingPathComponent("link")
    try Data("x".utf8).write(to: target)
    try fm.createSymbolicLink(at: link, withDestinationURL: target)
    let dest = try fm.destinationOfSymbolicLink(atPath: link.path)
    return dest.hasSuffix("target")
        ? (.pass, "resolved to \(dest)")
        : (.fail, "unexpected: \(dest)")
}

// --- Extended attributes (platform-specific API) ---

probe("extended attributes") {
    let url = scratch.appendingPathComponent("xattr-test")
    try Data().write(to: url)

    let key = "user.probe"
    let value = "swift-foundation"
    let valueData = Array(value.utf8)

    #if canImport(Darwin)
    let setResult = url.path.withCString { path in
        setxattr(path, key, valueData, valueData.count, 0, 0)
    }
    #elseif os(FreeBSD)
    // FreeBSD uses extattr_set_file with a namespace + name split.
    // swift-foundation may or may not expose an xattr API here; this
    // probe is informational.
    return (.skip, "FreeBSD xattr uses extattr_* family; Foundation API not standardized")
    #else
    let setResult = url.path.withCString { path in
        setxattr(path, key, valueData, valueData.count, 0)
    }
    #endif

    #if !os(FreeBSD)
    guard setResult == 0 else {
        return (.note, "setxattr returned \(setResult), errno=\(errno) (may be unsupported fs)")
    }
    return (.pass, "set \(key)=\(value)")
    #endif
}

// --- File flags (chflags / st_flags) ---

probe("BSD file flags (chflags)") {
    #if os(FreeBSD) || canImport(Darwin)
    let url = scratch.appendingPathComponent("flags-test")
    try Data().write(to: url)
    // UF_NODUMP = 0x00000001, safe to set without root on BSD-family systems.
    let result = url.path.withCString { path in
        chflags(path, UInt32(0x00000001))
    }
    if result == 0 {
        return (.pass, "UF_NODUMP set")
    } else {
        return (.note, "chflags returned \(result), errno=\(errno)")
    }
    #else
    return (.skip, "chflags is BSD-family only")
    #endif
}

// --- Case-sensitivity behavior ---

probe("case-sensitive filesystem detection") {
    let lower = scratch.appendingPathComponent("casefile")
    let upper = scratch.appendingPathComponent("CASEFILE")
    try Data("lower".utf8).write(to: lower)
    do {
        try Data("upper".utf8).write(to: upper)
        let lowerData = try Data(contentsOf: lower)
        let upperData = try Data(contentsOf: upper)
        if lowerData != upperData {
            return (.pass, "case-sensitive (distinct files)")
        } else {
            return (.note, "case-insensitive (same file)")
        }
    } catch {
        return (.note, "could not create both cases: \(error)")
    }
}

// --- replaceItemAt (historically buggy on non-Darwin) ---

probe("FileManager.replaceItemAt") {
    let original = scratch.appendingPathComponent("original")
    let replacement = scratch.appendingPathComponent("replacement")
    try Data("original".utf8).write(to: original)
    try Data("replacement".utf8).write(to: replacement)

    do {
        _ = try fm.replaceItemAt(original, withItemAt: replacement)
        let content = try String(contentsOf: original, encoding: .utf8)
        return content == "replacement"
            ? (.pass, "content replaced correctly")
            : (.fail, "got: \(content)")
    } catch {
        return (.fail, "threw: \(error)")
    }
}

// --- contentsOfDirectory ordering ---

probe("contentsOfDirectory determinism") {
    let dir = scratch.appendingPathComponent("listing")
    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
    for n in ["zeta", "alpha", "mike"] {
        try Data().write(to: dir.appendingPathComponent(n))
    }
    let first = try fm.contentsOfDirectory(atPath: dir.path)
    let second = try fm.contentsOfDirectory(atPath: dir.path)
    return first == second
        ? (.note, "stable across calls: \(first)")
        : (.note, "non-deterministic ordering observed")
}

// --- Process spawning, signal inheritance ---

probe("Process posix_spawn basic") {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "echo probe"]
    let pipe = Pipe()
    p.standardOutput = pipe
    do {
        try p.run()
        p.waitUntilExit()
        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "probe"
            ? (.pass, "exit=\(p.terminationStatus)")
            : (.fail, "unexpected output: \(output)")
    } catch {
        return (.fail, "threw: \(error)")
    }
}

// --- Report ---

print("")
print("=== swift-foundation FileManager probe results ===")
#if canImport(Darwin)
print("platform: Darwin")
#elseif os(FreeBSD)
print("platform: FreeBSD")
#elseif os(Linux)
print("platform: Linux")
#else
print("platform: unknown")
#endif
print("scratch:  \(scratch.path)")
print("")

let nameWidth = max(results.map { $0.name.count }.max() ?? 30, 30)
for r in results {
    let padded = r.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
    print("  \(padded)  [\(r.outcome.rawValue)]  \(r.detail)")
}

let failed = results.filter { $0.outcome == .fail }.count
print("")
print("\(failed) failure(s), \(results.count) probe(s) total")
exit(failed == 0 ? 0 : 1)
