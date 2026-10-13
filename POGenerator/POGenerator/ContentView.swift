import SwiftUI

struct ContentView: View {
    @StateObject private var store = POStore()
    @StateObject private var authStore = AuthStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if authStore.currentUser != nil {
                TabView {
                    GenerateView()
                        .tabItem { Label("New PO", systemImage: "shippingbox") }

                    HistoryView()
                        .tabItem { Label("History", systemImage: "clock") }

                    AccountView()
                        .tabItem { Label("Account", systemImage: "person.circle") }
                }
            } else {
                LoginView()
            }
        }
        .environmentObject(store)
        .environmentObject(authStore)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onChange(of: scenePhase) { phase in
            // Don't let the app go to sleep holding an unsynced edit.
            if phase != .active {
                store.flushPendingPushes()
            }
        }
    }
}

#Preview {
    ContentView()
}
