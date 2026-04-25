import Foundation
import SwiftCardanoCore

/// The set of active governance proposals on-chain.
///
/// Returned by `GetProposals` (query tag 31).
///
/// Wire format: a CBOR list of `GovernanceProposal` entries. Each `GovernanceProposal`
/// is itself a 7-element list `[govActionID, committeeVotes, dRepVotes, stakePoolVotes,
/// proposalProcedure, proposedIn, expiresAfter]` — the same shape as proposals in
/// `GovernanceState.proposals.proposals`.
public struct ActiveProposals: CBORSerializable, Sendable {
    public let proposals: [GovernanceProposal]

    public init(proposals: [GovernanceProposal]) {
        self.proposals = proposals
    }

    public init(from primitive: Primitive) throws {
        guard case .list(let elems) = primitive else {
            throw LedgerStateDecodingError.unexpectedFormat("ActiveProposals: expected list")
        }
        proposals = try elems.map { try GovernanceProposal(from: $0) }
    }

    public func toPrimitive() throws -> Primitive {
        .list(try proposals.map { try $0.toPrimitive() })
    }
}
