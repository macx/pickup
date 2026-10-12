import Foundation

/// SplitMix64: tiny, fast, deterministic across platforms. Used for all property and fuzz tests.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }
    mutating func chance(_ probability: Double) -> Bool { Double.random(in: 0..<1, using: &self) < probability }
    mutating func pick<T>(_ items: [T]) -> T { items[int(0...(items.count - 1))] }

    /// Random string of `length` characters drawn from `alphabet`.
    mutating func string(from alphabet: [Character], length: Int) -> String {
        String((0..<length).map { _ in alphabet[int(0...(alphabet.count - 1))] })
    }

    /// Random digit string.
    mutating func digits(_ count: Int) -> String {
        string(from: Array("0123456789"), length: count)
    }
}

/// Runs `body` for a fixed number of seeds. A failing assertion must include `seed` in its message
/// (use `fuzz.context`), so the case can be replayed with `PICKUP_FUZZ_SEED=<seed> swift test --filter ...`
/// and then be added as a fixture.
///
/// Environment overrides: `PICKUP_FUZZ_SEED` (run just that seed), `PICKUP_FUZZ_ITERATIONS` (scale up
/// locally; the defaults keep the whole suite in a few seconds).
enum Fuzz {
    static func run(_ name: String, iterations: Int, baseSeed: UInt64 = 0x5EED_0001, _ body: (inout SeededRandom, UInt64) throws -> Void) rethrows {
        let environment = ProcessInfo.processInfo.environment
        if let text = environment["PICKUP_FUZZ_SEED"], let seed = UInt64(text) {
            var rng = SeededRandom(seed: seed)
            try body(&rng, seed)
            return
        }
        let count = environment["PICKUP_FUZZ_ITERATIONS"].flatMap(Int.init) ?? iterations
        for index in 0..<count {
            let seed = baseSeed &+ UInt64(index)
            var rng = SeededRandom(seed: seed)
            try body(&rng, seed)
        }
    }

    static func context(_ name: String, _ seed: UInt64) -> String { "[\(name) seed=\(seed)]" }
}
