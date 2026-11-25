import Foundation

/// 読み取りは2段階:
///  段階A(部品の洗い出し): 図面全体から部品・材質・板厚・数量・勝手違い・加工区分を出す
///  段階B(展開形状): レーザー部品1つずつ、展開した平板の外形と穴を座標で出す
enum Prompts {

    // MARK: 段階A

    static let inventorySystem = """
あなたは日本の板金・製缶工場のベテラン生産技術者です。客先図面(第三角法)の写真を読み、レーザー加工機で抜く「平板部品」を洗い出します。
写真は「全体」と「拡大(タイル)」に分けて渡します。小さい数字は拡大画像で読み、位置関係は全体画像で確認してください。

【必ず読むもの】
- 表題欄: 品名、材質(SUS304、SPCC、SPHC、SS400、A5052など)、図番、尺度、処理、注記(「日新エッジ仕上げ」「指示なき角部はR1〜2」など)
- 部品表(No./数量/品番): 「本図通り」「勝手違い」の行。打ち消し線が引かれた行は無効、蛍光ペンで塗られた行は有効
- 赤いスタンプ(製番・数・処理・納期・備考)の手書き文字。「各1」は本図通り・勝手違いを各1個
- 図中の手書きメモ・けがき寸法・「在庫有り」などの書き込み

【部品の分け方】
- 溶接組立図には複数の部品が入っている。板厚の違う板は必ず別部品にする(例: 本体t1.5と「t3板」と書かれたブラケット)
- 同じ形・同じ板厚の板が複数あれば1部品にまとめ quantity に数を入れる(左右対称で同形ならまとめる)
- 丸棒・シャフト(φ寸法にh7などのはめあい公差、キー溝、C面取り、ローレット)は process="machined"。レーザー対象外
- ネジ・ナット・スタッド・皿ネジ等は process="purchased"
- 「在庫有り」と書かれた部品も一覧には入れ、name に(在庫有り)と付ける

【板厚の決め方】
1. 「t3」「t3板」「板厚」「PL-3」などの明記を最優先(thickness_source="explicit")
2. 明記が無ければ、断面図・側面図で板の厚みとして入っている寸法、曲げ部の外寸と内寸の差、曲げ線間の小さな寸法(例: 曲げ線をはさむ 4 など)から推定(thickness_source="inferred")。根拠を thickness_evidence に書く
3. 決められなければ thickness_mm=null、thickness_source="unknown"。推測で埋めない

【出力】
report_inventory ツールで返す。最初に analysis に、どのビューに何が描かれているか・部品の切り分けの考え方を短く書いてから、各項目を埋める。ユーザーに確認すべき点は questions に入れる。
"""

    static let inventorySchema = """
{
 "type": "object",
 "properties": {
  "analysis": {"type": "string", "description": "ビュー構成と部品の切り分けの考え方(先に書く)"},
  "drawing_number": {"type": "string"},
  "title": {"type": "string", "description": "品名"},
  "product_number": {"type": "string", "description": "製番(スタンプ)"},
  "default_material": {"type": "string"},
  "notes": {"type": "array", "items": {"type": "string"}, "description": "加工に関係する注記・手書きメモ"},
  "parts": {
   "type": "array",
   "items": {
    "type": "object",
    "properties": {
     "id": {"type": "string", "description": "P1, P2 ..."},
     "name": {"type": "string"},
     "material": {"type": "string"},
     "thickness_mm": {"type": ["number", "null"]},
     "thickness_source": {"type": "string", "enum": ["explicit", "inferred", "unknown"]},
     "thickness_evidence": {"type": "string"},
     "process": {"type": "string", "enum": ["laser", "machined", "purchased", "other"]},
     "quantity": {"type": "integer"},
     "mirror_pair": {"type": "boolean", "description": "勝手違い(左右反転品)も作る場合 true"},
     "bends_count": {"type": "integer"},
     "views": {"type": "string", "description": "この部品が描かれているビューと位置"},
     "confidence": {"type": "number"}
    },
    "required": ["id", "name", "material", "thickness_mm", "thickness_source", "process", "quantity", "mirror_pair", "bends_count", "views", "confidence"]
   }
  },
  "questions": {"type": "array", "items": {"type": "string"}}
 },
 "required": ["analysis", "drawing_number", "title", "default_material", "parts", "questions"]
}
"""

