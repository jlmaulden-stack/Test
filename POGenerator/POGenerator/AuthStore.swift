import Foundation

/// Manager-provisioned employee roster and "who's using this phone" session state.
/// Login is just a name/phone-number pick from the roster (no SMS verification yet) —
/// see the phone-number-authenticated version once a backend is available.
@MainActor
final class AuthStore: ObservableObject {
    @Published var employees: [Employee] = []
    @Published var currentUser: Employee?

    private let defaults = UserDefaults.standard
    private let employeesKey = "AuthStore.employees"
    private let currentUserIDKey = "AuthStore.currentUserID"

    init() {
        employees = Self.loadEmployees(from: defaults, key: employeesKey)
        if let id = defaults.string(forKey: currentUserIDKey) {
            currentUser = employees.first { $0.id == id }
        }
    }

    func addEmployee(name: String, phoneNumber: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedPhone = phoneNumber.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty, !trimmedPhone.isEmpty else { return }

        let employee = Employee(id: UUID().uuidString, name: trimmedName, phoneNumber: trimmedPhone)
        employees.append(employee)
        saveEmployees()
    }

    func removeEmployee(_ employee: Employee) {
        employees.removeAll { $0.id == employee.id }
        saveEmployees()
        if currentUser?.id == employee.id {
            logOut()
        }
    }

    func logIn(as employee: Employee) {
        currentUser = employee
        defaults.set(employee.id, forKey: currentUserIDKey)
    }

    func logOut() {
        currentUser = nil
        defaults.removeObject(forKey: currentUserIDKey)
    }

    private func saveEmployees() {
        guard let data = try? JSONEncoder().encode(employees) else { return }
        defaults.set(data, forKey: employeesKey)
    }

    private static func loadEmployees(from defaults: UserDefaults, key: String) -> [Employee] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([Employee].self, from: data)
        else { return [] }
        return decoded
    }
}
