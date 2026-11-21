import Foundation

// Independent test fixture: compile the shipping DXF.swift without SwiftUI.
struct Hole {
    var x: Double
    var y: Double
    var diameter: Double
}

struct Drawing {
    var verified: Bool
    var width: Double
    var height: Double
    var chamfer: Double
    var holes: [Hole]
    var issues: [String] = []
}

@main
struct DXFSmokeTest {
    static func main() throws {
        let drawing = Drawing(
            verified: true, width: 100, height: 50, chamfer: 5,
            holes: [Hole(x: 25, y: 20, diameter: 8)]
        )
        let data = try DXF.generate(drawing)
        guard let text = String(data: data, encoding: .utf8) else {
            fatalError("DXF output is not UTF-8")
        }
        let tokens = text.components(separatedBy: "\r\n")
        func hasSequence(_ items: [String]) -> Bool {
            guard tokens.count >= items.count else { return false }
            for i in 0...(tokens.count - items.count) {
                if Array(tokens[i..<(i + items.count)]) == items { return true }
            }
            return false
        }
        precondition(hasSequence(["9", "$ACADVER", "1", "AC1009"]), "R12 header")
        precondition(hasSequence(["2", "LAYER", "70", "2"]), "layer table")
        precondition(hasSequence(["0", "LAYER", "2", "CUT_OUTLINE"]), "outline layer")
        precondition(hasSequence(["0", "LAYER", "2", "CUT_HOLES"]), "hole layer")
        precondition(hasSequence(["0", "CIRCLE", "8", "CUT_HOLES", "10", "25.0000", "20", "20.0000", "30", "0", "40", "4.0000"]), "hole size and position")
        precondition(tokens.filter { $0 == "LINE" }.count == 8, "8 chamfered outline edges")
        precondition(hasSequence(["0", "EOF"]), "DXF ends with EOF")
        var invalid = drawing
        invalid.verified = false
        precondition((try? DXF.generate(invalid)) == nil, "unverified cuts must not export")
        invalid.verified = true
        invalid.issues = ["invalid hole"]
        precondition((try? DXF.generate(invalid)) == nil, "invalid geometry must not export")
        print("DXF smoke test passed")
    }
}
