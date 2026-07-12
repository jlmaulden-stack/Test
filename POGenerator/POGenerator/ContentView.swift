import SwiftUI

struct ContentView: View {
    @StateObject private var store = POStore()
    @StateObject private var authStore = AuthStore()

    var body: some View {
        Group {
            if authStore.currentUser != nil {
                TabView {
                    GenerateView()
                        .tabItem { Label("New PO", systemImage: "plus.circle") }

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
    }
}

#Preview {
    ContentView()
}
