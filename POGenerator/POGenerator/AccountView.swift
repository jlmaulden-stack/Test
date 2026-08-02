import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var newUsername = ""
    @State private var newPassword = ""
    @State private var newIsManager = false
    @State private var resetTarget: Account?
    @State private var resetPasswordText = ""
    @State private var errorMessage: String?
    @State private var showLogOutConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = authStore.currentUser {
                    Section("Logged In As") {
                        Text(user.username)
                        if user.isManager {
                            Text("Manager")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        Button("Log Out", role: .destructive) {
                            showLogOutConfirmation = true
                        }
                    }
                    .listRowBackground(Theme.panel)
                }

                if authStore.currentUser?.isManager == true {
                    Section("Team") {
                        ForEach(authStore.accounts) { account in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.username)
                                    if account.isManager {
                                        Text("Manager")
                                            .font(.footnote)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                Button("Reset Password") {
                                    resetTarget = account
                                    resetPasswordText = ""
                                }
                                .font(.footnote)
                                .buttonStyle(.borderless)
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                authStore.removeAccount(authStore.accounts[index], requestedBy: authStore.currentUser)
                            }
                        }
                        .listRowBackground(Theme.panel)
                    }

                    Section("Add Account") {
                        TextField("Username", text: $newUsername)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $newPassword)
                        Toggle("Manager Account", isOn: $newIsManager)
                        Button("Add") {
                            addAccount()
                        }
                        .disabled(newUsername.trimmingCharacters(in: .whitespaces).isEmpty || newPassword.isEmpty)
                    }
                    .listRowBackground(Theme.panel)
                } else {
                    Section {
                        Text("Contact your manager to add accounts or reset your password.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .listRowBackground(Theme.panel)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundColor(.red)
                            .font(.footnote)
                    }
                    .listRowBackground(Theme.panel)
                }
            }
            .industrialForm()
            .navigationTitle("ACCOUNT")
            .alert(
                "Reset Password",
                isPresented: Binding(
                    get: { resetTarget != nil },
                    set: { if !$0 { resetTarget = nil } }
                ),
                presenting: resetTarget
            ) { account in
                SecureField("New Password", text: $resetPasswordText)
                Button("Cancel", role: .cancel) { resetTarget = nil }
                Button("Reset") {
                    _ = authStore.resetPassword(
                        for: account,
                        newPassword: resetPasswordText,
                        requestedBy: authStore.currentUser
                    )
                    resetTarget = nil
                }
            } message: { account in
                Text("Set a new password for \(account.username).")
            }
            .confirmationDialog(
                "Log out of this account?",
                isPresented: $showLogOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Log Out", role: .destructive) {
                    authStore.logOut()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need your username and password to log back in.")
            }
            .task {
                await authStore.refreshAccounts()
            }
        }
    }

    private func addAccount() {
        errorMessage = nil
        let success = authStore.createAccount(
            username: newUsername,
            password: newPassword,
            isManager: newIsManager,
            requestedBy: authStore.currentUser
        )
        if success {
            newUsername = ""
            newPassword = ""
            newIsManager = false
        } else {
            errorMessage = "Couldn't add that account (username may already be taken)."
        }
    }
}

#Preview {
    AccountView()
        .environmentObject(AuthStore())
}
