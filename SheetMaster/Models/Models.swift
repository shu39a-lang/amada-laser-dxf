import Foundation

// MARK: - 基本型

struct P2: Codable, Hashable {
    var x: Double
    var y: Double
}

struct ArcSpec: Codable, Hashable {
    /// 円弧の中心(この頂点 → 次の頂点 を円弧で結ぶ)
    var cx: Double
    var cy: Double
    /// true = 時計回り
    var clockwise: Bool
}

enum CornerType: String, Codable, CaseIterable, Identifiable {
    case none, chamfer, radius
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none: return "なし"
        case .chamfer: return "C面取り"
        case .radius: return "R"
        }
    }
}

struct OutlineVertex: Codable, Hashable, Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var cornerType: CornerType = .none
    var cornerSize: Double = 0
    var arcToNext: ArcSpec? = nil
    /// v3.0: 推定した頂点(要確認)。理由の文章。nil なら確かな頂点
    var check: String? = nil

    enum CodingKeys: String, CodingKey { case x, y, cornerType, cornerSize, arcToNext, check }
}

enum HoleType: String, Codable, CaseIterable, Identifiable {
    case circle, slot, rect, polygon
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circle: return "丸穴"
        case .slot: return "長穴"
        case .rect: return "角穴"
        case .polygon: return "多角形"
        }
    }
}

struct Hole: Codable, Hashable, Identifiable {
    var id = UUID()
    var type: HoleType = .circle
    // circle / rect
    var cx: Double = 0
    var cy: Double = 0
    var d: Double = 0
    // slot(両端の円の中心と幅)
    var x1: Double = 0
    var y1: Double = 0
    var x2: Double = 0
    var y2: Double = 0
    var width: Double = 0
    // rect
    var w: Double = 0
    var h: Double = 0
    var angle: Double = 0
    var cornerR: Double = 0
    // polygon
    var points: [P2] = []
    var note: String = ""
    /// v2.9: 写真の中でこの穴が描かれている位置(見比べ画面用)。
    ///  photoNo = 何枚目の写真か(1〜)、photoX / photoY = その写真の幅・高さに対する割合(0〜1、左上が原点)
    ///  古いデータには無いので Optional
    var photoNo: Int? = nil
    var photoX: Double? = nil
    var photoY: Double? = nil
    /// v3.0: 推定した穴(要確認)。理由の文章
    var check: String? = nil

    enum CodingKeys: String, CodingKey {
        case type, cx, cy, d, x1, y1, x2, y2, width, w, h, angle, cornerR, points, note, photoNo, photoX, photoY, check
    }
}

enum BendAxis: String, Codable, CaseIterable, Identifiable {
    /// x = 縦の曲げ線(x = position の直線)
    case x
    /// y = 横の曲げ線(y = position の直線)
    case y
    var id: String { rawValue }
    var label: String { self == .x ? "縦線(X位置)" : "横線(Y位置)" }
}

struct Bend: Codable, Hashable, Identifiable {
    var id = UUID()
    var axis: BendAxis = .x
    var position: Double = 0
    var angleDeg: Double = 90
    var up: Bool = true
    var note: String = ""
    /// 曲げ線の範囲(縦線ならY、横線ならXの始点・終点)。nil なら板の端から端まで
    var from: Double? = nil
    var to: Double? = nil

    enum CodingKeys: String, CodingKey { case axis, position, angleDeg, up, note, from, to }
}

struct KeyDimension: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String
    var value: Double
    /// "x" = 展開前の全体横寸法, "y" = 全体縦寸法, "none" = 参考
    var axis: String

    enum CodingKeys: String, CodingKey { case label, value, axis }
}

enum DevelopMode: String, Codable {
    /// 曲げなし。座標は図面寸法そのまま
    case flat
    /// 曲げあり。外寸を足し合わせた座標(控除はアプリが引く)。v2.5までの方式(箱形の角が正しく出ない)
    case outerDims
    /// 曲げあり。基準面+フランジの外寸だけを受け取り、展開座標はアプリが計算する(v2.6〜)
    case faces
    /// 曲げあり。前板(段付き・L字など、辺が縦横だけの多角形)+辺ごとの側壁。
    ///  内角で重なる側壁の切り分け・逃げ・角の切り欠きはアプリが計算する(v3.3〜)
    case plateWalls
}

