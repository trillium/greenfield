# Signing and credentials: where everything lives

**Rule: no signing material or credential is ever committed.** `scripts/check-secrets.sh` blocks `.p8 .p12 .pfx .mobileprovision .provisionprofile .certSigningRequest .pem .key .keychain AuthKey_* .env*`, private-key blocks and JWT-shaped strings in the pre-commit hook and in `make secrets`. `make doctor` fails if your API key sits inside the work tree.

## What lives where
| Thing | Where | Secret? | In git? |
|---|---|---|---|
| Team ID (10 chars) | `Config/Base.xcconfig` (`DEVELOPMENT_TEAM`) or `Config/Local.xcconfig` | no | Base yes, Local no |
| Bundle id | `Config/Base.xcconfig` (`PRODUCT_BUNDLE_IDENTIFIER`) | no | yes |
| App Store Connect API key `.p8` | A directory outside every repo, e.g. `~/.appstoreconnect/AuthKey_<KEYID>.p8`, mode 600 | **yes** | **never** |
| Key ID, Issuer ID | Env vars `ASC_KEY_ID`, `ASC_ISSUER_ID` (shell profile or secret manager) | low, still not committed | never |
| Path to the key | Env var `ASC_KEY_PATH` | no | never (it is per machine) |
| Distribution/development certificates + private keys | macOS login Keychain (or Apple-managed "cloud signing" when using the API key) | **yes** | never |
| Provisioning profiles | Managed by Xcode (`~/Library/MobileDevice/Provisioning Profiles`); `-allowProvisioningUpdates` fetches them | yes | never |
| Apple ID password / app-specific password | Not used by this pipeline. Do not introduce it. | yes | never |

## How the scripts use them
- `scripts/archive.sh` reads **only environment variables**. When `ASC_KEY_PATH`, `ASC_KEY_ID`, `ASC_ISSUER_ID` are all set they pass `-authenticationKeyPath/-authenticationKeyID/-authenticationKeyIssuerID` to `xcodebuild` so signing and upload are headless. When unset, `archive` falls back to the Apple ID signed in to Xcode > Settings > Accounts.
- There is no upload script yet: nothing in this repo uploads to App Store Connect or TestFlight.
- Simulator work (`make build`, `make test`, `make device-compile`, `make archive-unsigned`) needs none of this and runs with `CODE_SIGNING_ALLOWED=NO`.

## Setting it up
1. Generate the key by hand (App Store Connect > Users and Access > Integrations). Apple shows the `.p8` once.
2. `mkdir -p ~/.appstoreconnect && mv ~/Downloads/AuthKey_<KEYID>.p8 ~/.appstoreconnect/ && chmod 600 ~/.appstoreconnect/AuthKey_<KEYID>.p8`
3. In your shell profile (values are examples, not real):
   ```sh
   export ASC_KEY_PATH="$HOME/.appstoreconnect/AuthKey_ABC123DEFG.p8"
   export ASC_KEY_ID="ABC123DEFG"
   export ASC_ISSUER_ID="00000000-0000-0000-0000-000000000000"
   ```
4. `make doctor SIGNING=1` should now report the key outside the repo with mode 600.

## If a secret leaks
Revoke the key in App Store Connect > Users and Access > Integrations (revocation is immediate), generate a new one, and rewrite history only with the maintainer's approval. Treat anything that reached a remote as compromised.
