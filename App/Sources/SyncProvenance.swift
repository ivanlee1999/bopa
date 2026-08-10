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

    var tint: Color {
        switch self {
        case .onServer: return .accentColor
        case .localOnly: return .orange
        case .unknown: return .secondary
        }
    }
}

/// The provenance glyph. Renders nothing at all when provenance is unknown, so a library
/// with no server configured stays free of badges.
struct ProvenanceBadge: View {
    let provenance: SyncProvenance
    var size: CGFloat = 13

    var body: some View {
        if let symbolName = provenance.symbolName, let label = provenance.label {
            Image(systemName: symbolName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(provenance.tint)
                .accessibilityLabel(label)
        }
    }
}

/// Marks a notebook that changed on both devices and is waiting on a decision.
///
/// Deliberately outranks the provenance glyph on a cover: "on server" is information, this is a
/// thing to do, and until it is done the notebook will not sync in either direction.
struct ConflictCoverBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .accessibilityLabel("Changed on both devices — needs you to choose")
            .padding(5)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
            .padding(6)
    }
}

/// Same glyph on a frosted disc, for laying over a notebook cover thumbnail.
struct ProvenanceCoverBadge: View {
    let provenance: SyncProvenance

    var body: some View {
        if provenance != .unknown {
            ProvenanceBadge(provenance: provenance, size: 12)
                .padding(5)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .padding(6)
        }
    }
}
