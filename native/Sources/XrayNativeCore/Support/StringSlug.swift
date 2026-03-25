import Foundation

extension String {
    func slugified() -> String {
        let lowered = lowercased()
        let pattern = "[^a-z0-9]+"
        let replaced = lowered.replacingOccurrences(
            of: pattern,
            with: "-",
            options: .regularExpression
        )
        let trimmed = replaced.replacingOccurrences(
            of: "^-+|-+$",
            with: "",
            options: .regularExpression
        )
        return trimmed.isEmpty ? "profile" : trimmed
    }
}
