# Security Policy

## Scope

This policy covers `ship.sh` only. Vulnerabilities in third-party tools invoked by the script (Xcode, UE5/UAT, `notarytool`, `codesign`, Steam SDK) should be reported to their respective maintainers.

## Credential handling

`ship.sh` does not transmit credentials. Signing identities are read from the local macOS keychain, and notarization uses a locally stored notary profile (via `xcrun notarytool`). No secrets are sent to any server controlled by this project.

Sensitive values (`DEVELOPMENT_TEAM`, `SIGN_IDENTITY`, `NOTARY_PROFILE`) are read from a local `.env` file that is never committed (it is listed in `.gitignore`).

## Reporting a vulnerability

If you find a security issue in `ship.sh` (e.g. command injection, unsafe file handling, credential leakage):

1. **Do not open a public GitHub issue.**
2. Use [GitHub's private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability) for this repository, or email the maintainer directly (address in the commit history).
3. Include:
   - A description of the vulnerability and its impact
   - Steps to reproduce or a minimal proof-of-concept
   - The version of `ship.sh` (commit SHA) where you observed it

We aim to acknowledge reports within 5 business days and to release a fix within 30 days for confirmed issues.
