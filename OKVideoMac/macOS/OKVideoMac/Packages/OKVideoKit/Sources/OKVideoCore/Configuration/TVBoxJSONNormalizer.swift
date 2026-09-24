import Foundation

/// Normalizes the deliberately small JSONC dialect accepted by TVBox/Gson
/// configurations without broadening configuration parsing to JSON5.
///
/// Comments and trailing commas are replaced with spaces; Gson-style unquoted
/// names and literal string controls are encoded as standard JSON.
enum TVBoxJSONNormalizer {
    static func normalize(_ data: Data) throws -> Data {
        var bytes = try normalizeGsonKeysAndControls([UInt8](data))
        try replaceComments(in: &bytes)
        replaceTrailingCommas(in: &bytes)
        return Data(bytes)
    }

    /// Gson accepts unquoted object names and literal controls in strings.
    /// A name such as ext" is literally that name, not the known field ext.
    /// Preserve it as an unknown field rather than guessing provider intent.
    private static func normalizeGsonKeysAndControls(_ input: [UInt8]) throws -> [UInt8] {
        var output: [UInt8] = []
        var containers: [UInt8] = []
        var expectsKey = false
        var index = 0
        while index < input.count {
            let byte = input[index]
            // Leave comments intact for the existing comment normalizer.
            if byte == ascii("/"), index + 1 < input.count,
               input[index + 1] == ascii("/") || input[index + 1] == ascii("*") {
                let start = index
                let block = input[index + 1] == ascii("*")
                index += 2
                while index < input.count {
                    if !block && (input[index] == 10 || input[index] == 13) { break }
                    if block && index + 1 < input.count && input[index] == 42 && input[index + 1] == 47 {
                        index += 2
                        break
                    }
                    index += 1
                }
                output.append(contentsOf: input[start..<index])
                continue
            }
            if byte == ascii("\"") {
                output.append(byte)
                index += 1
                while index < input.count {
                    let current = input[index]
                    index += 1
                    if current == ascii("\\") {
                        output.append(current)
                        if index < input.count {
                            output.append(input[index])
                            index += 1
                        }
                    } else if current == ascii("\"") {
                        output.append(current)
                        break
                    } else if current < 0x20 {
                        output.append(contentsOf: String(format: "\\u%04x", current).utf8)
                    } else {
                        output.append(current)
                    }
                }
                continue
            }
            if expectsKey && !isJSONWhitespace(byte) && byte != ascii("}") {
                guard byte != ascii("'") else {
                    throw AppError.decoding("配置不支持单引号字段名")
                }
                let start = index
                // Gson's unquoted-name delimiters intentionally exclude quotes.
                let delimiters: Set<UInt8> = Set("{}[],:;=/\\#".utf8)
                while index < input.count,
                      !isJSONWhitespace(input[index]), !delimiters.contains(input[index]) {
                    index += 1
                }
                if index > start {
                    output.append(ascii("\""))
                    for character in input[start..<index] {
                        if character == ascii("\"") { output.append(ascii("\\")) }
                        output.append(character)
                    }
                    output.append(ascii("\""))
                    expectsKey = false
                    continue
                }
            }
            switch byte {
            case ascii("{"): containers.append(byte); expectsKey = true
            case ascii("["): containers.append(byte); expectsKey = false
            case ascii("}"), ascii("]"): _ = containers.popLast(); expectsKey = false
            case ascii(":"): expectsKey = false
            case ascii(","): expectsKey = containers.last == ascii("{")
            default: break
            }
            output.append(byte)
            index += 1
        }
        return output
    }

    private static func replaceComments(in bytes: inout [UInt8]) throws {
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == ascii("\\") {
                    isEscaped = true
                } else if byte == ascii("\"") {
                    isInsideString = false
                }
                index += 1
                continue
            }

            if byte == ascii("\"") {
                isInsideString = true
                index += 1
                continue
            }
            guard byte == ascii("/"), index + 1 < bytes.count else {
                index += 1
                continue
            }

            switch bytes[index + 1] {
            case ascii("/"):
                bytes[index] = ascii(" ")
                bytes[index + 1] = ascii(" ")
                index += 2
                while index < bytes.count,
                      bytes[index] != ascii("\n"),
                      bytes[index] != ascii("\r") {
                    bytes[index] = ascii(" ")
                    index += 1
                }

            case ascii("*"):
                bytes[index] = ascii(" ")
                bytes[index + 1] = ascii(" ")
                index += 2
                var didClose = false
                while index < bytes.count {
                    if index + 1 < bytes.count,
                       bytes[index] == ascii("*"),
                       bytes[index + 1] == ascii("/") {
                        bytes[index] = ascii(" ")
                        bytes[index + 1] = ascii(" ")
                        index += 2
                        didClose = true
                        break
                    }
                    if bytes[index] != ascii("\n"),
                       bytes[index] != ascii("\r") {
                        bytes[index] = ascii(" ")
                    }
                    index += 1
                }
                guard didClose else {
                    throw AppError.decoding("JSON 块注释未闭合")
                }

            default:
                index += 1
            }
        }
    }

    private static func replaceTrailingCommas(in bytes: inout [UInt8]) {
        var index = 0
        var isInsideString = false
        var isEscaped = false

        while index < bytes.count {
            let byte = bytes[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if byte == ascii("\\") {
                    isEscaped = true
                } else if byte == ascii("\"") {
                    isInsideString = false
                }
                index += 1
                continue
            }
            if byte == ascii("\"") {
                isInsideString = true
                index += 1
                continue
            }
            guard byte == ascii(",") else {
                index += 1
                continue
            }

            var lookahead = index + 1
            while lookahead < bytes.count, isJSONWhitespace(bytes[lookahead]) {
                lookahead += 1
            }
            if lookahead < bytes.count,
               bytes[lookahead] == ascii("}")
                || bytes[lookahead] == ascii("]") {
                bytes[index] = ascii(" ")
            }
            index += 1
        }
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == ascii(" ") || byte == ascii("\t")
            || byte == ascii("\n") || byte == ascii("\r")
    }

    private static func ascii(_ character: Character) -> UInt8 {
        character.asciiValue!
    }
}
