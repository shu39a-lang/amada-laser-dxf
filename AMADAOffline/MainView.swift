import SwiftUI
import PhotosUI
import UIKit

struct MainView: View {
    private let masterRed = Color(red: 0.38, green: 0.045, blue: 0.068)
    private let masterYellow = Color(red: 1, green: 0.82, blue: 0.13)
    @State private var selected: PhotosPickerItem?
    @State private var cameraShown = false
    @State private var photo: UIImage?
    @State private var recognitionID = UUID()
    @State private var busy = false
    @State private var showingResult = false
    @State private var drawing = Drawing()
    @State private var message = ""
    @State private var exportURL: URL?
    @State private var previewOriginal = false
    @State private var editing: EditTarget?
    @State private var input = ""
    @State private var error = ""
    @State private var verifiedAgainstOriginal = false
    @State private var detectedText: [String] = []
    @State private var recognitionSummary = ""

    private enum EditTarget: Hashable, Identifiable {
        case width, height, thickness, chamfer, x(UUID), y(UUID), diameter(UUID)
        var id: Self { self }
        var title: String {
            switch self {
            case .width: return "外形幅"
            case .height: return "外形高さ"
            case .thickness: return "板厚"
            case .chamfer: return "角C"
            case .x: return "中心X"
            case .y: return "中心Y"
            case .diameter: return "直径Φ"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("SHEET MASTER").font(.system(size: 29, weight: .black, design: .rounded))
                        Text(showingResult ? "② 図面の数値を確認" : "① 図面を撮影・選択")
                            .font(.title2.bold()).foregroundStyle(masterYellow)
                        if showingResult {
                            if busy {
                                VStack(spacing: 12) {
                                    if let photo {
                                        Image(uiImage: photo)
                                            .resizable().scaledToFit().frame(maxHeight: 195)
                                    }
                                    ProgressView("Google OCRで図面を読み取り中…")
                                    Text("寸法・穴数・中心座標・穴径を確認しています")
                                        .font(.caption).foregroundStyle(.white)
                                }.frame(maxWidth: .infinity, minHeight: 180)
                            } else { result }
                        } else {
                            if let photo {
                                Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 220)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                VStack(spacing: 10) {
                                    Image(systemName: "doc.viewfinder").font(.system(size: 44))
                                    Text("図面を撮影するか、写真から選んでください").font(.subheadline)
                                }
                                .frame(maxWidth: .infinity, minHeight: 165)
                                .background(Color.black.opacity(0.28), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Button { cameraShown = true } label: {
                                Label("図面を撮影する", systemImage: "camera")
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }.buttonStyle(MasterYellowButton()).disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                            PhotosPicker(selection: $selected, matching: .images) {
                                Label("写真から選ぶ", systemImage: "photo").frame(maxWidth: .infinity, minHeight: 52)
                            }.buttonStyle(MasterYellowButton())
                            if photo != nil {
                                Button("読み取り結果を表示") { showingResult = true }.buttonStyle(MasterYellowButton())
                            }
                        }
                        if !message.isEmpty { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    }.frame(maxWidth: 680).padding().frame(maxWidth: .infinity)
                }
                if showingResult {
                    HStack {
                        Button("戻る") { showingResult = false }.buttonStyle(.bordered)
                        if let exportURL {
                            ShareLink(item: exportURL) { Text("DXFを保存・共有").frame(maxWidth: .infinity) }
                                .buttonStyle(MasterYellowButton())
                        } else {
                            Button { createDXF() } label: { Text("確認済みDXFを作る").frame(maxWidth: .infinity) }
                                .buttonStyle(MasterYellowButton()).disabled(busy)
                        }
                    }.controlSize(.large).padding(.horizontal).padding(.vertical, 8)
                }
            }
            .background(masterRed.ignoresSafeArea()).tint(masterYellow).preferredColorScheme(.dark)
            .sheet(isPresented: $cameraShown) { CameraView { image in loadPhoto(image) }.ignoresSafeArea() }
            .sheet(item: $editing) { target in
                VStack(alignment: .leading, spacing: 16) {
                    Text(target.title + "（mm）").font(.headline)
                    TextField("数値", text: $input).keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("キャンセル") { editing = nil }
                        Spacer()
                        Button("保存") { save(target) }.buttonStyle(.borderedProminent)
                    }
                }.padding().presentationDetents([.height(215)])
            }
            .onChange(of: selected) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data)
                    else { message = "写真を読み込めませんでした"; return }
                    guard selected == item else { return }
                    loadPhoto(image)
                }
            }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            if drawing.width > 0 && drawing.height > 0 {
                DrawingPreview(drawing: drawing).frame(height: 165)
            } else if let photo {
                Image(uiImage: photo).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 200)
            }
            HStack {
                Label("穴の候補：\(drawing.holes.count)件", systemImage: "circle.dotted.circle")
                    .font(.headline)
                Spacer()
                Text("単位：mm").font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            GroupBox("穴（中心のX、Yと直径Φ）") {
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        Text("中心X"); Text("中心Y"); Text("直径Φ"); Color.clear.frame(width: 36, height: 1)
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(drawing.holes) { hole in
                        GridRow {
                            cell(hole.x, .x(hole.id), warn: hole.xSuggested == true)
                            cell(hole.y, .y(hole.id), warn: hole.ySuggested == true)
                            cell(hole.diameter, .diameter(hole.id), warn: hole.diameterSuggested == true || hole.diameter <= 0)
                            Button { drawing.holes.removeAll { $0.id == hole.id }; changed() } label: {
                                Image(systemName: "xmark").frame(width: 36,height: 44)
                            }.buttonStyle(.plain).accessibilityLabel("穴を削除")
                        }
                    }
                }.padding(.vertical, 6)
                if drawing.holes.isEmpty { Text("穴の位置を読み取れませんでした").font(.footnote).foregroundStyle(.orange) }
                Button("穴を追加") {
                    var hole = Hole(x:0,y:0,diameter:0)
                    hole.xSuggested = true; hole.ySuggested = true
                    drawing.holes.append(hole); changed()
                    edit(.x(hole.id), value: 0)
                }.buttonStyle(.bordered).frame(maxWidth:.infinity,alignment:.leading)
            }
            if !recognitionSummary.isEmpty {
                Text(recognitionSummary).font(.subheadline.bold())
                    .foregroundStyle(recognitionSummary.contains("失敗") ? .orange : .white)
            }
            if recognitionSummary.contains("失敗") ||
                recognitionSummary.contains("特定できませんでした") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("図面解析の詳細").font(.headline).foregroundStyle(.orange)
                    Text(message).font(.footnote).foregroundStyle(.white).textSelection(.enabled)
                    Button {
                        UIPasteboard.general.string = message
                    } label: {
                        Label("エラー内容をコピー", systemImage: "doc.on.doc")
                    }.buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
            }
            if (recognitionSummary.contains("失敗") ||
                 recognitionSummary.contains("特定できませんでした")), let photo {
                Button("Google OCRで再読み取り") {
                    recognizeGoogleDrawing(photo)
                }.buttonStyle(MasterYellowButton())
            }
            if !detectedText.isEmpty {
                DisclosureGroup("OCR・AIが読み取った印刷数値・寸法候補（\(detectedText.count)件）") {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(detectedText.indices, id: \.self) { index in
                            Text(detectedText[index])
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding(.vertical, 6)
                }
            }
            GroupBox("外形・板厚（mm）") {
                HStack {
                    sizeCell(.width,drawing.width); sizeCell(.height,drawing.height)
                    sizeCell(.thickness,drawing.thickness); sizeCell(.chamfer,drawing.chamfer)
                }
            }
            Text("オレンジは要確認。数字を押すと修正できます。").font(.caption).foregroundStyle(.secondary)
            if !drawing.notes.isEmpty { Text(drawing.notes).font(.caption).foregroundStyle(.secondary) }
            Toggle("原図と全寸法・穴数・穴位置を照合しました", isOn: $verifiedAgainstOriginal)
                .font(.subheadline).tint(.yellow)
            Text("DXFはCAD/CAMへの受け渡し用です。機械のNCコードは生成しません。加工前に現場で必ず再確認してください。")
                .font(.caption).foregroundStyle(.orange)
            if let photo {
                DisclosureGroup("元の図面", isExpanded:$previewOriginal) { Image(uiImage:photo).resizable().scaledToFit() }
            }
            DisclosureGroup("図面管理情報") {
                VStack {
                    TextField("図番",text:$drawing.drawingNumber); TextField("品名",text:$drawing.partName)
                    TextField("会社名",text:$drawing.companyName); TextField("材質",text:$drawing.material)
                    TextField("数量",text:$drawing.quantity); TextField("改訂番号",text:$drawing.revision)
                    TextField("備考",text:$drawing.notes)
                }.textFieldStyle(.roundedBorder)
            }
        }
    }

    private func sizeCell(_ target:EditTarget,_ value:Double) -> some View {
        VStack { Text(target.title).font(.caption); cell(value,target,warn:value <= 0 && target != .chamfer) }
    }
    private func cell(_ value:Double,_ target:EditTarget,warn:Bool) -> some View {
        Button { edit(target,value:value) } label: {
            Text(value == 0 && warn ? "—" : value.formatted(.number.grouping(.never)))
                .monospacedDigit().foregroundStyle(warn ? Color.orange : Color.white)
                .frame(maxWidth:.infinity,minHeight:44).background(Color(white:0.08),in:RoundedRectangle(cornerRadius:8))
        }.buttonStyle(.plain).accessibilityLabel(target.title + " " + value.formatted())
    }
    private func edit(_ target:EditTarget,value:Double) {
        input = value.formatted(.number.grouping(.never)); error = ""; editing = target
    }
    private func changed() { exportURL = nil; message = ""; verifiedAgainstOriginal = false; drawing.verified = false }
    private func save(_ target:EditTarget) {
        let s = input.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:",",with:".")
        guard let v = Double(s), v.isFinite, v >= 0 else { error = "0以上の数値を入力してください"; return }
        switch target {
        case .width: drawing.width = v
        case .height: drawing.height = v
        case .thickness: drawing.thickness = v
        case .chamfer: drawing.chamfer = v
        case let .x(id), let .y(id), let .diameter(id):
            guard let i = drawing.holes.firstIndex(where: { $0.id == id }) else { return }
            if case .x = target { drawing.holes[i].x = v; drawing.holes[i].xSuggested = false }
            if case .y = target { drawing.holes[i].y = v; drawing.holes[i].ySuggested = false }
            if case .diameter = target { drawing.holes[i].diameter = v; drawing.holes[i].diameterSuggested = false }
        }
        changed(); editing = nil
    }

    private func createDXF() {
        guard verifiedAgainstOriginal else {
            message = "原図と全寸法・穴の位置を照合し、確認欄にチェックを入れてください"
            return
        }
        guard drawing.issues.isEmpty else { message = drawing.issues.joined(separator:"、"); return }
        do {
            drawing.verified = true
            let data = try DXF.generate(drawing)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("drawing_\(UUID().uuidString.prefix(8)).dxf")
            try data.write(to:url,options:.atomic)
            exportURL = url
        } catch { message = error.localizedDescription }
    }

    private func loadPhoto(_ image: UIImage) {
        // Normalize camera / photo-library orientation before Vision obtains cgImage.
        let originalSize = image.size
        // Preserve fine dimension text in high-resolution engineering drawings.
// Previously shrinking all photographs to 2400 px erased small labels.
        let maxSide: CGFloat = 3200
        let factor = min(1, maxSide / max(originalSize.width, originalSize.height, 1))
        let size = CGSize(width: max(1, originalSize.width * factor),
                          height: max(1, originalSize.height * factor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        recognitionID = UUID()
        photo = normalized
        selected = nil
        drawing = Drawing()
        detectedText = []
        recognitionSummary = ""
        message = ""
        exportURL = nil
        previewOriginal = false
        verifiedAgainstOriginal = false
        showingResult = true
        busy = true
        recognizeGoogleDrawing(normalized)
    }

    private func recognizeGoogleDrawing(_ normalized: UIImage) {
        let id = recognitionID
        busy = true
        recognitionSummary = "Google OCRに接続して図面を解析しています"
        Task {
            do {
                let words = try await CloudDrawingRecognition.read(normalized)
                guard recognitionID == id, let raster = normalized.cgImage else { return }
                let result = await Task.detached(priority: .userInitiated) {
                    OfflineVision.geometry(cgImage: raster, candidates: words)
                }.value
                guard recognitionID == id else { return }
                drawing = result.ordinateDrawing ?? Drawing()
                for field in recognizeDrawingFields(words) {
                    switch field.key {
                    case "thickness": drawing.thickness = Double(field.value) ?? 0
                    case "chamfer": drawing.chamfer = Double(field.value) ?? 0
                    case "material": drawing.material = field.value
                    case "number": drawing.drawingNumber = field.value
                    default: break
                    }
                }
                detectedText = words.map(\.text)
                message = result.diagnostics

                // Independent on-device OCR reads faint and rotated dimension labels
                // differently from Cloud Vision. Run it only when cloud geometry is
                // incomplete, and use it only if the resulting dimensional geometry
                // is more complete. This does not mark anything as verified.
                if drawing.holes.isEmpty || drawing.width <= 0 || drawing.height <= 0 {
                    if let local = try? await OfflineVision.analyze(cgImage: raster) {
                        guard recognitionID == id else { return }
                        if let localDrawing = local.ordinateDrawing {
                            let cloudScore = drawing.holes.count * 3 +
                                (drawing.width > 0 ? 1 : 0) + (drawing.height > 0 ? 1 : 0)
                            let localScore = localDrawing.holes.count * 3 +
                                (localDrawing.width > 0 ? 1 : 0) + (localDrawing.height > 0 ? 1 : 0)
                            if localScore > cloudScore &&
                                localDrawing.geometryIssues.isEmpty {
                                drawing.width = localDrawing.width
                                drawing.height = localDrawing.height
                                drawing.holes = localDrawing.holes
                                if drawing.thickness <= 0 {
                                    drawing.thickness = localDrawing.thickness
                                }
                                message += "\n端末内の再解析で寸法・穴候補を補完しました。"
                            }
                        }
                        // Show both OCR sources for transparent comparison.
                        for item in local.candidates where
                            !detectedText.contains(item.text) && detectedText.count < 300 {
                            detectedText.append(item.text)
                        }
                    }
                }

                // OCR returning words only proves text detection, not dimension parsing.
                // The former implementation stopped here even when all measured values
                // and holes were absent, leaving the user with an unusable blank drawing.
                let needsAI = drawing.holes.isEmpty || drawing.width <= 0 ||
                    drawing.height <= 0 || drawing.thickness <= 0
                if needsAI {
                    recognitionSummary = "OCRで\(words.count)件読み取りました。図面の数値をAIで再解析中…"
                    do {
                        let ai = try await CloudDrawingRecognition.analyze(normalized, ocrHints: words.map(\.text))
                        guard recognitionID == id else { return }
                        let candidate = CloudDrawingRecognition.drawing(from: ai)
                        // Retain the exact recognized labels for troubleshooting, even
                        // when the model cannot associate them with a hole center.
                        for label in ai.read_numbers ?? [] where
                            !detectedText.contains(label) && detectedText.count < 300 {
                            detectedText.append(label)
                        }
                        // Prefer measured geometric readings. AI values are provisional
                        // and always require comparison against the original drawing.
                        if drawing.width <= 0 { drawing.width = candidate.width }
                        if drawing.height <= 0 { drawing.height = candidate.height }
                        if drawing.thickness <= 0 { drawing.thickness = candidate.thickness }
                        if drawing.chamfer <= 0 { drawing.chamfer = candidate.chamfer }
                        if drawing.material.isEmpty { drawing.material = candidate.material }
                        if drawing.drawingNumber.isEmpty { drawing.drawingNumber = candidate.drawingNumber }
                        if drawing.holes.isEmpty { drawing.holes = candidate.holes }
                        if !candidate.notes.isEmpty {
                            drawing.notes += (drawing.notes.isEmpty ? "" : "\n") + candidate.notes
                        }
                        if drawing.holes.isEmpty && drawing.width <= 0 && drawing.height <= 0 {
                            recognitionSummary = "文字\(words.count)件を検出。AI解析でも寸法・穴位置を特定できませんでした"
                            message += "\nAI解析結果: 穴0件、幅と高さ未検出。図面全体の寸法線が写っているか確認してください。"
                        } else {
                            recognitionSummary = "OCR \(words.count)件＋AI図面解析：穴\(drawing.holes.count)件（原図との照合が必要）"
                        }
                    } catch {
                        guard recognitionID == id else { return }
                        recognitionSummary = "文字\(words.count)件を検出。図面解析AIは失敗しました"
                        message += "\n図面解析AI: \(error.localizedDescription)"
                    }
                } else {
                    recognitionSummary = "Google OCRで文字を\(words.count)件読み取りました。元の図面で寸法を照合してください。"
                }
            } catch {
                guard recognitionID == id else { return }
                let ocrError = error.localizedDescription
                // OCR server outage must not silently turn into an empty drawing.
                // Reuse Firebase AI Logic to read the original photo directly.
                do {
                    let ai = try await CloudDrawingRecognition.analyze(normalized)
                    guard recognitionID == id else { return }
                    drawing = CloudDrawingRecognition.drawing(from: ai)
                    detectedText = ai.read_numbers ?? []
                    recognitionSummary = "Gemini AIで図面候補を読み取りました（要照合）"
                    message = "専用OCRに接続できなかったためGemini AIに切り替えました。OCR: \(ocrError)。図面と数値を必ず照合してください。"
                } catch {
                    guard recognitionID == id else { return }
                    recognitionSummary = "Google OCR・Gemini AIとも接続に失敗しました"
                    let ns = error as NSError
                    let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                    let detail = underlying.map { " / 原因: \($0.domain) (\($0.code)): \($0.localizedDescription)" } ?? ""
                    message = "専用OCR: \(ocrError) / Gemini AI: [\(ns.domain) / \(ns.code)] \(error.localizedDescription)\(detail)"
                    print("[SHEET MASTER] \(message)")
                }
            }
            guard recognitionID == id else { return }
            busy = false
        }
    }

    private func recognizeDrawingFields(_ lines: [OCRCandidate]) -> [DetectedDrawingField] {
        var found: [DetectedDrawingField] = []
        let pattern = #"(?i)(?:板厚|THICKNESS|THK|(?:^|\s)t)\s*[:：=]?\s*(\d{1,2}(?:[.．]\d{1,2})?)\s*(?:mm)?\s*$"#
        let chamferPattern = #"(?i)^(?:4\s*[-‐−x×]\s*)?C\s*(\d{1,2}(?:[.．]\d{1,2})?)$"#
        let materialPattern = #"(?i)^(?:SPHC|SPCC|SS400|SUS304|SUS430|SECC|SGCC|A5052|A6061)$"#
        let drawingNumberPattern = #"^\d{3,6}[-‐ー]\d{1,4}[-‐ー]\d{1,4}[-‐ー]\d{1,4}$"#
        let sorted = lines.sorted { $0.confidence > $1.confidence }
        for line in sorted where line.confidence >= 0.55 {
            let value = line.text.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
            if let thickness = capturedNumber(value, pattern: pattern), thickness > 0, thickness <= 50 {
                found.append(DetectedDrawingField(key: "thickness", label: "板厚", value: "\(thickness)", source: value, sourceID: line.id))
            }
            if let chamfer = capturedNumber(value, pattern: chamferPattern), chamfer > 0, chamfer <= 50 {
                found.append(DetectedDrawingField(key: "chamfer", label: "角C", value: "\(chamfer)", source: value, sourceID: line.id))
            }
            if value.range(of: materialPattern, options: .regularExpression) != nil {
                found.append(DetectedDrawingField(key: "material", label: "材質", value: value.uppercased(), source: value, sourceID: line.id))
            }
            if value.range(of: drawingNumberPattern, options: .regularExpression) != nil {
                found.append(DetectedDrawingField(key: "number", label: "図番", value: value, source: value, sourceID: line.id))
            }
        }
        // If the OCR split the label and numeric value into separate observations,
        // use only immediately adjacent items on the same baseline.
        let thicknessLabels = lines.filter {
            $0.text.range(of: #"(?i)^(?:板厚|THICKNESS|THK|t)$"#,
                          options: .regularExpression) != nil && $0.confidence >= 0.6
        }
        for label in thicknessLabels {
            let neighbors = lines.filter { item in
                guard item.id != label.id, item.confidence >= 0.6,
                      let v = recognizedDimension(item.text), v > 0, v <= 50 else { return false }
                return abs(item.rectangle.midY - label.rectangle.midY) < 0.025 &&
                    item.rectangle.minX >= label.rectangle.maxX &&
                    item.rectangle.minX - label.rectangle.maxX < 0.13
            }
            if neighbors.count == 1, let item = neighbors.first,
               let thickness = recognizedDimension(item.text) {
                found.append(DetectedDrawingField(key: "thickness", label: "板厚",
                    value: "\(thickness)", source: "\(label.text) \(item.text)", sourceID: item.id))
            }
        }
        let grouped = Dictionary(grouping: found, by: { $0.key })
        // Conflicting readings are omitted rather than choosing the first.
        return grouped.keys.sorted().compactMap { key in
            guard let choices = grouped[key], let first = choices.first,
                  choices.allSatisfy({ $0.value == first.value }) else { return nil }
            return first
        }
    }

    private func capturedNumber(_ text: String, pattern: String) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Double(text[range].replacingOccurrences(of: "．", with: "."))
    }

    private func recognizedDimension(_ text: String) -> Double? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "ｍｍ", with: "mm")
            .replacingOccurrences(of: "．", with: ".")
        guard normalized.range(of: #"^\d{1,5}(?:\.\d{1,3})?\s*(?:mm)?$"#,
                               options: .regularExpression) != nil else { return nil }
        let number = normalized.replacingOccurrences(of: "mm", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(number), value > 0, value <= 100000 else { return nil }
        return value
    }

}

