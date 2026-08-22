import Foundation

/// A tiny, pure, sandboxed expression language for row-level transforms and
/// filters. Column references by name (bare identifiers or `col("name")`),
/// arithmetic, comparison, logic, and a curated string/util function library.
///
///     len(text) > 40 and lang == "en"
///     lower(trim(title)) + " — " + source
///     tokens(text) <= 512
public indirect enum Expr: Sendable {
    case literal(Value)
    case column(String)
    case unary(String, Expr)
    case binary(String, Expr, Expr)
    case call(String, [Expr])
}

public enum ExpressionParser {

    // MARK: Lexer

    enum Token: Equatable {
        case number(Double)
        case int(Int64)
        case string(String)
        case identifier(String)
        case op(String)
        case lparen, rparen, comma
    }

    static func lex(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        let chars = Array(input)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch.isWhitespace { i += 1; continue }
            if ch == "(" { tokens.append(.lparen); i += 1; continue }
            if ch == ")" { tokens.append(.rparen); i += 1; continue }
            if ch == "," { tokens.append(.comma); i += 1; continue }
            if ch == "\"" || ch == "'" {
                let quote = ch
                var s = ""
                i += 1
                while i < chars.count && chars[i] != quote {
                    if chars[i] == "\\" && i + 1 < chars.count {
                        i += 1
                        switch chars[i] {
                        case "n": s.append("\n")
                        case "t": s.append("\t")
                        default: s.append(chars[i])
                        }
                    } else {
                        s.append(chars[i])
                    }
                    i += 1
                }
                guard i < chars.count else { throw AlembicError.expressionError("Unterminated string") }
                i += 1
                tokens.append(.string(s))
                continue
            }
            if ch.isNumber || (ch == "." && i + 1 < chars.count && chars[i + 1].isNumber) {
                var s = ""
                var isDouble = false
                while i < chars.count && (chars[i].isNumber || chars[i] == ".") {
                    if chars[i] == "." { isDouble = true }
                    s.append(chars[i])
                    i += 1
                }
                if isDouble {
                    guard let d = Double(s) else { throw AlembicError.expressionError("Bad number: \(s)") }
                    tokens.append(.number(d))
                } else {
                    guard let n = Int64(s) else { throw AlembicError.expressionError("Bad number: \(s)") }
                    tokens.append(.int(n))
                }
                continue
            }
            if ch.isLetter || ch == "_" {
                var s = ""
                while i < chars.count && (chars[i].isLetter || chars[i].isNumber || chars[i] == "_") {
                    s.append(chars[i])
                    i += 1
                }
                switch s {
                case "and", "or", "not": tokens.append(.op(s))
                case "true": tokens.append(.identifier("true"))
                case "false": tokens.append(.identifier("false"))
                case "null": tokens.append(.identifier("null"))
                default: tokens.append(.identifier(s))
                }
                continue
            }
            // operators
            let two = i + 1 < chars.count ? String([ch, chars[i + 1]]) : ""
            if ["==", "!=", ">=", "<=", "&&", "||"].contains(two) {
                tokens.append(.op(two == "&&" ? "and" : two == "||" ? "or" : two))
                i += 2
                continue
            }
            if "+-*/%<>!".contains(ch) {
                tokens.append(.op(ch == "!" ? "not" : String(ch)))
                i += 1
                continue
            }
            throw AlembicError.expressionError("Unexpected character: \(ch)")
        }
        return tokens
    }

    // MARK: Pratt parser

    public static func parse(_ input: String) throws -> Expr {
        var tokens = try lex(input)
        let expr = try parseExpression(&tokens, minPrecedence: 0)
        guard tokens.isEmpty else { throw AlembicError.expressionError("Trailing tokens") }
        return expr
    }

    static let precedence: [String: Int] = [
        "or": 1, "and": 2,
        "==": 3, "!=": 3, "<": 4, ">": 4, "<=": 4, ">=": 4,
        "+": 5, "-": 5,
        "*": 6, "/": 6, "%": 6
    ]

    static func parseExpression(_ tokens: inout [Token], minPrecedence: Int) throws -> Expr {
        var lhs = try parsePrimary(&tokens)
        while case .op(let o)? = tokens.first, let prec = precedence[o], prec >= minPrecedence {
            tokens.removeFirst()
            let rhs = try parseExpression(&tokens, minPrecedence: prec + 1)
            lhs = .binary(o, lhs, rhs)
        }
        return lhs
    }

    static func parsePrimary(_ tokens: inout [Token]) throws -> Expr {
        guard let first = tokens.first else { throw AlembicError.expressionError("Unexpected end of expression") }
        tokens.removeFirst()
        switch first {
        case .number(let d): return .literal(.double(d))
        case .int(let n): return .literal(.int(n))
        case .string(let s): return .literal(.string(s))
        case .op("-"):
            let operand = try parsePrimary(&tokens)
            return .unary("-", operand)
        case .op("not"):
            let operand = try parseExpression(&tokens, minPrecedence: 3)
            return .unary("not", operand)
        case .lparen:
            let e = try parseExpression(&tokens, minPrecedence: 0)
            guard tokens.first == .rparen else { throw AlembicError.expressionError("Expected )") }
            tokens.removeFirst()
            return e
        case .identifier(let name):
            if name == "true" { return .literal(.bool(true)) }
            if name == "false" { return .literal(.bool(false)) }
            if name == "null" { return .literal(.null) }
            if tokens.first == .lparen {
                tokens.removeFirst()
                var args: [Expr] = []
                if tokens.first != .rparen {
                    while true {
                        args.append(try parseExpression(&tokens, minPrecedence: 0))
                        if tokens.first == .comma { tokens.removeFirst(); continue }
                        break
                    }
                }
                guard tokens.first == .rparen else { throw AlembicError.expressionError("Expected ) after arguments to \(name)") }
                tokens.removeFirst()
                return .call(name, args)
            }
            return .column(name)
        default:
            throw AlembicError.expressionError("Unexpected token")
        }
    }
}

