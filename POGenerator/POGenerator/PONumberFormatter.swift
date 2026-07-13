import Foundation

enum PONumberFormatter {
    /// Last 4 digits of the job number, e.g. "4521-10234" -> "0234".
    static func jobCore(from jobNumber: String) -> String {
        let digits = jobNumber.filter(\.isNumber)
        return String(digits.suffix(4))
    }

    /// First full word of the customer name, uppercased, e.g. "Acme Corp" -> "ACME",
    /// "Smith Brothers Construction" -> "SMITH". Falls through to the next word if
    /// the first is purely numeric/symbolic (e.g. "84 Lumber Co" -> "LUMBER"), so the
    /// code is never left blank for a name that happens to start with a number.
    static func customerCode(from customerName: String) -> String {
        let words = customerName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        for word in words {
            let letters = word.filter(\.isLetter)
            if !letters.isEmpty {
                return String(letters).uppercased()
            }
        }
        return ""
    }

    /// Builds "0234-2-ACME" from job number, PO sequence number for that job, and customer name.
    static func poNumber(jobNumber: String, customerName: String, sequence: Int) -> String {
        "\(jobCore(from: jobNumber))-\(sequence)-\(customerCode(from: customerName))"
    }
}
