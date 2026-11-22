import Foundation

// Compile the actual production Models.swift and DXF.swift with these tests.
@main
struct DXFSmokeTest {
    static func main() throws {
        var drawing = Drawing()
        drawing.verified = true
        drawing.width = 100
        drawing.height = 50
        drawing.chamfer = 5
        drawing.thickness = 2
        drawing.holes = [Hole(x: 25, y: 20, diameter: 8)]
        precondition(drawing.issues.isEmpty, "valid geometry rejected")
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
        var draft = drawing
        draft.verified = false
        draft.thickness = 0
        let preview = try DXF.preview(draft)
        precondition(preview == data, "2D preview changed the parsed hole positions")
        precondition((try? DXF.generate(draft)) == nil, "unverified production export allowed")
        draft.holes[0].diameter = 0
        precondition((try? DXF.preview(draft)) == nil, "missing hole diameter exported")
        var invalid = drawing
        invalid.verified = false
        precondition((try? DXF.generate(invalid)) == nil, "unverified cuts must not export")
        invalid.verified = true
        invalid.holes = [Hole(x: 1, y: 1, diameter: 8)]
        precondition(!invalid.issues.isEmpty, "out-of-bounds hole accepted")
        precondition((try? DXF.generate(invalid)) == nil, "invalid geometry must not export")
        var overlap = drawing
        overlap.holes.append(Hole(x: 28, y: 20, diameter: 8))
        precondition(overlap.issues.contains(where: { $0.contains("重なっています") }), "overlap accepted")
        var chamferCollision = drawing
        chamferCollision.holes = [Hole(x: 5, y: 5, diameter: 10)]
        precondition(chamferCollision.issues.contains(where: { $0.contains("角C") }), "chamfer collision accepted")
        var noChamfer = drawing
        noChamfer.chamfer = 0
        let normalDXF = String(data: try DXF.generate(noChamfer), encoding: .utf8)!
        precondition(normalDXF.components(separatedBy: "\r\n").filter { $0 == "LINE" }.count == 4, "rectangle edge count")
        var invalidWidth = drawing
        invalidWidth.width = -1
        precondition(!invalidWidth.issues.isEmpty, "negative width accepted")
        precondition((try? DXF.generate(invalidWidth)) == nil, "negative width exported")
        var invalidThickness = drawing
        invalidThickness.thickness = .nan
        precondition(!invalidThickness.issues.isEmpty, "NaN thickness accepted")
        var invalidChamfer = drawing
        invalidChamfer.chamfer = 25
        precondition(!invalidChamfer.issues.isEmpty, "degenerate chamfer accepted")
        var diameterOverflow = drawing
        diameterOverflow.holes = [Hole(x: 50, y: 25, diameter: 200)]
        precondition(!diameterOverflow.issues.isEmpty, "oversized hole accepted")
        var touchingHoles = drawing
        touchingHoles.holes = [Hole(x: 25, y: 20, diameter: 8), Hole(x: 33, y: 20, diameter: 8)]
        precondition(!touchingHoles.issues.contains(where: { $0.contains("重なっています") }),
                     "tangent holes should not be treated as overlapping")
        print("DXF and geometry validation tests passed")
    }
}
