#if os(macOS)
import SwiftUI
import VestalCore

// MARK: - Stage
//
// The render model's window content, over whatever background the host
// draws (the aurora and blur in the app, the palette's `bg` offscreen): the
// view's root node (§10.4 rule 5), and while a popup is open the scrim and
// the popup's card (§9.4). The card is v0.3's: black under an ultra-thick
// dark material, radius 14, a white 10% stroke and a shadow. A click on the
// scrim is Esc, which the core turns into closing the popup.

public struct RenderStageView: View {
    @ObservedObject var store: RenderStore

    public init(store: RenderStore) {
        self.store = store
    }

    public var body: some View {
        StageLayout {
            if let root = store.root {
                RenderNodeView(handle: root, parentAxis: nil)
                    .layoutValue(key: StageRoleKey.self, value: .root)
            }
            if let popup = store.popup {
                store.style.color("scrim")
                    .contentShape(Rectangle())
                    .onTapGesture { store.send(.key("escape")) }
                    .transition(.opacity)
                    .layoutValue(key: StageRoleKey.self, value: .scrim)
                RenderNodeView(handle: popup.handle, parentAxis: nil)
                    .background(PopupCard())
                    .shadow(color: .black.opacity(0.5), radius: 24, y: 12)
                    // A click inside the card that hits nothing is not Esc.
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .layoutValue(key: StageRoleKey.self, value: .card(width: popup.width))
            }
        }
        .coordinateSpace(name: FrameCollector.space)
        // v0.3's popup animation (§10.4 "Animations").
        .animation(.easeInOut(duration: 0.18), value: store.popup?.handle.id)
        .environment(\.renderStyle, store.style)
        .environment(\.renderSend, store.send)
    }
}

/// The popup card's chrome, as v0.3's SystemDetailView draws it.
struct PopupCard: View {
    static let radius: CGFloat = 14

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Self.radius).fill(.black)
            RoundedRectangle(cornerRadius: Self.radius)
                .fill(.ultraThickMaterial)
                .environment(\.colorScheme, .dark)
            RoundedRectangle(cornerRadius: Self.radius)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}
#endif