// MARK: - 面モデル(曲げ部品)

/// 角の処理(フランジ先端の角: at = "start" / "end"、基準面の角: "bottom_left" など)
struct FaceCorner: Codable, Hashable {
    var at: String
    var type: CornerType
    var size: Double
}

/// フランジ(基準面の辺、または別のフランジの先端から曲がる面)
struct FaceFlange: Codable, Hashable, Identifiable {
    var id: String
    var name: String = ""
    /// "base" または親フランジの id
    var parent: String = "base"
    /// 親が base: bottom / top / left / right。親がフランジ: free(親の先端)
    var edge: String = "bottom"
    /// 曲げの外側の面から先端までの外寸
    var length: Double = 0
    /// true = length は内側の面から(アプリが板厚を足す)
    var lengthInner: Bool = false
    var angleDeg: Double = 90
    var up: Bool = false
    /// 辺に沿った範囲(基準面の座標)。nil = 辺の全長
    var start: Double? = nil
    var end: Double? = nil
    var corners: [FaceCorner] = []
}

/// 面の上の穴・切欠き
struct FaceFeature: Codable, Hashable, Identifiable {
    var id = UUID()
    /// "base" またはフランジの id
    var face: String = "base"
    /// "hole" / "notch"
    var kind: String = "hole"
    /// 穴(面の座標: cx = a(辺に沿った位置), cy = d(先端からの距離)。base は X, Y)
    var hole: Hole = Hole()
    // 切欠き
    /// フランジ: free / start / end、base: bottom / top / left / right
    var edge: String = "free"
    var center: Double = 0
    var width: Double = 0
    /// 縁から奥まで(丸端なら半円の中心まで)
    var depth: Double = 0
    var roundEnd: Bool = true
    var mouthR: Double = 0

    enum CodingKeys: String, CodingKey { case face, kind, hole, edge, center, width, depth, roundEnd, mouthR }
}

struct FaceModel: Codable, Hashable {
    var baseName: String = "基準面"
    /// 基準面の外寸(外側を手前にして、横・縦)
    var width: Double = 0
    var height: Double = 0
    var baseCorners: [FaceCorner] = []
    var flanges: [FaceFlange] = []
    var features: [FaceFeature] = []
}

// MARK: - 前板+側壁モデル(v3.3)

/// 前板の辺に付く側壁
struct PlateWall: Codable, Hashable {
    /// 辺の番号(0〜。頂点 edge → 頂点 edge+1)
    var edge: Int
    /// 側壁の奥行(外寸)
    var depth: Double
    var angleDeg: Double = 90
    var up: Bool = false
}

/// 側壁の上の穴
struct PlateWallHole: Codable, Hashable {
    var edge: Int
    /// 辺に沿った位置(前板と同じ座標。横の辺ならX、縦の辺ならY)
    var along: Double
    /// 側壁の先端(前板から遠い方の縁)からの距離
    var fromFree: Double
    /// 丸穴(径 d、要確認 check、写真の位置 photo… をそのまま使う)
    var hole: Hole
}

struct PlateModel: Codable, Hashable {
    /// 前板の外形(外寸、反時計回り。辺は縦か横だけ)
    var outline: [P2] = []
    var walls: [PlateWall] = []
    /// 前板の穴(前板の外寸の座標)
    var holes: [Hole] = []
    var wallHoles: [PlateWallHole] = []
}

struct FlatPattern: Codable, Hashable {
    var developedBy: DevelopMode = .flat
    var outline: [OutlineVertex] = []
    var holes: [Hole] = []
    var bends: [Bend] = []
    var keyDimensions: [KeyDimension] = []
    var uncertain: [String] = []
    var analysis: String = ""
    var confidence: Double = 0
    /// AIの返答そのもの(原因調査用)
    var rawJSON: String? = nil
    /// 曲げ部品の面モデル(developedBy == .faces のとき)
    var faces: FaceModel? = nil
    /// v3.3: 前板+側壁モデル(developedBy == .plateWalls のとき)
    var plate: PlateModel? = nil
}

