import Foundation

/// Britse getalnotatie zoals een darts-caller het zegt: 120 → "one hundred and twenty".
enum NumberWords {
    private static let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
                               "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen",
                               "seventeen", "eighteen", "nineteen"]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]

    static func british(_ n: Int) -> String {
        guard n >= 0 && n < 1000 else { return "\(n)" }
        if n < 20 { return ones[n] }
        if n < 100 { return n % 10 == 0 ? tens[n / 10] : "\(tens[n / 10])-\(ones[n % 10])" }
        let rest = n % 100
        return "\(ones[n / 100]) hundred" + (rest == 0 ? "" : " and \(british(rest))")
    }
}
