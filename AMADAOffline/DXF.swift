import Foundation

enum DXF {
    static func generate(_ d: Drawing) throws -> Data {
        guard d.verified, d.issues.isEmpty else {
            throw NSError(domain: "AMADA", code: 2, userInfo: [NSLocalizedDescriptionKey: "図面の照合と寸法検証が必要です"])
        }
        // ASCII-only DXF R12, closed outline in CUT_OUTLINE and circles in CUT_HOLES.
        func f(_ n: Double) -> String { String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), n) }
        var tokens = ["0", "SECTION", "2", "HEADER", "9", "$INSUNITS", "70", "4", "0", "ENDSEC", "0", "SECTION", "2", "ENTITIES"]
        let w = d.width, h = d.height, c = d.chamfer
        let points: [(Double, Double)] = c > 0 ? [(c,0),(w-c,0),(w,c),(w,h-c),(w-c,h),(c,h),(0,h-c),(0,c)] : [(0,0),(w,0),(w,h),(0,h)]
        for i in points.indices {
            let p = points[i], q = points[(i+1)%points.count]
            tokens += ["0","LINE","8","CUT_OUTLINE","10",f(p.0),"20",f(p.1),"30","0","11",f(q.0),"21",f(q.1),"31","0"]
        }
        for hole in d.holes {
            tokens += ["0","CIRCLE","8","CUT_HOLES","10",f(hole.x),"20",f(hole.y),"30","0","40",f(hole.diameter/2)]
        }
        tokens += ["0","ENDSEC","0","EOF"]
        return Data((tokens.joined(separator: "\r\n") + "\r\n").utf8)
    }
}
