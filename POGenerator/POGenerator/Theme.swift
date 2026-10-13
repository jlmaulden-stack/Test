import SwiftUI

/// Industrial palette: gunmetal backgrounds, steel panels, safety-orange accent.
enum Theme {
    static let background = Color(red: 0.090, green: 0.098, blue: 0.114)
    static let panel = Color(red: 0.137, green: 0.149, blue: 0.173)
    static let accent = Color(red: 1.0, green: 0.541, blue: 0.0)
    static let steel = Color(red: 0.62, green: 0.65, blue: 0.68)
}

extension View {
    /// Dark steel backdrop for Form-based screens.
    func industrialForm() -> some View {
        self
            .scrollContentBackground(.hidden)
            .background(Theme.background)
    }
}
