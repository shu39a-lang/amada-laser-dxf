# SHEET MASTER Claude API relay (separate from the original HTML)

The source HTML is unchanged. This backend verifies Firebase App Check tokens and forwards
photo+prompt to Anthropic, then returns the parsed drawing JSON.

## Deployment prerequisites
- Google Cloud project `sheet-master-e2aa0` with billing and Cloud Run available
- Anthropic API key **stored only in Google Secret Manager**, never in GitHub or iOS app
- Cloud Run runtime service account with `roles/firebaseappcheck.tokenVerifier` and
  `roles/secretmanager.secretAccessor` (only for the Anthropic key)
- Firebase App Check / App Attest configured for iOS bundle ID `com.shu39a.amadaoffline`

Create a Secret Manager secret named `sheet-master-anthropic-key` through the
Google Cloud Console, entering the key **there only**, not in chat or source code.

Deploy this folder with Cloud Run source deployment. Supply environment
variables `CLAUDE_MODEL=claude-sonnet-5-5`,
`FIREBASE_APP_ID=1:195319181441:ios:9bf5ca1c72cd9839429d80`
and bind `ANTHROPIC_API_KEY` to the secret version `latest`.
Allow public HTTPS invocations at Cloud Run's edge, while the endpoint
enforces Firebase App Check for every /v1/analyze request.

After deployment, enter <service-url>/v1/analyze as `DrawingAnalysisEndpoint`
in `SHEET_MASTER_iOS/SHEETMASTER/Info.plist`, then build a new TestFlight IPA.

A GET /health returns status, **not an upstream Claude proof**. Confirm real
Claude communication only by successfully submitting a drawing photo from the
signed TestFlight app and inspecting the returned measurements; review every
dimension manually before any CAM use.
