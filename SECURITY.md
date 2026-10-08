# Security

This is a prerelease SDK. Report suspected vulnerabilities privately through the repository's GitHub Security advisory reporting if enabled. Do not include production signing keys, editor sessions, or personal data in public issues; for ordinary reproducible bugs, use the test-only fixture configuration.

The trust anchor is the pinned Ed25519 public key in app configuration. HTTPS transports signed content, but a TLS connection alone does not authorize a release. Exact UTF-8 signatures, organization/app scope, same-origin delivery paths, sequence monotonicity, and content hashes are enforced independently. Equal-sequence payload comparison is byte-based, not Swift's Unicode-equivalent String equality.

The supplied disk adapter verifies persisted signed history and atomically commits state with a cross-instance OS lock. It refuses corrupted or regressed state. Custom `AssetStorage` implementations must provide the documented atomic monotonic commit behavior. Namespace storage by the complete configuration, including origin and pinned key.

Removing application data removes the local rollback watermark. This preview does not defend against an attacker controlling the application's sandbox, compromised signing keys, or a compromised app binary. Disconnecting does not erase the watermark. Recovery from corrupt local state currently requires an explicit app-data reset; do not silently delete state in response to a verification failure. Key rotation requires shipping a new trusted configuration.

Delivery accepts only still WebP files with bounded compressed size, bounded decoded dimensions, a successful ImageIO decode, and the signed placement's aspect ratio. Keep the operating system updated. The SDK does not download executable code or change app layout.

The test fixture keys are deterministic, explicitly public test material and must never be trusted by a production deployment. No production configuration belongs in a package or demonstration repository.
