import Foundation

enum PONumberFormatter {
    /// Last 4 digits of the job number, e.g. "4521-10234" -> "0234".
    static func jobCore(from jobNumber: String) -> String {
        let digits = jobNumber.filter(\.isNumber)
        return String(digits.suffix(4))
    }

    /// First 4 letters of the customer name, uppercased, e.g. "Acme Corp" -> "ACME".
    static func customerCode(from customerName: String) -> String {
        let letters = customerName.filter(\.isLetter)
        return String(letters.prefix(4)).uppercased()
    }

    /// Builds "0234-2-ACME" from job number, PO sequence number for that job, and customer name.
    static func poNumber(jobNumber: String, customerName: String, sequence: Int) -> String {
        "\(jobCore(from: jobNumber))-\(sequence)-\(customerCode(from: customerName))"
    }
}