enum PartProcess: String, Codable, CaseIterable, Identifiable {
    case laser, machined, purchased, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .laser: return "レーザー(板)"
        case .machined: return "機械加工品"
        case .purchased: return "購入品"
        case .other: return "その他"
        }
    }
}

struct Part: Codable, Hashable, Identifiable {
    var id = UUID()
    var partKey: String = "P1"
    var name: String = ""
    var material: String = ""
    var thickness: Double? = nil
    /// explicit / inferred / unknown / user
    var thicknessSource: String = "unknown"
    var thicknessEvidence: String = ""
    var process: PartProcess = .laser
    var quantity: Int = 1
    var mirrorPair: Bool = false
    var bendsCount: Int = 0
    var viewsDescription: String = ""
    var confidence: Double = 0
    var flat: FlatPattern? = nil
    var readError: String? = nil
    var userHint: String = ""
    var include: Bool = true
    /// v3.0: 部品表に無い板。"ai" = AIが見つけて追加、"user" = 作業者が「板を追加して読む」で追加。nil = 部品表どおり
    var addedBy: String? = nil
    /// v3.1: 見比べ画面で手で合わせた写真の位置 [写真番号, ar, ai, br, bi, 写真の幅]
    var manualAlign: [Double]? = nil
    /// v3.6: 「形から部品を作る」で作った部品の形の種類(ShapeKind の rawValue)。nil = 図面から読んだ部品
    ///  この部品は展開を読みに行かない(作業者が入れた寸法で展開済み)
    var shapeKind: String? = nil

    var groupKey: String {
        let mat = material.isEmpty ? "材質未確定" : material
        guard let t = thickness else { return "\(mat) 板厚未確定" }
        return "\(mat) t\(Fmt.num(t))"
    }

    enum CodingKeys: String, CodingKey {
        case partKey, name, material, thickness, thicknessSource, thicknessEvidence, process,
             quantity, mirrorPair, bendsCount, viewsDescription, confidence, flat, readError, userHint, include, addedBy, manualAlign, shapeKind
    }
}

struct DrawingRecord: Codable, Hashable, Identifiable {
    var id = UUID()
    var createdAt = Date()
    var drawingNumber: String = ""
    var title: String = ""
    var productNumber: String = ""
    var notes: [String] = []
    var questions: [String] = []
    var imageFiles: [String] = []
    var parts: [Part] = []
    var appVersion: String = AppInfo.version
    var analysis: String = ""
    /// 段階AのAIの返答そのもの(原因調査用)
    var rawInventory: String? = nil
    /// v3.5: 図面を出した会社(表題欄の会社名)。DXFの保存フォルダ名に使う
    var company: String? = nil
    /// v3.6: true = 部品一覧を確かめている途中(まだ展開を読んでいない)。nil / false = 展開まで済み
    var reviewPending: Bool? = nil
    /// v3.6: 読み取りの前に作業者が入れた前提(例:「部品は8種類。板厚違いは1種類」)
    var hints: String? = nil
}

// MARK: - 設定テーブル

struct DeductionRow: Codable, Hashable, Identifiable {
    var id = UUID()
    /// SPCC / SUS / AL
    var materialGroup: String
    var thickness: Double
    var vWidth: Double
    /// 90°曲げ1回あたりの控除値(mm)
    var value90: Double
    var provisional: Bool = true
}

struct TapDrillRow: Codable, Hashable, Identifiable {
    var id = UUID()
    var size: String   // "M3"
    var drill: Double  // 2.5
}

enum AppInfo {
    static let version = "3.7"
}

enum Fmt {
    static func num(_ v: Double) -> String {
        if abs(v - v.rounded()) < 0.0005 { return String(Int(v.rounded())) }
        var s = String(format: "%.3f", v)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}

/// 材質名を控除表のグループにまとめる
func materialGroup(_ material: String) -> String {
    let m = material.uppercased()
    if m.contains("SUS") || m.contains("ステン") { return "SUS" }
    if m.hasPrefix("A") && !m.hasPrefix("AL") && m.count >= 5, m.dropFirst().first?.isNumber == true { return "AL" }
    if m.contains("AL") || m.contains("アルミ") || m.contains("A5052") || m.contains("A1100") { return "AL" }
    return "SPCC"
}
