import SwiftUI

/// A notebook cover in the Modernist language: a square-cornered 3:4 block with a
/// saturated spine down the left edge and the page count set as a micro-label.
///
/// The first page supplies the paper and ink. A missing preview uses plain paper
/// and the title, so the cover never invents a paper pattern.
struct NotebookCoverView: View {
    /// Stable identity (the notebook id) — picks the spine colour.
    let seed: String
    let title: String
    let pageCount: Int
    let thumbnail: UIImage?
    var showsPageCount = true

    private static let spineWidth: CGFloat = 12


    var body: some View {
        ZStack(alignment: .topLeading) {
            base
            Rectangle()
                .fill(Modernist.fill(for: seed))
                .frame(width: Self.spineWidth)
                .frame(maxHeight: .infinity, alignment: .leading)
        }
        .aspectRatio(3.0 / 4.0, contentMode: .fit)
        .clipped()
        .overlay(
            Rectangle().strokeBorder(Modernist.neutral600, lineWidth: Modernist.ruleHair)
        )
        .overlay(alignment: .bottomLeading) {
            if showsPageCount { pageLabel }
        }
    }

    @ViewBuilder
    private var base: some View {
        if let thumbnail {
            Color.white
                .overlay {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
        } else {
            ZStack(alignment: .topLeading) {
                Modernist.paper
                Text(title)
                    .font(Modernist.display(15))
                    .tracking(Modernist.displayTracking(15))
                    .foregroundStyle(Modernist.ink)
                    .lineLimit(3)
                    .padding(.leading, Self.spineWidth + 10)
                    .padding(.trailing, 12)
                    .padding(.top, 16)
            }
        }
    }

    /// Sits on a paper chip rather than straight on the cover: over a page preview there
    /// is no telling what is underneath it.
    private var pageLabel: some View {
        Text("\(pageCount) \(pageCount == 1 ? "page" : "pages")")
            .font(Modernist.font(12, .semibold))
            .foregroundStyle(Modernist.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Modernist.paper)
            .padding(.leading, Self.spineWidth + 10)
            .padding(.bottom, 10)
    }
}
