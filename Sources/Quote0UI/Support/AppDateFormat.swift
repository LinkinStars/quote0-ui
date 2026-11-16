import Foundation

enum AppDateFormat {
    static func short(_ date: Date) -> String { format(date, pattern: "yyyy年M月d日 HH:mm") }
    static func detail(_ date: Date) -> String { format(date, pattern: "yyyy年M月d日 HH:mm:ss") }

    private static func format(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
