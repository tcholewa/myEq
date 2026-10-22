# Security review and hardening — 0.4

This is a source review with isolated regression tests, not an independent penetration test or a certification. The baseline was commit `a8f9758`; the runtime hardening begins at `bb72948`. Tests do not claim root escalation or unauthorized audio capture was demonstrated.

## Threat model

Consider an unrelated local process sending malformed or stale XPC traffic, users in other login sessions, corrupted shared-memory metadata, malicious filesystem objects at installation paths, interrupted upgrades, and accidental credential exposure in CI. Protect audio/session ownership, ordinary playback recovery, root installer operations and distribution integrity. A compromised root account, malicious Apple platform services, or compromised signing keys are outside the enforced boundary. An authenticated app remains capable of reading the audio mapping it is intentionally granted; XPC authentication is not a restriction on the legitimate user's access to their own playback.

## Findings and changes

| Area | Evidence before hardening | Mitigation and verification |
| --- | --- | --- |
| Missing XPC reply context | An isolated one-way recovery status request trapped while populating a null reply. | Reject requests without reply context before running handlers; anonymous XPC and parser tests exercise one-way traffic. |
| Stale session ownership | A direct bridge-handler fixture accepted a non-current connection's close operation. This did not establish a reachable unauthenticated exploit. | Require current peer, foreground UID/audit session and generation on session mutations. Reject stale generations through real anonymous endpoints. |
| Expired driver lease | An isolated driver fixture copied 16 frames after its deadline. | Check the deadline on every WriteMix; expired-lease test asserts no frames copied. |
| Malformed replies | A wrong-type error field was treated as success in an isolated parser probe. | Require typed protocol/error fields and bounded strings; regression cases and fixed-seed fuzzing. |
| Blocking recovery and late replies | Source review found blocking control-queue RPC and restoration paths that could overlap session changes. | Asynchronous requests with deadlines; epoch/peer checks; bridge retirement and settlement prevent a new open during restoration. Mocked sequencing tests cover stale callbacks, timeouts and settlement retry. |
| Persistence | Unbounded reads and weaker path/metadata checks in source. | 4 MiB settings, 64 KiB trust and 16 KiB journal bounds; descriptor-based reads, link/owner/mode/ACL checks, private atomic writes. Global trust also validates ancestor directories. |
| Installer trust/path handling | Source review found recursive permission repair and recovery execution without a verified private snapshot. No privileged exploit was executed. | Native one-shot maintenance, fixed operations/paths, descriptor traversal, signed-component/manifest checks, verified snapshots, quarantine/inode checks. Hostile fixtures cover links, permissions, ACLs and altered components. |
| Distribution | Default builds were only ad-hoc signed. | Separate Developer ID signing/notarization path, strict package verifier, ephemeral CI keychain and maintainer validation gate. No production credentials were used during this work. |

## Validation and remaining work

The native suite runs with ASan and UBSan, including 25,000 deterministic malformed-message/ring-metadata cases and actual anonymous XPC signature acceptance/rejection. Console-user discovery is mocked, so this does not prove isolation across real macOS logins. Recovery sequencing tests mock Core Audio and RPC completion; they do not prove live device fallback. Clang static analysis covers the driver, helpers, client, DSP and maintenance utility.

Installer tests compile the same maintenance source with an unprivileged fixture root and service calls suppressed. They validate snapshots, rollback, removal and rejection of malicious files without invoking root or changing installed services. They do not validate Apple Installer's real payload deployment, system directory races, launchd/Background Items behavior, or crash consistency across all filesystem operations. A partially failed rollback retains recovery stages and refuses service startup; automatic transactional rollback of every package operation is not claimed.

Before a public binary: execute the [clean-Mac/hardware checklist](VERIFICATION.md#remaining-hardware-acceptance-checks), including actual multi-user transitions, rapid enable/disable, app/bridge/recovery/driver-host failures, output disconnects, sleep/wake and CPU measurements. Specifically verify driver bundle trust reads under the real audio-host sandbox, existing-installation migration and malformed-file rejection. Validate Developer ID signing, notarization/stapling and a quarantined download with real credentials. These are release gates, not tests reported as passed. See [release setup](RELEASING.md).

No network listener, telemetry or audio recording was added. Audio callbacks perform no new file IO, signature checks, allocation or IPC; lease enforcement uses existing atomic state. Performance targets remain subject to measurement on the installed build.

## Lock/session recovery update (0.4.4)

The lock-related changes retain code-signing constraints, foreground console ownership, matching peer audit sessions, generation checks and existing lease deadlines. Only transient XPC failures and explicitly retryable recovery results authorize bounded reconnection; malformed replies and signing/protocol failures do not. Screen lock is not treated as authorization to bypass console ownership. Activity declarations allow idle system sleep and exist only for audio/recovery work. Fixtures cover retired-generation heartbeat classification, mismatched console/audit sessions and stale activation cleanup; actual multi-user and locked-screen behavior still require hardware validation.
