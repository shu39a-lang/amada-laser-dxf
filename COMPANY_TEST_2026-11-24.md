# SHEET MASTER — 2026-11-24 (Tuesday) company trial
## What this build does
- On-device (Apple Vision) photograph / photo-library input.
- Extracts *candidate* sizes, thickness and circle coordinates from drawing dimensions.
- Editable hole center X / Y / diameter, material, plate thickness and overall dimensions.
- After comparing all dimensions against the original and confirming them, exports DXF R12.
- **Does not generate AMADA-specific NC code or drive a machine.**
- Google Gemini/Vertex cloud recognition service is only a backend draft: not deployed or connected, so do not claim cloud AI recognition is available.

## Before the trial
1. Check the GitHub Actions iOS compile result and Codemagic iOS signing/build result. A green GitHub Actions check alone does not prove a signed iPhone build is available.
2. Install the latest successful TestFlight build and check its build number. If it is old, fixes in this repository are not yet included.
3. Bring reference drawings with known printed dimensions and hole coordinate tables, including a difficult low-contrast drawing. Avoid confidential photos leaving the device.

## Trial sequence (do not connect to a production machine)
1. Launch app; verify red/dark theme and iPhone/iPad controls are visible.
2. Capture a clearly printed drawing; record whether a nonempty results screen appears.
3. Compare overall width/height, material/thickness, hole count, every hole X/Y/diameter against the original; note missing, duplicated, false-positive or swapped axes.
4. Repeat with an angled image, shadow, rotated drawing, light print, multiple diameters, dense dimensions.
5. Without checking source-confirmation, attempt DXF export; it should block export.
6. Correct uncertain readings manually, compare again, then confirm original and export DXF.
7. Import the DXF into a non-production CAD viewer/CAD-CAM sandbox: inspect units (millimetres), origin, width/height and every circle. No automatic manufacturing.
8. Do not use exported geometry for machinery until an engineer independently verifies CAM compatibility and safety.

## Result record
- iPhone model / iOS version / TestFlight build number:
- Drawing identifier (no secret/customer data):
- Number of printed holes / number correctly recognized:
- Width/height/plate thickness correct?:
- Every hole X/Y/diameter correct?:
- Camera worked? Photo library worked?:
- DXF importer and units correct?:
- Screenshots of wrong or missing fields (redact customer identifiers):
- Verdict: PASS / NEEDS FIX / NOT TESTED

## Known prerequisites and limitations
- Backend deploy and Firebase App Check client integration are NOT completed.
- Real-image benchmarks and Apple-signed builds must be verified; automated tests alone cannot guarantee accuracy.
- Actual AMADA-specific NC output is explicitly unsupported.