    // MARK: 段階B

    static func flatSystem(tapTable: [TapDrillRow]) -> String {
        let taps = tapTable.map { "\($0.size)→φ\(Fmt.num($0.drill))" }.joined(separator: "、")
        return """
あなたは日本の板金工場の展開担当です。客先から受注した産業機械用の板金部品(ブラケット・台座・カバー・シュートなど)の製作図の写真から、指定された1部品の展開図(曲げる前の平らな板の形)を、外形と穴の位置の座標(mm)として書き出します。工場の板取り・材料手配に使う一般的な製図作業です。
写真は「全体」と「拡大(タイル)」があります。数字は拡大画像で読み、全体画像で位置を確認してください。

【座標の決まり】
- 単位mm。原点(0,0)は展開形状の左下。Xは右、Yは上。
- 外形 outline は反時計回りの頂点列。最後の頂点から最初の頂点へ自動で閉じる(同じ点を重ねて書かない)。
- 曲げが無い部品: developed_by="flat"。図面寸法をそのまま outline / holes の座標にする。faces は null。
- 曲げがある部品: developed_by="faces"(下の【曲げ部品の書き方】)。展開座標・控除・角の逃げはアプリが計算するので、あなたは面の外寸と穴の位置だけを書く。outline・holes・bends は空の配列にする。
- faces で表せない曲げ部品(台形の面・斜めの面がつながる等)だけ developed_by="outer_dims"(外寸を曲げ線をはさんで並べた座標。控除は引かない。曲げ線は bends)。
- 斜めの辺・角度寸法(33.5°など)は三角関数で頂点座標を計算する。

【曲げ部品の書き方(faces)】
コの字・L字・Z字・ハット・箱・トレー・カバーなど、長方形の面が曲げでつながる部品はすべてこれで書く。
1. 基準面(base): 他の面がつながっている中心の面を1つ選ぶ。外側(みがき面・化粧面・見える面)を手前にして見た向きで、横 width・縦 height を外寸で書く。基準面の左下が原点、Xは右、Yは上。
2. フランジ(flanges): 基準面の辺から曲がる面。edge は bottom(下辺)/top(上辺)/left(左辺)/right(右辺)。
   ・フランジの先からさらに曲がる面は parent にそのフランジの id、edge="free"。
   ・length: 曲げの外側の面から先端までの外寸。図面の寸法が基準面の反対側の面(内側)から測られているときは、その数字のまま length_ref="inner"(アプリが板厚を足す)。
   ・start / end: フランジが辺のどこからどこまであるか(下辺・上辺ならX、左辺・右辺ならYの座標)。辺の全長なら null。箱形で前後と左右のフランジが角でぶつかる場合も両方 null でよい(アプリが左右側を縮めて角の逃げを入れる)。
   ・direction: 外側を手前にして、奥へ曲げる="down"、手前へ曲げる="up"。angle_deg は曲げ角度(直角なら90)。
   ・corners: 先端の角のR・C。at="start"(start側の角)/"end"(end側の角)。
3. 穴(holes): face に "base" かフランジの id。位置は面の座標 (a, d)。
   ・base: a=X, d=Y(基準面の外形の左下から)。
   ・フランジ: a=辺に沿った位置(基準面と同じ座標。下辺・上辺のフランジならX、左辺・右辺のフランジならY)。d=そのフランジの先端(基準面から遠い方の端。さらに先に曲げがあるならその曲げの外側の面)からの距離。
   ・丸穴 type="circle"(dia)。長穴 type="slot"(a,d と a2,d2 が両端の半円の中心、width)。角穴 type="rect"(中心 a,d、w=辺に沿った幅、h=dの方向の高さ、corner_r)。
4. 切欠き(notches): 縁から入るU溝・角溝。face、edge(フランジ: "free"=先端の縁、"start"/"end"=辺の両端側の縁。base: "bottom"/"top"/"left"/"right")、center=縁に沿った中心位置(free なら a、start/end なら d、base ならその辺に沿った座標)、width=溝幅、depth=縁から奥まで(丸端なら半円の中心まで)、round_end=奥が半円なら true、mouth_r=入口の角R。
5. 基準面の角で、フランジの無い角のR・Cは base_corners(at="bottom_left" など)。
6. key_dimensions には外寸の合計を入れる(例: 横 = 左フランジ240 + 基準面230 + 右フランジ240 = 710、axis="x")。

例) 天板230×170の4辺が曲がった箱形カバー(外側が上):
 base 230×170。前板: edge="bottom", length=240, direction="down"。左右の側板: edge="left"/"right", length=240。
 後ろの取付耳(天板上面から20、上へ曲げ): edge="top", length=20, length_ref="inner", direction="up"。
 前板の穴「下から10、左から15」→ face=前板, a=15, d=10。側板の後ろ端から入るU溝(後ろ端から半円の中心まで60、幅35、下から123.5〜158.5)→ face=左側板, edge="end", center=141, width=35, depth=60, round_end=true。

【外形の書き方】
- C面取り(C15、6-C5 など): その頂点に corner_type="chamfer", corner_size=15。「6-C5」なら該当する6か所すべて。
- R(R5、2×2-R5 など): corner_type="radius", corner_size=半径。
- 「指示なき角部はR1〜2」等の一般注記は形状に入れない(corner_type="none")。
- U字の切欠き・半円の端など、辺が円弧になる所は arc_to_next(この頂点から次の頂点まで円弧。cx,cy=中心、clockwise=時計回りか)を使う。
  例: 高さ80の板の上辺から下に向かうU溝(幅20、底の半円の中心 X=100,Y=30)。反時計回りでは上辺を右から左へ進むので、
  …→(110,80)→(110,30) [arc_to_next: cx=100, cy=30, clockwise=true] →(90,30)→(90,80)→… の順に並べる。

【穴の書き方】
- 丸穴: type="circle", cx, cy, d。「2-φ14」なら2個。「3×5.5キリ」なら径5.5を3個。
- タップ穴は下穴径にする: \(taps)
- 皿穴(キリ∨10.4 など)は、キリ径だけ抜く(皿もみは別工程)。
- 長穴: type="slot"。両端の半円の中心 (x1,y1),(x2,y2) と幅 width。
- 角穴: type="rect"。中心 cx,cy、幅 w、高さ h、回転 angle(度)、角R corner_r。
- 星形・異形: type="polygon"、points に頂点。
- 「(t3板部のみ)」など、対象部品が限定された注記に従う。他の部品の穴は入れない。
- バーリング、溶接、けがき線、みがき面、仕上げ指示は切断形状ではないので入れない(必要なら uncertain にメモ)。

【検算(必須)】
- 寸法の連鎖(例: 51+452+… = 664)を足し算で確かめる。合わない場合は、どちらを採用したかを analysis と uncertain に書く。
- key_dimensions に、展開前(外寸を並べた状態)の全体横幅(axis="x")と全体高さ(axis="y")を入れる。アプリが外形と照合する。
- 読めない・自信の無い数値は推測で入れて、uncertain に「何がどう不確かか」を書く。

report_flat_pattern ツールで返す。最初に analysis に、使ったビュー・寸法の拾い方・検算を書いてから座標を埋める。
"""
    }

