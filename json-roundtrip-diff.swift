#!/usr/bin/env swift
// json-rountrip-diff.swift - Detect JSON encoder/decoder behavior changes
//
// Usage:
//   swift json-roundtrip-diff.swift generate <output-dir>
//       Generate golden output files from the current Foundation.
//   swift json-roundtrip-diff.swift verify <golden-dir>
//       Compare current Foundation output against previously-generated
//       golden files and report byte-level differences.
//
// Run 'generate' once on a known-good build (e.g. Darwin with the pre-
// swift-foundation toolchain, or a known-working BSD build). Check the
// resulting files into the repo. Then run 'verify' in CI on target
// platforms. Any diff is a signal worth looking at.

import Foundation

struct TestCase: Codable, Equatable {
    let name: String
    let payload: [String: CodableValue]
}

// A recursive Codable value so we can build heterogeneous test payloads
// without per-case types.
indirect enum CodableValue: Codable, Equatable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case null
    case array([CodableValue])
    case object([String: CodableValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([CodableValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: CodableValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(
            in: c, debugDescription: "unknown value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// Test payloads targeting known behavior-divergence points between the
// old CoreFoundation-backed JSONEncoder and swift-foundation's pure-Swift
// replacement. Extend this list based on what your code actually uses.
let cases: [(String, [String: CodableValue])] = [
    ("simple_strings", [
        "ascii": .string("hello"),
        "unicode": .string("héllo wörld"),
        "emoji": .string("🌍🚀"),
        "empty": .string(""),
    ]),
    ("integer_boundaries", [
        "zero": .int(0),
        "max_int64": .int(.max),
        "min_int64": .int(.min),
        "near_max_safe": .int(9_007_199_254_740_992),
    ]),
    ("doubles", [
        "zero": .double(0.0),
        "neg_zero": .double(-0.0),
        "pi": .double(.pi),
        "small": .double(1e-300),
        "large": .double(1e300),
        "one_third": .double(1.0 / 3.0),
    ]),
    ("key_ordering", [
        "zebra": .int(1),
        "alpha": .int(2),
        "mike": .int(3),
        "charlie": .int(4),
    ]),
    ("nested_structures", [
        "array_of_objects": .array([
            .object(["k": .string("v1")]),
            .object(["k": .string("v2")]),
        ]),
        "object_with_nulls": .object([
            "present": .string("here"),
            "absent": .null,
        ]),
    ]),
    ("special_characters", [
        "quote": .string("she said \"hi\""),
        "backslash": .string("path\\to\\file"),
        "newline": .string("line1\nline2"),
        "tab": .string("a\tb"),
        "solidus": .string("http://example.com/path"),
    ]),
]

// Configurations that commonly differ in output across implementations.
let configurations: [(String, (JSONEncoder) -> Void)] = [
    ("default", { _ in }),
    ("sorted_keys", { e in e.outputFormatting = [.sortedKeys] }),
    ("pretty", { e in e.outputFormatting = [.prettyPrinted] }),
    ("pretty_sorted", { e in e.outputFormatting = [.prettyPrinted, .sortedKeys] }),
]

func encode(_ payload: [String: CodableValue], config: (JSONEncoder) -> Void) throws -> Data {
    let encoder = JSONEncoder()
    config(encoder)
    return try encoder.encode(payload)
}

enum Mode { case generate, verify }

func run(mode: Mode, directory: String) {
    let fm = FileManager.default
    let dirURL = URL(fileURLWithPath: directory)

    if mode == .generate {
        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
    }

    var diffs = 0
    var generated = 0

    for (caseName, payload) in cases {
        for (configName, config) in configurations {
            let filename = "\(caseName).\(configName).json"
            let fileURL = dirURL.appendingPathComponent(filename)

            let data: Data
            do {
                data = try encode(payload, config: config)
            } catch {
                print("ENCODE FAIL: \(filename): \(error)")
                diffs += 1
                continue
            }

            switch mode {
            case .generate:
                do {
                    try data.write(to: fileURL)
                    generated += 1
                } catch {
                    print("WRITE FAIL: \(filename): \(error)")
                }

            case .verify:
                guard let expected = try? Data(contentsOf: fileURL) else {
                    print("MISSING: \(filename)")
                    diffs += 1
                    continue
                }
                if data == expected {
                    // silent on match
                } else {
                    print("DIFF: \(filename)")
                    print("  expected: \(String(data: expected, encoding: .utf8) ?? "<binary>")")
                    print("  actual:   \(String(data: data, encoding: .utf8) ?? "<binary>")")
                    diffs += 1
                }
            }
        }
    }

    switch mode {
    case .generate:
        print("Generated \(generated) golden files in \(directory)")
    case .verify:
        if diffs == 0 {
            print("OK: all \(cases.count * configurations.count) cases match")
            exit(0)
        } else {
            print("FAIL: \(diffs) difference(s) detected")
            exit(1)
        }
    }
}

let args = CommandLine.arguments
guard args.count == 3 else {
    print("usage: \(args[0]) {generate|verify} <directory>")
    exit(2)
}

switch args[1] {
case "generate": run(mode: .generate, directory: args[2])
case "verify":   run(mode: .verify, directory: args[2])
default:
    print("unknown mode: \(args[1])")
    exit(2)
}
