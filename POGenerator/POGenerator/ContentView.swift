import SwiftUI

struct ContentView: View {
    @StateObject private var store = POStore()

    var body: some View {
        TabView {
            GenerateView()
                .tabItem { Label("New PO", systemImage: "plus.circle") }

            HistoryView()
                .tabItem { Label("History", systemImage: "clock") }
        }
        .environmentObject(store)
    }
}

#Preview {
    ContentView()
}
