# Optional Google Cloud OCR prototype — NOT ACTIVE

This isolated directory is an implementation draft for migrating SHEET MASTER's
text recognition to Google Cloud Vision without changing existing screens.

## Architecture
1. iPhone captures and pre-processes a drawing, keeping the existing on-device
   Apple Vision pipeline as fallback.
2. When the user explicitly enables cloud recognition and consents to sending
   the image, the app obtains a **Firebase App Check token**.
3. A minimal Cloud Run service verifies that token server-side before calling
   Google Cloud Vision `DOCUMENT_TEXT_DETECTION` with its service identity.
4. Only recognized words with bounding rectangles come back. **Hole geometry,
   scale, dimensions, tolerances, and DXF output are not inferred by Google OCR.**
5. Existing drawing calculations must verify results against the original
   dimension annotations. Uncertain readings require manual confirmation.

## Why not a direct iPhone API key?
A distributed iPhone application cannot keep a Google Cloud service credential
secret. Embedding a billing-enabled key would permit abuse and unexpected costs.
Cloud Run is Google-managed; no owned or maintained physical server is needed.

## Deployment is intentionally not done yet
- Configure a Google Cloud project, billing budget/alerts and a quota cap.
- Enable Vision API and Cloud Run, set the runtime service account with minimum
  permissions needed for Vision.
- Configure Firebase and App Check for this exact iOS Bundle ID and authorize
  Cloud Run traffic only through an appropriate gateway/access-control design.
- Provision Firebase App Check in the iOS app before enabling any cloud upload.
- Deploy this folder, configure HTTPS endpoint, and test unauthorized requests
  return 401 and no image body/recognized text is logged.
- Make cloud recognition opt-in with clear privacy disclosures, and test on
  several known drawings. Do not auto-authorize cutting or machine operation.

Cloud Run, network traffic, Vision feature units and other Google Cloud services
may have different free tiers and charges. The 1,000-units/month Vision allowance
is per billing account across projects, not a per-app unlimited guarantee.
Do not assume one photographed drawing is exactly one billable unit if multiple
features or requests are used.

## Current status
Code prepared only. No Google Cloud account credentials were obtained; no
deployment, production OCR call, iOS app integration, billing or accuracy test
has been performed. Current app remains unchanged.
