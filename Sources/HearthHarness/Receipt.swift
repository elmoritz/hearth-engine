/// What a run proved, by catalogue id. The rule of E-PROOF-2 lives here: skipped is not passed.
///
/// HE-1 holds the rule; the harness tool adds the commit, the image hashes and the file.
public struct Receipt: Sendable, Equatable {
    public enum Outcome: Int, Sendable, Comparable {
        case passed = 0
        case skipped = 1
        case failed = 2

        public static func < (lhs: Outcome, rhs: Outcome) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// The GPU the run used, or `nil` when it had none.
    public let gpu: String?
    public private(set) var outcomes: [String: Outcome] = [:]

    public init(gpu: String?) {
        self.gpu = gpu
    }

    /// The receipt of a GPU suite that could not run: every id skipped, no GPU.
    public static func skippingGPUSuite(ids: [String]) -> Receipt {
        var receipt = Receipt(gpu: nil)
        for id in ids {
            receipt.record(id, .skipped)
        }
        return receipt
    }

    /// Records one test's outcome. An id with several tests keeps its worst outcome.
    public mutating func record(_ id: String, _ outcome: Outcome) {
        outcomes[id] = max(outcomes[id] ?? .passed, outcome)
    }

    public var passedIDs: [String] { ids(.passed) }
    public var skippedIDs: [String] { ids(.skipped) }
    public var failedIDs: [String] { ids(.failed) }

    /// Complete only when it ran on a GPU, recorded at least one id, and every id passed.
    public var isComplete: Bool {
        gpu != nil && !outcomes.isEmpty && outcomes.values.allSatisfy { $0 == .passed }
    }

    private func ids(_ outcome: Outcome) -> [String] {
        outcomes.filter { $0.value == outcome }.keys.sorted()
    }
}
