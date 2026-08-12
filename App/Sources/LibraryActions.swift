import SwiftUI

/// A library action that failed, in a form an alert can be driven by.
///
/// Exists because every mutation in the library used to be written `try? store.doThing()`. Making
/// a notebook, renaming, moving, deleting, adding a page — all of them discarded whatever the file
/// system said. On a full disk, a revoked permission or an invalid state, the result was a tap
/// that appeared to do nothing at all, which is indistinguishable from the tap not having
/// registered and is the reason people tap again.
struct LibraryActionError: Identifiable {
    let id = UUID()
    /// What the user was trying to do, in their words — "Delete the notebook", not `deleteNotebook`.
    let action: String
    let underlying: Error

    var message: String {
        "\(action) failed. \(underlying.localizedDescription)"
    }
}

extension View {
    /// Presents whatever failed, and nothing when nothing has.
    func libraryActionAlert(_ error: Binding<LibraryActionError?>) -> some View {
        alert(item: error) { failure in
            Alert(
                title: Text("Couldn't finish that"),
                message: Text(failure.message),
                dismissButton: .default(Text("OK")))
        }
    }
}

/// Runs a throwing library mutation and routes the failure to an alert instead of the floor.
///
/// The call reads almost exactly like the `try?` it replaces, which is the point: the reason every
/// one of those existed is that surfacing an error took a `do`/`catch` and a piece of state at each
/// site, and nobody writes that ten times in a view.
@MainActor
func perform(
    _ action: String, error binding: Binding<LibraryActionError?>, _ body: () throws -> Void
) {
    do {
        try body()
    } catch {
        binding.wrappedValue = LibraryActionError(action: action, underlying: error)
    }
}