/// Evaluate an Expr against one row.
public enum ExpressionEvaluator {

    public static func evaluate(_ expr: Expr, columns: [String], values: [Value]) throws -> Value {
        switch expr {
        case .literal(let v):
            return v

        case .column(let name):
            guard let idx = columns.firstIndex(of: name) else {
                throw AlembicError.expressionError("Unknown column: \(name)")
            }
            return idx < values.count ? values[idx] : .null

        case .unary(let op, let operand):
            let v = try evaluate(operand, columns: columns, values: values)
            switch op {
            case "-":
                if case .int(let i) = v { return .int(-i) }
                if let d = v.doubleValue { return .double(-d) }
                return .null
            case "not":
                return .bool(!truthy(v))
            default:
                throw AlembicError.expressionError("Unknown unary operator \(op)")
            }

        case .binary(let op, let l, let r):
            // Short-circuit logic
            if op == "and" {
                let lv = try evaluate(l, columns: columns, values: values)
                if !truthy(lv) { return .bool(false) }
                return .bool(truthy(try evaluate(r, columns: columns, values: values)))
            }
            if op == "or" {
                let lv = try evaluate(l, columns: columns, values: values)
                if truthy(lv) { return .bool(true) }
                return .bool(truthy(try evaluate(r, columns: columns, values: values)))
            }
            let lv = try evaluate(l, columns: columns, values: values)
            let rv = try evaluate(r, columns: columns, values: values)
            return try binaryOp(op, lv, rv)

        case .call(let name, let argExprs):
            var args: [Value] = []
            for a in argExprs { args.append(try evaluate(a, columns: columns, values: values)) }
            return try callFunction(name, args, columns: columns, values: values)
        }
    }

