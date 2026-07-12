import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if authStore.needsSetup {
                    Section("Create Manager Account") {
                        Text("No accounts exist yet. Create the first one — it becomes a manager account that can create and manage everyone else's logins.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        SecureField("Confirm Password", text: $confirmPassword)
                        Button("Create Manager Account") {
                            createManagerAccount()
                        }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    }
                } else {
                    Section("Log In") {
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                        Button("Log In") {
                            logIn()
                        }
                        .disabled(username.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    }

                    Section {
                        Text("Forgot your password? Ask your manager to reset it from the Account tab.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("PO Generator")
        }
    }

    private func createManagerAccount() {
        errorMessage = nil
        guard password == confirmPassword else {
            errorMessage = "Passwords don't match."
            return
        }
        guard authStore.createInitialManagerAccount(username: username, password: password) else {
            errorMessage = "Couldn't create that account."
            return
        }
        _ = authStore.logIn(username: username, password: password)
    }

    private func logIn() {
        errorMessage = nil
        guard authStore.logIn(username: username, password: password) else {
            errorMessage = "Incorrect username or password."
            return
        }
        password = ""
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthStore())
}
