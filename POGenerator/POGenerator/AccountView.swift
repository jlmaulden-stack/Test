import SwiftUI

struct AccountView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var newName = ""
    @State private var newPhone = ""

    var body: some View {
        NavigationStack {
            Form {
                if let user = authStore.currentUser {
                    Section("Logged In As") {
                        Text(user.name)
                        Text(user.phoneNumber)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Button("Log Out", role: .destructive) {
                            authStore.logOut()
                        }
                    }
                }

                Section("Team") {
                    ForEach(authStore.employees) { employee in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(employee.name)
                            Text(employee.phoneNumber)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            authStore.removeEmployee(authStore.employees[index])
                        }
                    }
                }

                Section("Add Employee") {
                    TextField("Name", text: $newName)
                    TextField("Phone Number", text: $newPhone)
                        .keyboardType(.phonePad)
                    Button("Add") {
                        authStore.addEmployee(name: newName, phoneNumber: newPhone)
                        newName = ""
                        newPhone = ""
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty
                        || newPhone.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .navigationTitle("Account")
        }
    }
}

#Preview {
    AccountView()
        .environmentObject(AuthStore())
}
