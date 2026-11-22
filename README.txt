SHEET MASTER iOS wrapper (original HTML unchanged)

* Bundle identifier: com.shu39a.amadaoffline
* Open SHEETMASTER.xcodeproj on a Mac with Xcode, choose Signing team, build for iPhone.
* Or import the entire folder to a GitHub repo and build with Codemagic.
* The HTML file is an unmodified byte-for-byte copy of the supplied original.
* UI, layout and existing drawing/DXF logic are not edited.
* Native bridge: saves text files via iOS Files document picker.
* AI reading currently requires a separate HTTPS server: set DrawingAnalysisEndpoint in Info.plist.
  Endpoint POST application/json payload: {prompt, imageBase64, modelTier}
  Response: JSON object matching the original HTML's drawing schema (partName, drawingNo, material, thickness, width, height, chamfer, holes, notes, xDims, yDims).
  Do not embed provider API keys in the iOS app. With endpoint empty, photo analysis is not operational, but manual entry and DXF creation remain available.
* Not built/tested on macOS or uploaded to App Store Connect in this environment.
