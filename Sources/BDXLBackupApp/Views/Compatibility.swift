import SwiftUI

extension View {
    @ViewBuilder
    func groupedFormIfAvailable() -> some View {
        if #available(macOS 13.0, *) {
            self.formStyle(.grouped)
        } else {
            self
        }
    }

    @ViewBuilder
    func trackingIfAvailable(_ tracking: CGFloat) -> some View {
        if #available(macOS 13.0, *) {
            self.tracking(tracking)
        } else {
            self
        }
    }
}
