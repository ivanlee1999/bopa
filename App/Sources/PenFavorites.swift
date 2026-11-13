import SwiftUI

struct PenFavorite: Codable, Equatable, Identifiable {
    var id: String
    var pen: String
    var colorID: Int
    var width: String

    var kind: ToolSelection.Kind? { ToolSelection.Kind(rawValue: pen) }
    var strokeWidth: ToolSelection.Width? { ToolSelection.Width(rawValue: width) }
    var ink: Modernist.Ink? { Modernist.inks.first { $0.id == colorID } }
    var label: String { [kind?.label, ink?.name, strokeWidth?.label].compactMap { $0 }.joined(separator: ", ") }
    var valid: Bool { kind?.takesInk == true && strokeWidth != nil && ink != nil }
}

struct PenFavoritesEditor: View {
    @ObservedObject var selection: ToolSelection
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ForEach(selection.favorites) { favorite in
                    Button { selection.apply(favorite) } label: {
                        HStack {
                            Circle().fill(favorite.ink?.color ?? Modernist.ink).frame(width: 16, height: 16)
                            Text(favorite.label).foregroundStyle(Modernist.ink)
                            Spacer()
                            if selection.selectedFavoriteID == favorite.id { Image(systemName: "checkmark") }
                        }.frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("favorite.row.\(favorite.id)")
                }.onMove(perform: selection.moveFavorites).onDelete(perform: selection.deleteFavorites)
                Button { selection.pinCurrent() } label: { Label("Pin current pen", systemImage: "pin") }
                    .disabled(!selection.kind.takesInk || selection.selectedFavoriteID != nil)
                    .accessibilityIdentifier("favorite.pin")
            }.environment(\.editMode, .constant(.active))
                .navigationTitle("Favorite pens")
                .toolbar { Button("Done") { dismiss() }.accessibilityIdentifier("favorite.done") }
        }
    }
}
