package cjdist

import std.collection.ArrayList
import std.convert.*

// This is deliberately a small, strict parser for the JSON value forms emitted
// by CJDist's fixed manifest serializer. It is not advertised as a general JSON library.
class JsonMember {
    let name: String
    let value: JsonValue
    public init(name: String, value: JsonValue) { this.name = name; this.value = value }
}

class JsonValue {
    let kind: String
    let text: String
    let number: Int64
    let members: Array<JsonMember>
    let elements: Array<JsonValue>

    public init(kind: String, text: String, number: Int64, members: Array<JsonMember>, elements: Array<JsonValue>) {
        this.kind = kind; this.text = text; this.number = number
        this.members = members; this.elements = elements
    }
}

class JsonParseResult {
    let success: Bool
    let value: ?JsonValue
    let error: String
    public init(value: JsonValue) { success = true; this.value = Some(value); error = "" }
    public init(error: String) { success = false; value = None; this.error = error }
}

func parseStrictJson(source: String): JsonParseResult {
    return StrictJsonParser(source).parse()
}

private class StrictJsonParser {
    let source: String
    let bytes: Array<Byte>
    var position: Int64 = 0
    var failure: String = ""

    public init(source: String) { this.source = source; this.bytes = source.toArray() }

    public func parse(): JsonParseResult {
        skipWhitespace()
        let parsed = parseValue()
        if (!failure.isEmpty()) { return JsonParseResult(failure) }
        skipWhitespace()
        if (position != bytes.size) { return JsonParseResult("trailing data after the JSON value at byte ${position}") }
        return match (parsed) {
            case Some(value) => JsonParseResult(value)
            case None => JsonParseResult("missing JSON value")
        }
    }

    private func parseValue(): ?JsonValue {
        skipWhitespace()
        if (position >= bytes.size) { fail("unexpected end of JSON"); return None }
        let byte = bytes[position]
        if (byte == 123) { return parseObject() }
        if (byte == 91) { return parseArray() }
        if (byte == 34) {
            let value = parseString()
            if (!failure.isEmpty()) { return None }
            return Some(JsonValue("string", value, 0, [], []))
        }
        if (byte == 45 || (byte >= 48 && byte <= 57)) { return parseInteger() }
        fail("unsupported JSON value at byte ${position}")
        return None
    }

    private func parseObject(): ?JsonValue {
        position++
        let members = ArrayList<JsonMember>()
        skipWhitespace()
        if (consume(125)) { return Some(JsonValue("object", "", 0, members.toArray(), [])) }
        while (true) {
            skipWhitespace()
            if (position >= bytes.size || bytes[position] != 34) { fail("object key must be a string at byte ${position}"); return None }
            let name = parseString()
            if (!failure.isEmpty()) { return None }
            for (member in members) {
                if (member.name == name) { fail("duplicate object key '${name}'"); return None }
            }
            skipWhitespace()
            if (!consume(58)) { fail("expected ':' after object key '${name}'"); return None }
            let value = parseValue()
            if (!failure.isEmpty()) { return None }
            match (value) { case Some(item) => members.add(JsonMember(name, item)); case None => return None }
            skipWhitespace()
            if (consume(125)) { break }
            if (!consume(44)) { fail("expected ',' or '}' at byte ${position}"); return None }
        }
        return Some(JsonValue("object", "", 0, members.toArray(), []))
    }

    private func parseArray(): ?JsonValue {
        position++
        let values = ArrayList<JsonValue>()
        skipWhitespace()
        if (consume(93)) { return Some(JsonValue("array", "", 0, [], values.toArray())) }
        while (true) {
            let value = parseValue()
            if (!failure.isEmpty()) { return None }
            match (value) { case Some(item) => values.add(item); case None => return None }
            skipWhitespace()
            if (consume(93)) { break }
            if (!consume(44)) { fail("expected ',' or ']' at byte ${position}"); return None }
        }
        return Some(JsonValue("array", "", 0, [], values.toArray()))
    }

    private func parseString(): String {
        position++
        let builder = StringBuilder()
        var chunkStart = position
        while (position < bytes.size) {
            let byte = bytes[position]
            if (byte == 34) {
                if (position > chunkStart) { builder.append(source[chunkStart..position]) }
                position++
                return builder.toString()
            }
            if (byte < 32) { fail("unescaped control byte in JSON string at byte ${position}"); return "" }
            if (byte != 92) { position++; continue }
            if (position > chunkStart) { builder.append(source[chunkStart..position]) }
            position++
            if (position >= bytes.size) { fail("unterminated JSON escape"); return "" }
            let escape = bytes[position]
            position++
            if (escape == 34) { builder.append("\"") }
            else if (escape == 92) { builder.append("\\") }
            else if (escape == 47) { builder.append("/") }
            else if (escape == 98) { builder.append(String.fromUtf8([8])) }
            else if (escape == 102) { builder.append(String.fromUtf8([12])) }
            else if (escape == 110) { builder.append("\n") }
            else if (escape == 114) { builder.append("\r") }
            else if (escape == 116) { builder.append("\t") }
            else if (escape == 117) {
                if (position + 4 > bytes.size) { fail("incomplete Unicode escape"); return "" }
                var value: Int64 = 0
                for (index in 0..4) {
                    let digit = hexDigit(bytes[position + index])
                    if (digit < 0) { fail("invalid Unicode escape at byte ${position - 2}"); return "" }
                    value = value * 16 + digit
                }
                position += 4
                // The CJDist serializer uses \u escapes only for ASCII controls.
                // Reject other code points rather than implementing them incorrectly.
                if (value > 127) { fail("Unicode escape outside CJDist's supported manifest subset"); return "" }
                builder.append(String.fromUtf8([UInt8(value)]))
            } else { fail("invalid JSON escape at byte ${position - 2}"); return "" }
            chunkStart = position
        }
        fail("unterminated JSON string")
        return ""
    }

    private func parseInteger(): ?JsonValue {
        let start = position
        if (bytes[position] == 45) {
            position++
            if (position >= bytes.size) { fail("incomplete JSON integer"); return None }
        }
        if (bytes[position] == 48) {
            position++
            if (position < bytes.size && bytes[position] >= 48 && bytes[position] <= 57) {
                fail("leading zero in JSON integer at byte ${start}"); return None
            }
        } else {
            if (bytes[position] < 49 || bytes[position] > 57) { fail("invalid JSON integer at byte ${start}"); return None }
            while (position < bytes.size && bytes[position] >= 48 && bytes[position] <= 57) { position++ }
        }
        let raw = source[start..position]
        return match (Int64.tryParse(raw)) {
            case Some(value) => Some(JsonValue("integer", "", value, [], []))
            case None => fail("JSON integer is outside Int64 range at byte ${start}"); None
        }
    }

    private func skipWhitespace(): Unit {
        while (position < bytes.size) {
            let byte = bytes[position]
            if (byte == 32 || byte == 9 || byte == 10 || byte == 13) { position++ } else { break }
        }
    }
    private func consume(expected: Byte): Bool {
        if (position < bytes.size && bytes[position] == expected) { position++; return true }
        return false
    }
    private func fail(message: String): Unit { if (failure.isEmpty()) { failure = message } }
    private func hexDigit(byte: Byte): Int64 {
        if (byte >= 48 && byte <= 57) { return Int64(byte - 48) }
        if (byte >= 65 && byte <= 70) { return Int64(byte - 65 + 10) }
        if (byte >= 97 && byte <= 102) { return Int64(byte - 97 + 10) }
        return -1
    }
}
