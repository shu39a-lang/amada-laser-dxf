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
    @State private var tapAddsHole = false
    @State private var acceptedCircleIDs: Set<UUID> = []
    @State private var nominalDiameter = 6.0
    @State private var transferMethod = 0

    private let stages = ["写真を取り込む", "画像解析", "寸法・穴位置確認", "DXF生成", "AMADAへ受け渡し"]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(0..<5, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3).fill(i <= phase ? Color.blue : Color.gray.opacity(0.22)).frame(height: 5)
                    }
                }.padding(.horizontal).padding(.top, 7)
                ScrollView {
                    VStack(alignment: .leading, spacing: 15) {
                        Text("\(phase + 1) / 5　\(stages[phase])").font(.title3.bold())
                        switch phase {
                        case 0: photoScreen
                        case 1: analysisScreen
                        case 2: geometryScreen
                        case 3: exportScreen
                        default: transferScreen
                        }
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        Text("本アプリはAMADA社の公式製品ではありません。DXF出力前には必ず図面と照合してください。")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding()
                }
                HStack {
                    Button("戻る") { phase = max(0, phase - 1) }.disabled(phase == 0)
                    Spacer()
                    Button(phase == 4 ? "最初へ" : "次へ") {
                        if phase == 4 { phase = 0 } else { phase += 1; if phase == 1 && analysis == nil { runRecognition() } }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled((phase == 0 && photo == nil) || (phase == 1 && analysis == nil))
                }.padding().background(.regularMaterial)
            }
            .navigationTitle("図面レーザーDXF")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $cameraShown) {
                CameraView { image in loadPhoto(image) }
                    .ignoresSafeArea()
            }
            .onChange(of: drawing.holes) { _, _ in
                drawing.verified = false
                exportURL = nil
            }
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
            HStack {
                PhotosPicker(selection: $selected, matching: .images) {
                    Label("写真から選ぶ", systemImage: "photo")
                }.buttonStyle(.borderedProminent)
                Button { cameraShown = true } label: { Label("撮影", systemImage: "camera") }
                    .buttonStyle(.bordered)
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
            }
            if photo != nil {
                Button("別の図面を選ぶために現在の図面を消去", role: .destructive) {
                    recognitionID = UUID()
                    busy = false
                    photo = nil
                    analysis = nil
                    drawing = Drawing()
                    exportURL = nil
                    selected = nil
                    phase = 0
                    message = "新しい図面を取り込んでください"
                }
                .font(.footnote)
            }
            Text("写真は端末内のみで処理します。外部サーバーには送信しません。")
                .font(.footnote).foregroundStyle(.secondary)
            if photo != nil {
                Button("図面を画像解析") { phase = 1; runRecognition() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var drawingImage: some View {
        Group {
            if let photo {
                Image(uiImage: photo).resizable().scaledToFit().frame(maxHeight: 360)
                    .frame(maxWidth: .infinity).background(.white).clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                ContentUnavailableView("図面がありません", systemImage: "doc.viewfinder", description: Text("写真を選択または撮影してください"))
                    .frame(height: 200)
            }
        }
    }

    private var analysisScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            drawingImage
            Button(busy ? "解析中" : "画像解析を実行") { runRecognition() }
                .buttonStyle(.borderedProminent).disabled(busy || photo == nil)
            if busy { ProgressView("iPhone内で解析しています") }
            if let result = analysis {
                GroupBox("画像解析結果") {
                    VStack(alignment: .leading) {
                        Text(result.diagnostics)
                        Text(result.rectangle == nil ? "外形候補なし（手動寸法確認が必要）" : "矩形の外形候補あり（未検証）")
                            .foregroundStyle(.orange)
                        Text("読み取った寸法候補は、原図と照合してから「幅へ」「高さへ」で転記できます。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                if !result.circles.isEmpty {
                    GroupBox("丸穴候補（画像輪郭から検出）") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("検出候補：\(result.circles.count)件。写真上の円形文字や記号も含まれる場合があります。")
                                .font(.footnote).foregroundStyle(.orange)
                            Text("工程3で外形幅・高さを確定した後、必要な候補だけ追加してください。")
                                .font(.caption)
                            Text("誤認識を防ぐため、工程3で丸穴候補を1件ずつ選択してください。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                GroupBox("読み取った文字（候補）") {
                    if result.candidates.isEmpty {
                        Text("文字を認識できませんでした").foregroundStyle(.secondary)
                    } else {
                        ForEach(result.candidates) { candidate in
                            HStack(alignment: .firstTextBaseline) {
                                Text(candidate.text).textSelection(.enabled)
                                Spacer()
                                Text("\(Int(candidate.confidence * 100))%")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3)
                            if let value = recognizedDimension(candidate.text) {
                                HStack(spacing: 8) {
                                    Button("幅へ") { applyDimension(value, toWidth: true) }
                                        .buttonStyle(.bordered)
                                    Button("高さへ") { applyDimension(value, toWidth: false) }
                                        .buttonStyle(.bordered)
                                    Text("mm").font(.caption).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var geometryScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("図面情報（mm）") {
                VStack {
                    TextField("図番", text: $drawing.drawingNumber)
                    TextField("材質", text: $drawing.material)
                    valueRow("幅 X", value: $drawing.width)
                    valueRow("高さ Y", value: $drawing.height)
                    valueRow("板厚", value: $drawing.thickness)
                    valueRow("角 C", value: $drawing.chamfer)
                }
            }
            GroupBox("切断形状プレビュー") {
                DrawingPreview(drawing: drawing)
                    .frame(height: 230).frame(maxWidth: .infinity)
                Text("原点：左下。青＝外形、赤＝穴。寸法を変えるとプレビューに反映します。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let analysis, !analysis.circles.isEmpty {
                GroupBox("画像から検出した丸穴候補") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("候補\(analysis.circles.count)件。外形幅・高さを入力した後に追加します。")
                            .font(.footnote)
                        if drawing.width <= 0 || drawing.height <= 0 || analysis.rectangle == nil {
                            Text("外形候補を検出し、幅・高さを確認すると穴を選択できます。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        ForEach(Array(analysis.circles.enumerated()), id: \.element.id) { index, candidate in
                            HStack {
                                Text("候補\(index + 1)（画像検出）")
                                    .font(.subheadline)
                                Spacer()
                                Button(acceptedCircleIDs.contains(candidate.id) ? "追加済み" : "この穴を追加") {
                                    addDetectedHole(candidate, rect: analysis.rectangle)
                                }
                                .buttonStyle(.bordered)
                                .disabled(acceptedCircleIDs.contains(candidate.id) ||
                                          drawing.width <= 0 || drawing.height <= 0 || analysis.rectangle == nil)
                            }
                        }
                        Text("画像の線や文字も穴と誤認するため、原図にある穴だけ追加してください。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
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
                        }.padding(8).background(Color.secondary.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    Button { drawing.holes.append(Hole(x: drawing.width/2, y: drawing.height/2, diameter: 5)); drawing.verified = false } label: {
                        Label("穴を追加", systemImage: "plus.circle")
                    }.buttonStyle(.bordered)
                }
            }
            if !drawing.issues.isEmpty {
                GroupBox("修正が必要") {
                    ForEach(drawing.issues, id: \.self) { Text("・" + $0).foregroundStyle(.red) }
                }
            }
            Toggle("原図と寸法・穴位置を照合しました", isOn: $drawing.verified)
                .disabled(!drawing.issues.isEmpty)
            Text("画像だけから穴位置の確定はできません。加工前に必ず原図面と照合してください。")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    private var exportScreen: some View {
        VStack(alignment: .leading, spacing: 13) {
            DrawingPreview(drawing: drawing).frame(height: 230)
            Text("外形 \(drawing.width.formatted()) × \(drawing.height.formatted()) mm ／ 穴 \(drawing.holes.count)か所")
            if !drawing.verified || !drawing.issues.isEmpty {
                Label("寸法・穴位置の照合が未完了です。工程3で確認してください。", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Button("DXFファイルを生成") { createDXF() }
                .buttonStyle(.borderedProminent)
                .disabled(!drawing.verified || !drawing.issues.isEmpty)
            if let exportURL {
                ShareLink(item: exportURL) { Label("DXFをファイルに保存・共有", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
            Text("DXF R12形式。加工機用NCコードではありません。会社のCAD/CAMで取込・寸法照合・加工経路シミュレーションが必要です。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var transferScreen: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("受け渡し方法", selection: $transferMethod) {
                Text("ファイル共有").tag(0)
                Text("メール").tag(1)
                Text("USB等").tag(2)
            }.pickerStyle(.segmented)
            if let exportURL {
                ShareLink(item: exportURL) { Label("DXFファイルを共有する", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
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
                .onChange(of: value.wrappedValue) { _, _ in drawing.verified = false; exportURL = nil }
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
        acceptedCircleIDs.removeAll()
        drawing = Drawing()
        exportURL = nil
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
        drawing.verified = false
        exportURL = nil
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
        let centerX = (cx - rect.minX) / rect.width * drawing.width
        let centerY = (cy - rect.minY) / rect.height * drawing.height
        let diameterX = candidate.radiusX * 2 / rect.width * drawing.width
        let diameterY = candidate.radiusY * 2 / rect.height * drawing.height
        let diameter = (diameterX + diameterY) / 2
        guard diameter.isFinite, centerX.isFinite, centerY.isFinite,
              diameter > 0,
              centerX - diameter/2 >= 0, centerY - diameter/2 >= 0,
              centerX + diameter/2 <= drawing.width,
              centerY + diameter/2 <= drawing.height else {
            message = "穴候補が外形範囲外です。原図の寸法と位置を確認してください。"
            return
        }
        drawing.holes.append(Hole(x: centerX, y: centerY, diameter: diameter))
        acceptedCircleIDs.insert(candidate.id)
        drawing.verified = false
        exportURL = nil
        message = "丸穴候補を1件仮追加しました。穴径と座標を原図と照合してください。"
    }

    private func createDXF() {
        do {
            let data = try DXF.generate(drawing)
            let base = drawing.drawingNumber.isEmpty ? "drawing" : drawing.drawingNumber
            let safeName = base.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName + ".dxf")
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
                let scale = min((size.width - 2 * margin)/drawing.width, (size.height - 2 * margin)/drawing.height)
                let left = (size.width - drawing.width * scale)/2
                let bottom = (size.height + drawing.height * scale)/2
                func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: left + x*scale, y: bottom - y*scale) }
                let w=drawing.width,h=drawing.height,c=max(0,min(drawing.chamfer,min(w,h)/2))
                let outline: [(Double,Double)] = c>0 ? [(c,0),(w-c,0),(w,c),(w,h-c),(w-c,h),(c,h),(0,h-c),(0,c)] : [(0,0),(w,0),(w,h),(0,h)]
                var path=Path()
                if let first=outline.first { path.move(to: pt(first.0,first.1)) }
                for p in outline.dropFirst() { path.addLine(to: pt(p.0,p.1)) }
                path.closeSubpath()
                ctx.stroke(path, with: .color(.blue), lineWidth: 2)
                for hole in drawing.holes where hole.diameter>0 && hole.diameter.isFinite && hole.x.isFinite && hole.y.isFinite {
                    let center=pt(hole.x,hole.y),r=hole.diameter*scale/2
                    ctx.stroke(Path(ellipseIn: CGRect(x:center.x-r,y:center.y-r,width:2*r,height:2*r)),with:.color(.red),lineWidth:2)
                    var mark=Path();mark.move(to:CGPoint(x:center.x-4,y:center.y));mark.addLine(to:CGPoint(x:center.x+4,y:center.y));mark.move(to:CGPoint(x:center.x,y:center.y-4));mark.addLine(to:CGPoint(x:center.x,y:center.y+4));ctx.stroke(mark,with:.color(.red),lineWidth:1)
                }
            }
            .background(Color.white).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .bottom) { Text("左下原点　外形：青／穴：赤").font(.caption2).foregroundStyle(.black).padding(4) }
        }
    }
}
