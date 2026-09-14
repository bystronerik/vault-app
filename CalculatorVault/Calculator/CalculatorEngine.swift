import Foundation

/// Basic calculator with the same precedence and edge cases as the iOS Calculator.
struct CalculatorEngine {
    enum Op: String, CaseIterable {
        case divide, multiply, subtract, add
        var isMultiplicative: Bool { self == .multiply || self == .divide }
    }

    /// Text on the display without grouping separators. "Error" after a division by zero.
    private(set) var display = "0"
    private var typing = false
    private var pendingAdd: (lhs: Double, op: Op)?
    private var pendingMul: (lhs: Double, op: Op)?
    private var lastEquals: (op: Op, rhs: Double)?
    private var operatorJustPressed = false

    /// The operator to highlight, as the iOS Calculator does after an operator press.
    var activeOp: Op? { operatorJustPressed ? (pendingMul?.op ?? pendingAdd?.op) : nil }
    var isCleared: Bool { display == "0" && !typing }

    /// Display text with grouping separators.
    var text: String {
        guard display != "Error", !display.contains("e") else { return display }
        var parts = display.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let negative = parts[0].hasPrefix("-")
        if negative { parts[0].removeFirst() }
        var grouped = ""
        for (i, c) in parts[0].reversed().enumerated() {
            if i > 0, i % 3 == 0 { grouped.append(",") }
            grouped.append(c)
        }
        parts[0] = (negative ? "-" : "") + String(grouped.reversed())
        return parts.joined(separator: ".")
    }

    mutating func digit(_ d: String) {
        if display == "Error" { clearAll() }
        if !typing { display = "0"; typing = true }
        operatorJustPressed = false
        lastEquals = nil
        if d == "." {
            if !display.contains(".") { display += "." }
            return
        }
        guard display.filter(\.isNumber).count < 9 else { return }
        switch display {
        case "0": display = d
        case "-0": display = "-" + d
        default: display += d
        }
    }

    mutating func toggleSign() {
        guard display != "Error" else { return }
        display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display
    }

    mutating func percent() {
        guard let x = Double(display) else { return }
        if let add = pendingAdd, pendingMul == nil {
            show(add.lhs * x / 100)
        } else {
            show(x / 100)
        }
    }

    mutating func operate(_ op: Op) {
        guard var x = Double(display) else { return }
        if operatorJustPressed { // Replace the previous operator.
            if let m = pendingMul { x = m.lhs; pendingMul = nil } else if let a = pendingAdd { x = a.lhs; pendingAdd = nil }
        }
        if op.isMultiplicative {
            if let m = pendingMul { x = Self.apply(m.op, m.lhs, x) }
            pendingMul = (x, op)
        } else {
            if let m = pendingMul { x = Self.apply(m.op, m.lhs, x); pendingMul = nil }
            if let a = pendingAdd { x = Self.apply(a.op, a.lhs, x) }
            pendingAdd = (x, op)
        }
        show(x)
        operatorJustPressed = true
        lastEquals = nil
    }

    mutating func equals() {
        guard var x = Double(display) else { return }
        if pendingMul == nil, pendingAdd == nil {
            if let l = lastEquals { x = Self.apply(l.op, x, l.rhs) }
        } else {
            if let m = pendingMul { lastEquals = (m.op, x); x = Self.apply(m.op, m.lhs, x) } else if let a = pendingAdd { lastEquals = (a.op, x) }
            if let a = pendingAdd { x = Self.apply(a.op, a.lhs, x) }
            pendingMul = nil
            pendingAdd = nil
        }
        show(x)
    }

    /// Shows Error, as after a division by zero. The next digit clears it.
    mutating func showError() { show(.nan) }

    /// "C" clears the entry. "AC" clears everything.
    mutating func clear() {
        if isCleared { clearAll() } else { display = "0"; typing = false; operatorJustPressed = false }
    }

    private mutating func clearAll() {
        self = CalculatorEngine()
    }

    private mutating func show(_ v: Double) {
        typing = false
        operatorJustPressed = false
        guard v.isFinite else { clearAll(); display = "Error"; return }
        display = Self.format(v)
    }

    private static func apply(_ op: Op, _ a: Double, _ b: Double) -> Double {
        switch op {
        case .add: a + b
        case .subtract: a - b
        case .multiply: a * b
        case .divide: b == 0 ? .nan : a / b
        }
    }

    /// 9 significant digits. Exponent form for very large and very small values. `Double(_:)` can parse the result.
    static func format(_ v: Double) -> String {
        let exponent = v == 0 ? 0 : floor(log10(abs(v)))
        if exponent >= 12 || exponent < -6 {
            let parts = String(format: "%.8e", v).split(separator: "e")
            var mantissa = String(parts[0])
            while mantissa.hasSuffix("0") { mantissa.removeLast() }
            if mantissa.hasSuffix(".") { mantissa.removeLast() }
            return mantissa + "e\(Int(parts[1]) ?? 0)"
        }
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = 9
        return f.string(from: v as NSNumber) ?? "0"
    }

    #if DEBUG
    static func selfTest() {
        func run(_ keys: String) -> String {
            var e = CalculatorEngine()
            for k in keys {
                switch k {
                case "+": e.operate(.add)
                case "-": e.operate(.subtract)
                case "*": e.operate(.multiply)
                case "/": e.operate(.divide)
                case "=": e.equals()
                case "%": e.percent()
                case "~": e.toggleSign()
                case "c": e.clear()
                default: e.digit(String(k))
                }
            }
            return e.text
        }
        assert(run("2+3*4=") == "14")
        assert(run("2+3==") == "8")
        assert(run("5+=") == "10")
        assert(run("1/0=") == "Error")
        assert(run("1/0=5") == "5")
        assert(run("200+10%") == "20")
        assert(run("50%") == "0.5")
        assert(run("1234567*1000=") == "1,234,567,000")
        assert(run("1/3=") == "0.333333333")
        assert(run("99999999*99999999=") == "9.9999998e15")
        assert(run("1/8000000=") == "1.25e-7")
        assert(run("0.1+0.2=") == "0.3")
        assert(run("5~") == "-5")
        assert(run("2+*3=") == "6")
        assert(run("7+8cc") == "0")
        assert(run("7+8c3=") == "10")
        assert(run("123456789012") == "123,456,789")
    }
    #endif
}
