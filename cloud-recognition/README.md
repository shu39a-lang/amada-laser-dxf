# SHEET MASTER — optional AI recognition backend

Prepared but **not yet deployed or connected to the iOS client**. This Cloud Run service uses Vertex AI and rejects requests without verified Firebase App Check tokens. No Google AI API key is embedded in the iOS app. It returns only unverified dimensional candidates, never machine instructions.

Before activation: link billing, enable Vertex AI API, configure service-account IAM and Cloud Run, register Firebase App Check in iOS, select a supported Gemini model and region, configure a secure HTTPS endpoint, and test on actual drawings. Use spending limits/alerts and rate limits. Until these are complete the existing on-device recognition remains unchanged.

The output must be reviewed against the original drawing and verified in the correct AMADA CAD/CAM workflow before any manufacturing use.