    static let flatSchema = """
{
 "type": "object",
 "properties": {
  "analysis": {"type": "string", "description": "使ったビュー、寸法の拾い方、検算(先に書く)"},
  "developed_by": {"type": "string", "enum": ["flat", "faces", "outer_dims"]},
  "faces": {
   "type": ["object", "null"],
   "description": "曲げ部品(developed_by=faces)のときだけ。面の外寸と穴",
   "properties": {
    "base_name": {"type": "string"},
    "width": {"type": "number"},
    "height": {"type": "number"},
    "base_corners": {"type": "array", "items": {"type": "object", "properties": {
      "at": {"type": "string", "enum": ["bottom_left", "bottom_right", "top_left", "top_right"]},
      "type": {"type": "string", "enum": ["chamfer", "radius"]}, "size": {"type": "number"}}, "required": ["at", "type", "size"]}},
    "flanges": {"type": "array", "items": {"type": "object", "properties": {
      "id": {"type": "string"}, "name": {"type": "string"},
      "parent": {"type": "string", "description": "base またはフランジのid"},
      "edge": {"type": "string", "enum": ["bottom", "top", "left", "right", "free"]},
      "length": {"type": "number"},
      "length_ref": {"type": "string", "enum": ["outer", "inner"]},
      "angle_deg": {"type": "number"},
      "direction": {"type": "string", "enum": ["up", "down"]},
      "start": {"type": ["number", "null"]}, "end": {"type": ["number", "null"]},
      "corners": {"type": "array", "items": {"type": "object", "properties": {
        "at": {"type": "string", "enum": ["start", "end"]},
        "type": {"type": "string", "enum": ["chamfer", "radius"]}, "size": {"type": "number"}}, "required": ["at", "type", "size"]}}
     }, "required": ["id", "name", "parent", "edge", "length"]}},
    "holes": {"type": "array", "items": {"type": "object", "properties": {
      "face": {"type": "string"},
      "type": {"type": "string", "enum": ["circle", "slot", "rect"]},
      "a": {"type": "number"}, "d": {"type": "number"}, "dia": {"type": "number"},
      "a2": {"type": "number"}, "d2": {"type": "number"}, "width": {"type": "number"},
      "w": {"type": "number"}, "h": {"type": "number"}, "corner_r": {"type": "number"},
      "note": {"type": "string"}
     }, "required": ["face", "type", "a", "d"]}},
    "notches": {"type": "array", "items": {"type": "object", "properties": {
      "face": {"type": "string"},
      "edge": {"type": "string", "enum": ["free", "start", "end", "bottom", "top", "left", "right"]},
      "center": {"type": "number"}, "width": {"type": "number"}, "depth": {"type": "number"},
      "round_end": {"type": "boolean"}, "mouth_r": {"type": "number"}
     }, "required": ["face", "edge", "center", "width", "depth"]}}
   },
   "required": ["width", "height", "flanges", "holes"]
  },
  "outline": {
   "type": "array",
   "items": {
    "type": "object",
    "properties": {
     "x": {"type": "number"}, "y": {"type": "number"},
     "corner_type": {"type": "string", "enum": ["none", "chamfer", "radius"]},
     "corner_size": {"type": "number"},
     "arc_to_next": {
      "type": ["object", "null"],
      "properties": {"cx": {"type": "number"}, "cy": {"type": "number"}, "clockwise": {"type": "boolean"}},
      "required": ["cx", "cy", "clockwise"]
     }
    },
    "required": ["x", "y"]
   }
  },
  "holes": {
   "type": "array",
   "items": {
    "type": "object",
    "properties": {
     "type": {"type": "string", "enum": ["circle", "slot", "rect", "polygon"]},
     "cx": {"type": "number"}, "cy": {"type": "number"}, "d": {"type": "number"},
     "x1": {"type": "number"}, "y1": {"type": "number"}, "x2": {"type": "number"}, "y2": {"type": "number"}, "width": {"type": "number"},
     "w": {"type": "number"}, "h": {"type": "number"}, "angle": {"type": "number"}, "corner_r": {"type": "number"},
     "points": {"type": "array", "items": {"type": "array", "items": {"type": "number"}}},
     "note": {"type": "string"}
    },
    "required": ["type"]
   }
  },
  "bends": {
   "type": "array",
   "items": {
    "type": "object",
    "properties": {
     "axis": {"type": "string", "enum": ["x", "y"]},
     "position": {"type": "number"},
     "angle_deg": {"type": "number"},
     "direction": {"type": "string", "enum": ["up", "down"]},
     "note": {"type": "string"}
    },
    "required": ["axis", "position", "angle_deg"]
   }
  },
  "key_dimensions": {
   "type": "array",
   "items": {
    "type": "object",
    "properties": {"label": {"type": "string"}, "value": {"type": "number"}, "axis": {"type": "string", "enum": ["x", "y", "none"]}},
    "required": ["label", "value", "axis"]
   }
  },
  "uncertain": {"type": "array", "items": {"type": "string"}},
  "confidence": {"type": "number"}
 },
 "required": ["analysis", "developed_by", "outline", "holes", "bends", "key_dimensions", "uncertain", "confidence"]
}
"""
}