struct DrawingPreview: View {
    let drawing: Drawing
    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard drawing.width > 0, drawing.height > 0,
                      drawing.width.isFinite, drawing.height.isFinite else { return }
                let margin: CGFloat = 19
                let width = CGFloat(drawing.width)
                let height = CGFloat(drawing.height)
                let scale = min(max(0, size.width - 2 * margin) / width,
                                max(0, size.height - 2 * margin) / height)
                let left = (size.width - width * scale) / 2
                let bottom = (size.height + height * scale) / 2
                func pt(_ x: Double, _ y: Double) -> CGPoint {
                    CGPoint(x: left + CGFloat(x) * scale, y: bottom - CGFloat(y) * scale)
                }
                let w=drawing.width,h=drawing.height,c=max(0,min(drawing.chamfer,min(w,h)/2))
                let outline: [(Double,Double)] = c>0 ? [(c,0),(w-c,0),(w,c),(w,h-c),(w-c,h),(c,h),(0,h-c),(0,c)] : [(0,0),(w,0),(w,h),(0,h)]
                var path=Path()
                if let first=outline.first { path.move(to: pt(first.0,first.1)) }
                for p in outline.dropFirst() { path.addLine(to: pt(p.0,p.1)) }
                path.closeSubpath()
                ctx.stroke(path, with: .color(.white), lineWidth: 2)
                for hole in drawing.holes where hole.diameter.isFinite && hole.x.isFinite && hole.y.isFinite {
                    let center=pt(hole.x,hole.y),r=CGFloat(hole.diameter)*scale/2
                    if r > 0 { ctx.stroke(Path(ellipseIn: CGRect(x:center.x-r,y:center.y-r,width:2*r,height:2*r)),with:.color(.red),lineWidth:2); continue }
                    var mark=Path();mark.move(to:CGPoint(x:center.x-4,y:center.y));mark.addLine(to:CGPoint(x:center.x+4,y:center.y));mark.move(to:CGPoint(x:center.x,y:center.y-4));mark.addLine(to:CGPoint(x:center.x,y:center.y+4));ctx.stroke(mark,with:.color(.orange),lineWidth:1)
                }
            }
            .background(Color(red: 0.13, green: 0.13, blue: 0.13)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { Text("左下原点　外形：白／穴：赤").font(.caption2).foregroundStyle(.white).padding(4) }
        }
    }
}

private struct DetectedDrawingField: Identifiable {
    let id = UUID()
    let key: String
    let label: String
    let value: String
    let source: String
    let sourceID: UUID
}

private struct MasterYellowButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.black)
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 10)
            .background(Color(red: 1, green: 0.82, blue: 0.13).opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 12))
    }
}