    static func truthy(_ v: Value) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .date: return true
        }
    }

    static func binaryOp(_ op: String, _ l: Value, _ r: Value) throws -> Value {
        switch op {
        case "==": return .bool(looseEqual(l, r))
        case "!=": return .bool(!looseEqual(l, r))
        case "<", ">", "<=", ">=":
            let cmp: Int
            if let ld = l.doubleValue, let rd = r.doubleValue {
                cmp = ld < rd ? -1 : ld > rd ? 1 : 0
            } else if case .date(let a) = l, case .date(let b) = r {
                cmp = a < b ? -1 : a > b ? 1 : 0
            } else {
                let a = l.display, b = r.display
                cmp = a < b ? -1 : a > b ? 1 : 0
            }
            switch op {
            case "<": return .bool(cmp < 0)
            case ">": return .bool(cmp > 0)
            case "<=": return .bool(cmp <= 0)
            default: return .bool(cmp >= 0)
            }
        case "+":
            // String concat if either side is a string
            if case .string = l { return .string(l.display + r.display) }
            if case .string = r { return .string(l.display + r.display) }
            if case .int(let a) = l, case .int(let b) = r { return .int(a &+ b) }
            if let a = l.doubleValue, let b = r.doubleValue { return .double(a + b) }
            return .null
        case "-":
            if case .int(let a) = l, case .int(let b) = r { return .int(a &- b) }
            if let a = l.doubleValue, let b = r.doubleValue { return .double(a - b) }
            return .null
        case "*":
            if case .int(let a) = l, case .int(let b) = r { return .int(a &* b) }
            if let a = l.doubleValue, let b = r.doubleValue { return .double(a * b) }
            return .null
        case "/":
            guard let a = l.doubleValue, let b = r.doubleValue, b != 0 else { return .null }
            return .double(a / b)
        case "%":
            if case .int(let a) = l, case .int(let b) = r, b != 0 { return .int(a % b) }
            return .null
        default:
            throw AlembicError.expressionError("Unknown operator \(op)")
        }
    }

    static func looseEqual(_ l: Value, _ r: Value) -> Bool {
        if l == r { return true }
        if let a = l.doubleValue, let b = r.doubleValue { return a == b }
        return false
    }

    static func callFunction(_ name: String, _ args: [Value], columns: [String], values: [Value]) throws -> Value {
        func str(_ i: Int) -> String { i < args.count ? args[i].display : "" }
        func num(_ i: Int) -> Double? { i < args.count ? args[i].doubleValue : nil }

        switch name {
        case "len": return .int(Int64(str(0).count))
        case "lower": return .string(str(0).lowercased())
        case "upper": return .string(str(0).uppercased())
        case "trim": return .string(str(0).trimmingCharacters(in: .whitespacesAndNewlines))
        case "contains": return .bool(str(0).contains(str(1)))
        case "starts_with": return .bool(str(0).hasPrefix(str(1)))
        case "ends_with": return .bool(str(0).hasSuffix(str(1)))
        case "replace": return .string(str(0).replacingOccurrences(of: str(1), with: str(2)))
        case "substr":
            let s = str(0)
            let start = Int(num(1) ?? 0)
            let length = args.count > 2 ? Int(num(2) ?? 0) : s.count - start
            guard start >= 0, start < s.count, length > 0 else { return .string("") }
            let from = s.index(s.startIndex, offsetBy: start)
            let to = s.index(from, offsetBy: min(length, s.count - start))
            return .string(String(s[from..<to]))
        case "concat": return .string(args.map(\.display).joined())
        case "coalesce":
            for a in args where !a.isNull { return a }
            return .null
        case "col":
            guard case .string(let colName)? = args.first,
                  let idx = columns.firstIndex(of: colName) else {
                throw AlembicError.expressionError("col() needs a valid column name")
            }
            return idx < values.count ? values[idx] : .null
        case "tokens":
            return .int(Int64(TokenizerProvider.current.countTokens(str(0))))
        case "words":
            return .int(Int64(str(0).split(whereSeparator: \.isWhitespace).count))
        case "lang":
            return .string(LanguageID.detect(str(0)).code)
        case "is_null":
            return .bool(args.first?.isNull ?? true)
        case "abs":
            if case .int(let i)? = args.first { return .int(abs(i)) }
            if let d = num(0) { return .double(abs(d)) }
            return .null
        case "round":
            guard let d = num(0) else { return .null }
            return .int(Int64(d.rounded()))
        case "min":
            guard let a = num(0), let b = num(1) else { return .null }
            return .double(Swift.min(a, b))
        case "max":
            guard let a = num(0), let b = num(1) else { return .null }
            return .double(Swift.max(a, b))
        case "if":
            guard args.count == 3 else { throw AlembicError.expressionError("if(cond, then, else) needs 3 arguments") }
            return truthy(args[0]) ? args[1] : args[2]
        default:
            throw AlembicError.expressionError("Unknown function: \(name)")
        }
    }
}
