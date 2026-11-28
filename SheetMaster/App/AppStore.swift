import Foundation
import Observation
import UIKit

enum TileMode: String, Codable, CaseIterable, Identifiable {
    case standard   // 全体 + 2×2拡大
    case detail     // 全体 + 3×3拡大
    var id: String { rawValue }
    var label: String { self == .standard ? "標準(全体+4分割)" : "細部重視(全体+9分割)" }
    var grid: Int { self == .standard ? 2 : 3 }
}

struct AppSettings: Codable {
    var model: String = "claude-opus-5-5"
    var tileMode: TileMode = .standard
    var includeBendLayer: Bool = false
    var asciiFileNames: Bool = true
    var deductions: [DeductionRow] = AppSettings.defaultDeductions
    var tapDrills: [TapDrillRow] = AppSettings.defaultTaps

    static let models: [(id: String, label: String)] = [
        ("claude-opus-5-5", "Opus 5.5(高精度・おすすめ)"),
        ("claude-sonnet-5-5", "Sonnet 5.5(速い・安い)")
    ]

    /// ※すべて仮値。会社の曲げ控除表で必ず置き換えること
    static let defaultDeductions: [DeductionRow] = {
        let spcc: [(Double, Double, Double)] = [(1.0, 6, 1.8), (1.2, 8, 2.1), (1.6, 10, 2.8), (2.0, 12, 3.5),
                                                (2.3, 16, 4.0), (3.2, 20, 5.5), (4.5, 32, 7.5), (6.0, 40, 10.0)]
        let sus: [(Double, Double, Double)] = [(1.0, 6, 2.0), (1.2, 8, 2.3), (1.5, 10, 2.8), (2.0, 12, 3.7),
                                               (3.0, 20, 5.5), (4.0, 25, 7.0)]
        let al: [(Double, Double, Double)] = [(1.0, 6, 1.7), (1.5, 10, 2.5), (2.0, 12, 3.3), (3.0, 20, 5.0)]
        return spcc.map { DeductionRow(materialGroup: "SPCC", thickness: $0.0, vWidth: $0.1, value90: $0.2) }
            + sus.map { DeductionRow(materialGroup: "SUS", thickness: $0.0, vWidth: $0.1, value90: $0.2) }
            + al.map { DeductionRow(materialGroup: "AL", thickness: $0.0, vWidth: $0.1, value90: $0.2) }
    }()

    static let defaultTaps: [TapDrillRow] = [
        TapDrillRow(size: "M2", drill: 1.6), TapDrillRow(size: "M2.5", drill: 2.1),
        TapDrillRow(size: "M3", drill: 2.5), TapDrillRow(size: "M4", drill: 3.3),
        TapDrillRow(size: "M5", drill: 4.2), TapDrillRow(size: "M6", drill: 5.0),
        TapDrillRow(size: "M8", drill: 6.8), TapDrillRow(size: "M10", drill: 8.5),
        TapDrillRow(size: "M12", drill: 10.2)
    ]

    func deduction(material: String, thickness: Double) -> DeductionRow? {
        let g = materialGroup(material)
        return deductions.first { $0.materialGroup == g && abs($0.thickness - thickness) < 0.05 }
    }
}

@Observable
final class AppStore {
    var drawings: [DrawingRecord] = []
    var settings = AppSettings() { didSet { saveSettings() } }

    var apiKey: String {
        get { Keychain.read("claude_api_key") ?? "" }
        set { Keychain.write("claude_api_key", value: newValue) }
    }

    private let fm = FileManager.default
    private var docs: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    /// v3.5: 「書類」フォルダは「ファイル」アプリに見えるようにしたので、アプリのデータは見えない場所へ移す
    private var dataDir: URL {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SheetMasterData", isDirectory: true)
        if !fm.fileExists(atPath: u.path) { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
        return u
    }
    private var drawingsURL: URL { dataDir.appendingPathComponent("drawings_v24.json") }
    private var settingsURL: URL { dataDir.appendingPathComponent("settings_v24.json") }
    var imagesDir: URL {
        let u = dataDir.appendingPathComponent("images", isDirectory: true)
        if !fm.fileExists(atPath: u.path) { try? fm.createDirectory(at: u, withIntermediateDirectories: true) }
        return u
    }

    init() {
        migrateFromDocuments()
        load()
    }

    /// v3.4以前は「書類」に保存していたデータを、見えない場所へ移す(1回だけ)
    private func migrateFromDocuments() {
        for name in ["drawings_v24.json", "settings_v24.json", "images"] {
            let old = docs.appendingPathComponent(name)
            let new = dataDir.appendingPathComponent(name)
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            }
        }
    }

    func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: drawingsURL), let v = try? dec.decode([DrawingRecord].self, from: d) {
            drawings = v
        }
        if let d = try? Data(contentsOf: settingsURL), let v = try? dec.decode(AppSettings.self, from: d) {
            settings = v
        }
    }

    func save() {
        if let d = try? JSONEncoder().encode(drawings) { try? d.write(to: drawingsURL, options: .atomic) }
    }

    private func saveSettings() {
        if let d = try? JSONEncoder().encode(settings) { try? d.write(to: settingsURL, options: .atomic) }
    }

    func upsert(_ rec: DrawingRecord) {
        if let i = drawings.firstIndex(where: { $0.id == rec.id }) { drawings[i] = rec } else { drawings.insert(rec, at: 0) }
        save()
    }

    func delete(_ rec: DrawingRecord) {
        drawings.removeAll { $0.id == rec.id }
        for f in rec.imageFiles { try? fm.removeItem(at: imagesDir.appendingPathComponent(f)) }
        save()
    }

    func storeImage(_ img: UIImage) -> String? {
        let name = UUID().uuidString + ".jpg"
        guard let data = img.jpegData(compressionQuality: 0.9) else { return nil }
        do { try data.write(to: imagesDir.appendingPathComponent(name)); return name } catch { return nil }
    }

    func loadImage(_ name: String) -> UIImage? {
        UIImage(contentsOfFile: imagesDir.appendingPathComponent(name).path)
    }
}
