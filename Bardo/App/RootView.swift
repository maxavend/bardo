import SwiftUI

struct RootView: View {
    @StateObject private var model = LibraryViewModel()

    var body: some View {
        LibraryView(model: model)
    }
}
