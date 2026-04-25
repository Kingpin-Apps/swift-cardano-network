import Foundation
import SwiftCardanoCore

/// The genesis configuration for the current era.
///
/// Returned by `GetGenesisConfig` (query tag 11).
///
/// The wire format and field set varies by era:
/// - **Byron**: CBOR string-keyed map with legacy fields (avvmDistr, blockVersionData, etc.)
/// - **Shelley** (and all later eras): CBOR list of 15 fields in Haskell ToCBOR order
///   (systemStart, networkMagic, networkId, activeSlotsCoeff, securityParam, epochLength,
///    slotsPerKESPeriod, maxKESEvolutions, slotLength, updateQuorum, maxLovelaceSupply,
///    protocolParams, genDelegs, initialFunds, staking)
/// - **Alonzo** fields are overlaid on the Shelley genesis in the Alonzo upgrade genesis file
/// - **Conway** introduces poolVotingThresholds, dRepVotingThresholds, deposits, etc.
///
/// When querying at a Conway-era point, the node returns the Shelley genesis parameters.
/// Use `GetCurrentPParams` (tag 3) for the current protocol parameters.
///
/// NOTE: CBOR field ordering is based on Haskell ToCBOR instances in cardano-ledger.
/// Verify against live node output and adjust field indices if decoding fails.
public enum GenesisConfig: CBORSerializable, Sendable {
    case shelley(ShelleyGenesis)
    case alonzo(AlonzoGenesis)
    case conway(ConwayGenesis)
    case byron(ByronGenesis)
    /// Raw CBOR for unrecognised or future-era genesis formats.
    case unknown(Primitive)

    public init(from primitive: Primitive) throws {
        // Try each era decoder in order. The node returns different list lengths
        // for each era. Byron uses a string-keyed map, so try it first if it looks like a map.
        switch primitive {
        case .dict, .orderedDict:
            if let g = try? ByronGenesis(from: primitive) {
                self = .byron(g)
            } else {
                self = .unknown(primitive)
            }
        case .list(let elems):
            // Discriminate by list length:
            //   Shelley: 14-15 elements
            //   Alonzo:  8 elements
            //   Conway:  12 elements
            let count = elems.count
            if count >= 14, let g = try? ShelleyGenesis(from: primitive) {
                self = .shelley(g)
            } else if count == 8, let g = try? AlonzoGenesis(from: primitive) {
                self = .alonzo(g)
            } else if count == 12, let g = try? ConwayGenesis(from: primitive) {
                self = .conway(g)
            } else {
                self = .unknown(primitive)
            }
        default:
            self = .unknown(primitive)
        }
    }

    public func toPrimitive() throws -> Primitive {
        switch self {
        case .shelley(let g): return try g.toPrimitive()
        case .alonzo(let g): return try g.toPrimitive()
        case .conway(let g): return try g.toPrimitive()
        case .byron(let g): return try g.toPrimitive()
        case .unknown(let p): return p
        }
    }

    public static func == (lhs: GenesisConfig, rhs: GenesisConfig) -> Bool {
        (try? lhs.toPrimitive()) == (try? rhs.toPrimitive())
    }

    public func hash(into hasher: inout Hasher) {
        if let p = try? toPrimitive() { p.hash(into: &hasher) }
    }
}
