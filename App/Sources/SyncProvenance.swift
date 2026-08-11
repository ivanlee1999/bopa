import SwiftUI

/// Where an item lives, as of the last completed sync. Read from NotableKit's
/// `RemoteIndex` (`<root>/.bopa-remote-index.json`); `unknown` means this library has
/// never synced, so claiming anything is "local only" would be misleading.
enum SyncProvenance: Hashable {
    case onServer
    case localOnly
    case unknown

    var symbolName: String? {
        switch self {
        case .onServer: return "cloud.fill"
        case .localOnly: return "arrow.up.circle"
        case .unknown: return nil
        }
    }

    var label: String? {
        switch self {
        case .onServer: return "On server"
        case .localOnly: return "Local only, will upload on next sync"
        case .unknown: return nil
        }
    }

    /// Only two states carry colour, and both take a saturated one: on a Kaleido panel a
    /// pale tint is indistinguishable from grey.
    var tint: Color {
        switch self {
        case .onServer: return Modernist.neutral700
        case .localOnly: return Modernist.accent700
        case .unknown: return Modernist.neutral600
        }
    }
}

/// The provenance glyph. Renders nothing at all when provenance is unknown, so a library
/// with no server configured stays free of badges.
struct ProvenanceBadge: View {
    let provenance: SyncProvenance
    var size: CGFloat = 13
    /// Overrides the provenance tint where the glyph sits on an ink fill and the tint
    /// would have nothing to contrast against.
    var color: Color?

    var body: some View {
        if let symbolName = provenance.symbolName, let label = provenance.label {
            Image(systemName: symbolName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color ?? provenance.tint)
                .accessibilityLabel(label)
        }
    }
}

/// Marks a notebook that changed on both devices and is waiting on a decision.
///
/// Deliberately outranks the provenance glyph on a cover: "on server" is information, this is a
/// thing to do, and until it is done the notebook will not sync in either direction.
///
/// A solid red chip rather than a frosted disc — this is the one thing on a cover that has
/// to survive the colour layer washing out, so it is a fill, not a tint.
struct ConflictCoverBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Modernist.paper)
            .accessibilityLabel("Changed on both devices — needs you to choose")
            .frame(width: 24, height: 24)
            .background(Modernist.accent700)
    }
}

/// Same glyph on a paper chip, for laying over a notebook cover.
struct ProvenanceCoverBadge: View {
    let provenance: SyncProvenance

    var body: some View {
        if provenance != .unknown {
            ProvenanceBadge(provenance: provenance, size: 12)
                .frame(width: 24, height: 24)
                .background(Modernist.paper)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Modernist.neutral600)
                        .frame(height: Modernist.ruleHair)
                }
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Modernist.neutral600)
                        .frame(width: Modernist.ruleHair)
                }
        }
    }
}
