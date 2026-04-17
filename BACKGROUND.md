## Source compatibility: mostly a non-event

The headline is that Apple and the Foundation Workgroup have worked hard to make this a drop-in replacement at the source level. For non-Darwin code, no adoption is required; if you `import Foundation`, you are already using swift-foundation. Most existing code simply recompiles and runs.

That said, "mostly" is doing real work in that sentence. The places where problems surface are predictable:

**Code that depended on Objective-C runtime behavior.** Anything using `NSObject` subclassing, `@objc` dynamic dispatch, KVO, `NSKeyedArchiver` with archived class names, or runtime introspection of Foundation types will have compatibility edges on non-Darwin platforms. swift-corelibs-foundation still provides these as a best-effort compatibility layer, but the new Swift-native types underneath are value types or structs, not Objective-C classes. Code that relied on reference semantics for a `Calendar` or `Locale`, for example, passing it around expecting shared mutable state, is already broken, though it was arguably broken in concept before.

**Code using `NSKeyedArchiver` / `NSKeyedUnarchiver` for persistence.** This is the one to audit. The archive format is tied to Objective-C class names and runtime layout. Cross-platform archives produced on Darwin and read on Linux or BSD with corelibs-foundation were already fragile; with swift-foundation underneath on Darwin, behavior in edge cases (especially around `NSNumber`, `NSDate`, dictionary ordering) may diverge subtly from what older archives expect. If we have any persisted NSKeyed archives in our tooling, they need round-trip tests on the target platform.

**Code assuming specific Calendar / TimeZone / Locale identity semantics.** The new implementations are value types with proper Swift semantics. Locale, TimeZone and Calendar no longer require bridging from Objective-C, and common operations like getting a fixed Locale are an order of magnitude faster. But code that did `locale1 === locale2` pointer comparisons, or relied on `NSLocale` subclass hooks, will not behave the same way. In practice this is rare, but it exists in older Cocoa code.

## Behavioral parity: the real audit target

Identical API, slightly different behavior is the category that causes production bugs. Areas worth checking:

**JSON encoding/decoding.** The new `JSONEncoder` and `JSONDecoder` are clean-slate Swift implementations. In the overwhelming majority of cases they produce and accept the same output, but edge cases differ: handling of `Float.nan` and infinity with different `nonConformingFloatEncodingStrategy` settings, ordering of keys when `.sortedKeys` is not set (the new implementation is more deterministic but not identical to the old), decoding of very large integers near `Int64.max`, and precision of `Double` round-tripping. Anything that relies on byte-identical JSON output between platforms or between Swift versions needs regeneration of golden files and a diff pass.

**Date formatting and parsing.** The new `FormatStyle` / `ParseStrategy` APIs are the forward path; the old `DateFormatter` is still present but wraps different internals depending on platform. Locale-sensitive formatting is where divergence shows up, particularly for non-Gregorian calendars, for locales with recent CLDR data changes, and for calendar arithmetic across DST boundaries. On BSD this is doubly interesting because FoundationInternationalization brings its own ICU (via swift-foundation-icu) rather than inheriting the system's. That means our formatted output will match macOS and Linux swift-foundation output, but may diverge from whatever the host FreeBSD system ICU produces for other tools.

**URL parsing and resolution.** `URL` was rewritten to conform more strictly to RFC 3986. Code that accepted malformed URLs under the old permissive parser may now get `nil` back. The `URL.path` vs `URL.path()` split (with the parameter controlling percent-decoding) is a genuine API addition but also a behavior shift; code using the old non-parameterized `path` property gets a deprecation path, not a silent change, but the deprecation lands in production eventually.

**FileManager on BSD specifically.** This is where I'd spend the most audit time for our work. FileManager on swift-foundation is a Swift-native reimplementation that calls through to POSIX directly rather than going through CoreFoundation's file abstractions. Behaviors that vary between Linux and FreeBSD, such as extended attributes, file flags (`chflags`), ACLs, the finer points of `statfs` vs `statvfs`, and case-sensitivity handling on case-insensitive filesystems, are places where the Swift implementation may have been tuned for Linux first and BSD second. For any file-intensive GhostBSD utility, I'd build a small test matrix exercising these paths.

**Process and subprocess handling.** `Process` (née `NSTask`) on the new stack uses `posix_spawn` paths with different fallback behavior than the old CoreFoundation-backed version. Signal handling, pipe buffering, and environment inheritance have all been audited and in some cases changed. Code that shelled out to subprocesses with specific signal or FD inheritance expectations needs revalidation.

## Performance: generally a win, with caveats

The performance story is positive and real, not just marketing. Common tasks like getting a fixed Locale are an order of magnitude faster for Swift clients, and Calendar's date calculations see over 20% improvement in some benchmarks by taking advantage of Swift's value semantics to avoid intermediate allocations. JSON encoding/decoding is substantially faster than the old Objective-C-bridged path. String operations that previously round-tripped through `NSString` no longer do.

The caveat: code that was written around the old performance profile, for example caching a `DateFormatter` aggressively because creating one was expensive, may now be caching something that's cheap to create, at the cost of thread-safety complexity. Worth a look on a hot-path basis, not a blanket rewrite.

## Binary size

For any of our utilities that link Foundation, the FoundationEssentials / FoundationInternationalization split is a genuine benefit. A small tool that needs `URL`, `Data`, `JSONDecoder`, and `FileManager` but does no locale-sensitive formatting can link only FoundationEssentials and skip the ICU data payload entirely. On BSD where binary size matters for base system tools, this is worth designing around from the start rather than retrofitting. The practical rule: import FoundationEssentials explicitly when possible; only reach for full Foundation when you actually need the internationalization or legacy APIs.

## The honest bottom line

For most code, this transition is invisible. The cases where it matters are concentrated in three areas: persistence formats tied to Objective-C archives, locale-sensitive formatting where output byte-exactness matters, and platform-specific filesystem or process behavior. None of these require panicked action, but all three deserve explicit test coverage before we ship anything Swift-based with confidence.
