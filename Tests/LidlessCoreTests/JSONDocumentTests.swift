import Foundation
import Testing
import LidlessCore

@Suite("JSON documents are rewritten without collateral changes")
struct JSONDocumentTests {
    @Test func aFileWrittenByNodeRoundTripsByteForByte() throws {
        let text = """
        {
          "model": "opus",
          "permissions": {
            "allow": [
              "Bash(npm run test:*)",
              "Read(~/.zshrc)"
            ],
            "deny": []
          },
          "env": {},
          "ratio": 0.10,
          "big": 12345678901234567890,
          "exp": 1E+3,
          "negative": -0,
          "enabled": true,
          "disabled": false,
          "nothing": null,
          "path": "C:\\\\Users\\\\me",
          "quote": "say \\"hi\\"\\n\\tbye",
          "accents": "déjà vu — ✓ 😀",
          "url": "https://example.com/a/b"
        }

        """
        #expect(try JSONDocument(text: text).text == text)
    }

    @Test func keepsTheIndentationTheFileAlreadyUses() throws {
        let fourSpaces = "{\n    \"a\": {\n        \"b\": [\n            1\n        ]\n    }\n}"
        #expect(try JSONDocument(text: fourSpaces).text == fourSpaces)

        let tabs = "{\n\t\"a\": {\n\t\t\"b\": true\n\t}\n}\n"
        #expect(try JSONDocument(text: tabs).text == tabs)
    }

    @Test func aSingleLineFileStaysOnASingleLine() throws {
        let compact = #"{"a":1,"b":[true,null,"x"],"c":{}}"#
        #expect(try JSONDocument(text: compact).text == compact)
    }

    @Test func newKeysGoAfterTheExistingOnesAndReplacedKeysKeepTheirPlace() throws {
        var document = try JSONDocument(text: #"{"z":1,"a":2,"m":3}"#)
        guard case .object(var object) = document.root else {
            Issue.record("expected an object")
            return
        }
        object["a"] = .string("changed")
        object["new"] = .bool(true)
        object["z"] = nil
        document.root = .object(object)

        #expect(document.text == #"{"a":"changed","m":3,"new":true}"#)
    }

    @Test func decodesEscapesAndSurrogatePairs() throws {
        let document = try JSONDocument(text: #"["\u00e9\n\"\\\/", "\ud83d\ude00"]"#)
        #expect(document.root == .array([.string("é\n\"\\/"), .string("😀")]))
    }

    @Test func escapesWhatJSONRequiresAndNothingElse() throws {
        var document = try JSONDocument(text: "[]")
        document.root = .array([.string("tab\there \"quoted\" back\\slash \u{01} é / ✓")])
        #expect(document.text == #"["tab\there \"quoted\" back\\slash \u0001 é / ✓"]"#)
    }

    @Test(arguments: [
        "",
        "   ",
        "{",
        #"{"a":1,}"#,
        #"{"a":1} trailing"#,
        "{\n  // a comment\n  \"a\": 1\n}",
        #"{"a":01}"#,
        #"{"a":"unterminated}"#,
        #"{a:1}"#,
        #"["\ud83d"]"#,
        "[1 2]",
        "nul",
    ])
    func refusesAnythingThatIsNotStrictJSON(text: String) {
        #expect(throws: JSONParseError.self) {
            try JSONDocument(text: text)
        }
    }
}
