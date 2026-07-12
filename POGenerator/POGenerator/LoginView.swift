import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var authStore: AuthStore
    @State private var searchText = ""
    @State private var newName = ""
    @State private var newPhone = ""

    private var filteredEmployees: [Employee] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return authStore.employees }
        return authStore.employees.filter {
            $0.name.lowercased().contains(query) || $0.phoneNumber.contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if !authStore.employees.isEmpty {
                    Section("Log In") {
                        TextField("Search name or phone number", text: $searchText)
                            .keyboardType(.namePhonePad)

                        ForEach(filteredEmployees) { employee in
                            Button {
                                authStore.logIn(as: employee)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(employee.name)
                                        .foregroundColor(.primary)
                                    Text(employee.phoneNumber)
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section {
                        Text("No employees yet. Add your team below, then tap a name to log in.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
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
            .navigationTitle("PO Generator")
        }
    }
}

#Preview {
    LoginView()
        .environmentObject(AuthStore())
}
