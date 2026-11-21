import SwiftUI
import PhotosUI
import UIKit

struct MainView: View {
    @State private var phase = 0
    @State private var selected: PhotosPickerItem?
    @State private var photo: UIImage?
    @State private var cameraShown = false
    @State private var busy = false
    @State private var recognitionID = UUID()
    @State private var analysis: RecognitionResult?
    @State private var drawing = Drawing()
    @State private var message = "図面を取り込んでください"
    @State private var exportURL: URL?
    @State private var acceptedCircleIDs: Set<UUID> = []
    @State private var outlineChecked = false
    @State private var holeCountChecked = false
    @State private var checkedHoleIDs: Set<UUID> = []
    @State private var suggestedMeasurements: [OCRCandidate] = []

    private var safeToExport: Bool {
        drawing.verified && outlineChecked && holeCountChecked &&
        checkedHoleIDs.count == drawing.holes.count &&
        drawing.holes.allSatisfy { checkedHoleIDs.contains($0.id) } &&
        drawing.issues.isEmpty
    }

    private func invalidateReview() {
        drawing.verified = false
        exportURL = nil
        outlineChecked = false
        holeCountChecked = false
        checkedHoleIDs.removeAll()
    }

    private let panelRed = Color(red: 143 / 255, green: 23 / 255, blue: 29 / 255)
    private let stages = ["図面を取り込む", "画像解析", "寸法・穴位置確認", "DXF生成", "AMADAへ受け渡し"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("SHEET MASTER").font(.title2.bold())
                        Spacer()
                        Text("\(phase + 1) / \(stages.count)").font(.subheadline.monospacedDigit())
                    }
                    HStack(spacing: 4) {
                        ForEach(stages.indices, id: \.self) { i in
                            Rectangle().fill(i <= phase ? Color.white : Color.clear)
                                .overlay(Rectangle().strokeBorder(.white, lineWidth: 1))
                                .frame(height: 5)
                        }
                    }.accessibilityHidden(true)
                }
                .padding().foregroundStyle(.white)
                .background(panelRed)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        Text(stages[phase]).font(.largeTitle.bold()).foregroundStyle(.white)
                        switch phase {
                        case 0: photoScreen.foregroundStyle(.white)
                        case 1: analysisScreen
                        case 2: geometryScreen
                        case 3: exportScreen
                        default: transferScreen
                        }
                        if photo != nil || message != "図面を取り込んでください" { Text(message).font(.footnote).foregroundStyle(.white) }
                        if phase == 4 {
                            Text("本アプリはAMADA社の公式製品ではありません。")
                                .font(.caption2).foregroundStyle(.white)
                        }
                    }.frame(maxWidth: 680, alignment: .leading).padding().frame(maxWidth: .infinity)
                }
                if phase > 0 || photo != nil {
                HStack {
                    Button("戻る") { phase = max(0, phase - 1) }.disabled(phase == 0)
                    Spacer()
                    Button(phase == 0 ? "図面を解析する" : phase == 4 ? "最初へ" : "次へ") {
                        if phase == 4 { phase = 0 } else { phase += 1; if phase == 1 && analysis == nil { runRecognition() } }
                    }

                .buttonStyle(WorkshopButtonStyle())
                    .disabled((phase == 0 && photo == nil) || (phase == 1 && analysis == nil) || (phase == 3 && exportURL == nil))
                }.padding().background(panelRed)
                }
            }
            .background(panelRed.ignoresSafeArea())
            .buttonStyle(WorkshopButtonStyle())
            .groupBoxStyle(DrawingGroupStyle())
            .toolbar(.hidden, for: .navigationBar)
            .tint(.white)
            .preferredColorScheme(.dark)
            .sheet(isPresented: $cameraShown) {
                CameraView { image in loadPhoto(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: drawing.holes) { _, _ in invalidateReview() }
            .onChange(of: selected) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { loadPhoto(image) }
                    } else {
                        await MainActor.run { message = "画像を読み込めませんでした。JPEG・PNGで再度選択してください。" }
                    }
                }
            }
        }
    }

    private var photoScreen: some View {
        VStack(alignment: .leading, spacing: 14) {
            drawingImage
            Button { cameraShown = true } label: {
                Label("図面を撮影する", systemImage: "camera.fill")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }

                .buttonStyle(WorkshopButtonStyle())
            .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            PhotosPicker(selection: $selected, matching: .images) {
                Label("写真から選ぶ", systemImage: "photo.on.rectangle")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }

                .buttonStyle(WorkshopButtonStyle())
            if photo != nil {
                Button("別の図面を選ぶために現在の図面を消去", role: .destructive) {
                    recognitionID = UUID()
                    busy = false
                    photo = nil
                    analysis = nil
                    suggestedMeasurements = []
                    drawing = Drawing()
                    exportURL = nil
                    selected = nil
                    phase = 0
                    message = "新しい図面を取り込んでください"
                }
                .font(.footnote)
            }
            Text("写真は端末内で処理します。")
                .font(.footnote).foregroundStyle(.white).frame(maxWidth: .infinity)

        }
    }

    private var drawingImage: some View {
        Group {
            if let photo {
                GeometryReader { geo in
                    let scale = min(geo.size.width / max(photo.size.width, 1),
                                    geo.size.height / max(photo.size.height, 1))
                    let imageWidth = photo.size.width * scale
                    let imageHeight = photo.size.height * scale
                    let left = (geo.size.width - imageWidth) / 2
                    let top = (geo.size.height - imageHeight) / 2
                    ZStack(alignment: .topLeading) {
                        Color.white
                        Image(uiImage: photo)
                            .resizable().scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                        if phase == 2, let analysis {
                            if let rect = analysis.rectangle {
                                Rectangle()
                                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                                    .frame(width: rect.width * imageWidth,
                                           height: rect.height * imageHeight)
                                    .position(
                                        x: left + rect.midX * imageWidth,
                                        y: top + (1 - rect.midY) * imageHeight
                                    )
                            }
                            ForEach(analysis.circles.indices.filter { acceptedCircleIDs.contains(analysis.circles[$0].id) }, id: \.self) { index in
                                let candidate = analysis.circles[index]
                                Text("\(index + 1)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(.red))
                                    .position(
                                        x: left + CGFloat(candidate.center.x) * imageWidth,
                                        y: top + (1 - CGFloat(candidate.center.y)) * imageHeight
                                    )
                            }
                        }
                    }
                }
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 56, weight: .regular))
                    Text("図面全体が入るように撮影してください").font(.subheadline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 210)
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
            }
        }
    }

    private var analysisScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            drawingImage
            Button(busy ? "解析中" : "画像解析を実行") { runRecognition() }
                .buttonStyle(WorkshopButtonStyle()).disabled(busy || photo == nil)
            if busy { ProgressView("図面を解析しています") }
            if analysis != nil {
                GroupBox("DXFに必要なデータ") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("読み取った文字は候補です。原図との照合なしに寸法を確定しません。")
                            .font(.subheadline).foregroundStyle(.orange)
                        HStack {
                            Text("外形 幅 × 高さ")
                            Spacer()
                            Text(drawing.width > 0 && drawing.height > 0 ?
                                 "\(drawing.width.formatted()) × \(drawing.height.formatted()) mm" : "要確認")
                        }
                        Divider()
                        HStack {
                            Text("板厚")
                            Spacer()
                            Text(drawing.thickness > 0 ? "\(drawing.thickness.formatted()) mm" : "要確認")
                        }
                        Divider()
                        HStack {
                            Text("四隅のC")
                            Spacer()
                            Text(drawing.chamfer > 0 ? "\(drawing.chamfer.formatted()) mm（要照合）" : "0または未入力（要確認）")
                        }
                        Divider()
                        HStack {
                            Text("穴の中心・直径")
                            Spacer()
                            Text(drawing.holes.isEmpty ? "要確認" : "\(drawing.holes.count)件（未照合）")
                        }
                        Text("文字数や輪郭の検出件数は加工データではありません。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !suggestedMeasurements.isEmpty {
                    GroupBox("寸法の文字候補（原図照合後に転記）") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(suggestedMeasurements) { candidate in
                                if let number = recognizedDimension(candidate.text) {
                                    HStack {
                                        Text("\(candidate.text) mm")
                                        Spacer()
                                        Button("幅へ") { applyDimension(number, toWidth: true) }
                                        Button("高さへ") { applyDimension(number, toWidth: false) }
                                    }
                                }
                            }
                        }
                    }
                }
                Text("「次へ」で外形・穴位置を確認して修正します。")
                    .font(.subheadline).foregroundStyle(.white)
            }
        }
    }

    private var geometryScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("原図面（赤番号＝丸穴候補）") {
                drawingImage
                Text("青点線＝外形候補、赤番号＝丸穴候補。誤認識がある場合は追加しないでください。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("DXFに必要な寸法（mm）") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("原図面と照合してください。不明な寸法は推測で入力しないでください。")
                        .font(.caption).foregroundStyle(.orange)
                    valueRow("外形 幅 X", value: $drawing.width)
                    valueRow("外形 高さ Y", value: $drawing.height)
                    valueRow("板厚", value: $drawing.thickness)
                    valueRow("角 C", value: $drawing.chamfer)
                }
            }
            DisclosureGroup("図面管理情報（任意・DXF形状には含めません）") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("会社名・取引先名", text: $drawing.companyName)
                    TextField("品名", text: $drawing.partName)
                    TextField("図番", text: $drawing.drawingNumber)
                    TextField("改訂番号", text: $drawing.revision)
                    TextField("材質", text: $drawing.material)
                    TextField("数量", text: $drawing.quantity)
                    Picker("加工機種", selection: $drawing.machineType) {
                        Text("未指定").tag("未指定")
                        Text("レーザー").tag("レーザー")
                        Text("タレパン").tag("タレパン")
                        Text("その他").tag("その他")
                    }
                    TextField("備考", text: $drawing.notes, axis: .vertical).lineLimit(2...4)
                }.padding(.top, 8)
            }
            .padding()
            .background(Color(red: 0.13, green: 0.13, blue: 0.13), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
            .environment(\.colorScheme, .dark)
            GroupBox("切断形状プレビュー") {
                DrawingPreview(drawing: drawing)
                    .frame(height: 230).frame(maxWidth: .infinity)
                Text("原点：左下。白＝外形、赤＝穴。寸法を変えるとプレビューに反映します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let analysis, !analysis.circles.isEmpty {
                DisclosureGroup("画像の丸穴候補（参考・誤認識に注意）") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("輪郭検出は正しい穴とは限りません。原図に存在するものだけ選択してください。")
                            .font(.caption).foregroundStyle(.orange)
                        ForEach(analysis.circles.indices, id: \.self) { index in
                            let candidate = analysis.circles[index]
                            HStack {
                                Text("画像候補 \(index + 1)")
                                Spacer()
                                Button(acceptedCircleIDs.contains(candidate.id) ? "追加済み" : "仮追加") {
                                    addDetectedHole(candidate, rect: analysis.rectangle)
                                }
                                .disabled(acceptedCircleIDs.contains(candidate.id) ||
                                          drawing.width <= 0 || drawing.height <= 0 || analysis.rectangle == nil)
                            }
                        }
                    }.padding(.top, 8)
                }
                .padding()
                .background(Color(red: 0.13, green: 0.13, blue: 0.13), in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            }
            GroupBox("穴の座標と直径") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach($drawing.holes) { $hole in
                        VStack(alignment: .leading) {
                            HStack {
                                Text("穴：中心 X / Y・直径 Φ").bold()
                                Spacer()
                                Button("削除", role: .destructive) {
                                    drawing.holes.removeAll { $0.id == hole.id }
                                    drawing.verified = false
                                }.font(.caption)
                            }
                            valueRow("中心 X", value: $hole.x)
                            valueRow("中心 Y", value: $hole.y)
                            valueRow("直径 Φ", value: $hole.diameter)
                            Toggle("原図と照合済み：この穴のX・Y・直径", isOn: Binding(
                                get: { checkedHoleIDs.contains(hole.id) },
                                set: { checked in
                                    if checked { checkedHoleIDs.insert(hole.id) }
                                    else { checkedHoleIDs.remove(hole.id) }
                                    drawing.verified = false
                                    exportURL = nil
                                }
                            ))
                        }.padding(8).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button { drawing.holes.append(Hole(x: drawing.width/2, y: drawing.height/2, diameter: 5)); drawing.verified = false } label: {
                        Label("穴を追加", systemImage: "plus.circle")
                    }.buttonStyle(WorkshopButtonStyle())
                }
            }
            if !drawing.issues.isEmpty {
                GroupBox("修正が必要") {
                    ForEach(drawing.issues, id: \.self) { Text("・" + $0).foregroundStyle(.red) }
                }
            }
            GroupBox("出力前の独立照合（未完了はDXF生成不可）") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("原図と外形・板厚・角C・原点を照合済み", isOn: $outlineChecked)
                    Toggle("原図と穴の総数（\(drawing.holes.count)件）を照合済み", isOn: $holeCountChecked)
                    Text("各穴のX・Y・直径照合：\(checkedHoleIDs.count) / \(drawing.holes.count)件")
                    Toggle("原図との照合結果を承認する", isOn: $drawing.verified)
                        .disabled(!outlineChecked || !holeCountChecked ||
                            checkedHoleIDs.count != drawing.holes.count ||
                            !drawing.holes.allSatisfy { checkedHoleIDs.contains($0.id) } ||
                            !drawing.issues.isEmpty)
                    if !safeToExport {
                        Label("未確認項目があります。DXF生成を停止しています。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            Text("画像だけから穴位置の確定はできません。加工前に必ず原図面と照合してください。")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private var exportScreen: some View {
        VStack(alignment: .leading, spacing: 13) {
            DrawingPreview(drawing: drawing).frame(height: 230)
            VStack(alignment: .leading, spacing: 4) {
                if !drawing.companyName.isEmpty { Text("会社名：\(drawing.companyName)") }
                if !drawing.partName.isEmpty { Text("品名：\(drawing.partName)") }
                if !drawing.drawingNumber.isEmpty { Text("図番：\(drawing.drawingNumber)") }
                if !drawing.revision.isEmpty { Text("改訂：\(drawing.revision)") }
                if !drawing.material.isEmpty { Text("材質：\(drawing.material) ／ 板厚：\(drawing.thickness.formatted()) mm") }
                Text("加工機種：\(drawing.machineType)")
                if !drawing.quantity.isEmpty { Text("数量：\(drawing.quantity)") }
                if !drawing.notes.isEmpty { Text("備考：\(drawing.notes)") }
            }.font(.subheadline)
            Text("外形 \(drawing.width.formatted()) × \(drawing.height.formatted()) mm ／ 穴 \(drawing.holes.count)か所")
            if !safeToExport {
                Label("寸法・穴位置の照合が未完了です。工程3で確認してください。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("DXFファイルを生成") { createDXF() }

                .buttonStyle(WorkshopButtonStyle())
                .disabled(!safeToExport)
            if let exportURL {
                ShareLink(item: exportURL) { Label("DXFをファイルに保存・共有", systemImage: "square.and.arrow.up") }

                .buttonStyle(WorkshopButtonStyle())
            }
            Text("このDXFは試験用です。製造前にCAM上で原図寸法・穴位置を再照合し、加工経路をシミュレーションして責任者の承認を得てください。")
                .font(.footnote).foregroundStyle(.red)
            Text("DXF R12形式。加工機用NCコードではありません。会社のCAD/CAMで取込・寸法照合・加工経路シミュレーションが必要です。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var transferScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let exportURL {
                ShareLink(item: exportURL) { Label("DXFファイルを共有する", systemImage: "square.and.arrow.up") }

                .buttonStyle(WorkshopButtonStyle())
            } else { Text("工程4でDXFを生成してください").foregroundStyle(.orange) }
            GroupBox("会社のPC／AMADA CAMで行う作業") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(["DXFファイルを会社PCに保存", "AMADAのCAD/CAMへ読み込み", "単位mm、原点、外形・穴径・座標を原図面と照合", "材質・板厚・加工条件をCAMで設定", "干渉・加工順をシミュレーション", "現場責任者の確認後にNC出力"], id: \.self) { line in
                        Label(line, systemImage: "checkmark.square").font(.subheadline)
                    }
                }
            }
            Text("機種専用のNCコードをこのアプリから直接生成・転送する機能はありません。")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private func valueRow(_ label: String, value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 94, alignment: .leading)
            TextField("0", value: value, format: .number)
                .keyboardType(.decimalPad).textFieldStyle(.roundedBorder)
                .onChange(of: value.wrappedValue) { _, _ in invalidateReview() }
        }
    }

    private func loadPhoto(_ image: UIImage) {
        // Normalize camera / photo-library orientation before Vision obtains cgImage.
        let originalSize = image.size
        let maxSide: CGFloat = 2400
        let factor = min(1, maxSide / max(originalSize.width, originalSize.height, 1))
        let size = CGSize(width: max(1, originalSize.width * factor),
                          height: max(1, originalSize.height * factor))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let normalized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        recognitionID = UUID()
        busy = false
        photo = normalized
        selected = nil
        analysis = nil
        suggestedMeasurements = []
        acceptedCircleIDs.removeAll()
        drawing = Drawing()
        invalidateReview()
        message = "写真を取り込みました。端末内で画像解析を開始します。"
        phase = 1
        runRecognition()
    }

    private func runRecognition() {
        guard let photo, !busy else { return }
        busy = true
        let requestID = UUID()
        recognitionID = requestID
        message = "OCR解析中…"
        Task {
            do {
                let result = try await OfflineVision.analyze(image: photo)
                await MainActor.run {
                    guard recognitionID == requestID else { return }
                    analysis = result
                    suggestedMeasurements = result.candidates.filter {
                        recognizedDimension($0.text) != nil && $0.confidence >= 0.4
                    }.prefix(16).map { $0 }
                    busy = false
                    message = "\(result.diagnostics)。工程3で数値を照合してください。"
                }
            } catch {
                await MainActor.run {
                    guard recognitionID == requestID else { return }
                    busy = false
                    message = "解析失敗：\(error.localizedDescription)"
                }
            }
        }
    }

    // Restrict OCR transfer to standalone numbers, never tolerance or diameter symbols.
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

    private func applyDimension(_ value: Double, toWidth: Bool) {
        if toWidth {
            drawing.width = value
        } else {
            drawing.height = value
        }
        invalidateReview()
        message = "\(toWidth ? "幅" : "高さ")に\(value.formatted())mmを仮入力しました。必ず原図で確認してください。"
    }

    // Convert a single user-selected candidate relative to the detected outline.
    // A contour is never accepted automatically, because dimension lines and text
    // can look circular. Every accepted hole must still be checked against the drawing.
    private func addDetectedHole(_ candidate: CircleCandidate, rect: CGRect?) {
        guard let rect, rect.width > 0, rect.height > 0,
              drawing.width > 0, drawing.height > 0,
              !acceptedCircleIDs.contains(candidate.id) else { return }
        let cx = Double(candidate.center.x), cy = Double(candidate.center.y)
        let x0 = Double(rect.minX), y0 = Double(rect.minY)
        let rectWidth = Double(rect.width), rectHeight = Double(rect.height)
        let centerX = (cx - x0) / rectWidth * drawing.width
        let centerY = (cy - y0) / rectHeight * drawing.height
        let diameterX = candidate.radiusX * 2 / rectWidth * drawing.width
        let diameterY = candidate.radiusY * 2 / rectHeight * drawing.height
        let diameter = (diameterX + diameterY) / 2
        guard diameter.isFinite, centerX.isFinite, centerY.isFinite,
              diameter > 0,
              centerX - diameter/2 >= 0, centerY - diameter/2 >= 0,
              centerX + diameter/2 <= drawing.width,
              centerY + diameter/2 <= drawing.height else {
            message = "穴候補が外形範囲外です。原図の寸法と位置を確認してください。"
            return
        }
        let duplicate = drawing.holes.contains { existing in
            let centreDistance = hypot(existing.x - centerX, existing.y - centerY)
            return centreDistance < max(0.5, diameter * 0.15) &&
                   abs(existing.diameter - diameter) < max(0.5, diameter * 0.15)
        }
        guard !duplicate else {
            acceptedCircleIDs.insert(candidate.id)
            message = "同じ位置・径の穴が既に登録されているため、重複追加を防ぎました。"
            return
        }
        drawing.holes.append(Hole(x: centerX, y: centerY, diameter: diameter))
        acceptedCircleIDs.insert(candidate.id)
        invalidateReview()
        message = "丸穴候補を1件仮追加しました。穴径と座標を原図と照合してください。"
    }

    private func createDXF() {
        do {
            guard safeToExport else {
                message = "原図との照合が未完了のためDXF生成を停止しました。"
                return
            }
            let data = try DXF.generate(drawing)
            let base = drawing.drawingNumber.isEmpty ? "drawing" : drawing.drawingNumber
            let cleaned = base.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            let safeName = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
            let prefix = safeName.isEmpty ? "drawing" : String(safeName.prefix(50))
            let fileName = "\(prefix)_\(UUID().uuidString.prefix(8)).dxf"
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            exportURL = url
            message = "DXFを作成しました。共有ボタンから保存できます。"
        } catch { message = "DXF生成失敗：\(error.localizedDescription)" }
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
                for hole in drawing.holes where hole.diameter>0 && hole.diameter.isFinite && hole.x.isFinite && hole.y.isFinite {
                    let center=pt(hole.x,hole.y),r=CGFloat(hole.diameter)*scale/2
                    ctx.stroke(Path(ellipseIn: CGRect(x:center.x-r,y:center.y-r,width:2*r,height:2*r)),with:.color(.red),lineWidth:2)
                    var mark=Path();mark.move(to:CGPoint(x:center.x-4,y:center.y));mark.addLine(to:CGPoint(x:center.x+4,y:center.y));mark.move(to:CGPoint(x:center.x,y:center.y-4));mark.addLine(to:CGPoint(x:center.x,y:center.y+4));ctx.stroke(mark,with:.color(.red),lineWidth:1)
                }
            }
            .background(Color(red: 0.13, green: 0.13, blue: 0.13)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { Text("左下原点　外形：白／穴：赤").font(.caption2).foregroundStyle(.white).padding(4) }
        }
    }
}

private struct WorkshopButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .foregroundStyle(.black)
            .background(Color(red: 1, green: 0.81, blue: 0.18),
                        in: RoundedRectangle(cornerRadius: 9))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.48)
    }
}

private struct DrawingGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            configuration.label.font(.headline)
            configuration.content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.13, green: 0.13, blue: 0.13), in: RoundedRectangle(cornerRadius: 10))
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .tint(.yellow)
    }
}
