# ServiceOps for iOS

<img src="ServiceOps/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="128" alt="ServiceOps app icon">

[![CI](https://github.com/awijesundara/ServiceOps_iOS/actions/workflows/ci.yml/badge.svg)](https://github.com/awijesundara/ServiceOps_iOS/actions/workflows/ci.yml)
[![Last commit](https://img.shields.io/github/last-commit/awijesundara/ServiceOps_iOS/main)](https://github.com/awijesundara/ServiceOps_iOS/commits/main)
[![Top language](https://img.shields.io/github/languages/top/awijesundara/ServiceOps_iOS)](https://github.com/awijesundara/ServiceOps_iOS)
[![Code size](https://img.shields.io/github/languages/code-size/awijesundara/ServiceOps_iOS)](https://github.com/awijesundara/ServiceOps_iOS)
[![version](https://img.shields.io/badge/version-1.4.0%20%28build%209%29-003E4C)](#)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](ServiceOps)
[![iOS](https://img.shields.io/badge/iOS-26.5%2B-000000?logo=apple&logoColor=white)](ServiceOps.xcodeproj)
[![backend](https://img.shields.io/badge/backend-ServiceOps-0C7C68)](https://github.com/awijesundara/ServiceOps)

Native iPhone workspace for the self-hosted
[ServiceOps](https://github.com/awijesundara/ServiceOps) platform. The app uses
the signed-in user's ServiceOps identity; it does not embed or share a static
API key.

Current app version: **1.4.0 (build 9)**

## Screenshots

Six freshly captured previews of **v1.3.2** on iPhone 17 Pro (iOS 26.5). Home includes a sample profile photo; records use example data. [Capture details](docs/screenshots/capture-manifest.json).

<table>
<tr><td width="50%"><img src="docs/screenshots/preview-1.3.2-home.png" width="300" alt="Home dashboard and profile"><br><sub>Home dashboard and profile</sub></td><td width="50%"><img src="docs/screenshots/preview-1.3.2-login.png" width="300" alt="Server-aware sign-in"><br><sub>Server-aware sign-in</sub></td></tr>
<tr><td width="50%"><img src="docs/screenshots/preview-1.3.2-work.png" width="300" alt="My Work and ticket filters"><br><sub>My Work and ticket filters</sub></td><td width="50%"><img src="docs/screenshots/preview-1.3.2-ticket.png" width="300" alt="Ticket details and updates"><br><sub>Ticket details and updates</sub></td></tr>
<tr><td width="50%"><img src="docs/screenshots/preview-1.3.2-assets.png" width="300" alt="CMDB servers and assets"><br><sub>CMDB servers and assets</sub></td><td width="50%"><img src="docs/screenshots/preview-1.3.2-rack.png" width="300" alt="Rack elevation and selected server"><br><sub>Rack elevation and selected server</sub></td></tr>
</table>

## Included capabilities

- Local, LDAP, Keycloak or Cloudflare Access sign-in with MFA and rotating access/refresh tokens.
- Face ID or Touch ID foreground lock and Keychain-protected session storage.
- Passkey registration and passwordless sign-in.
- Home dashboard, assigned incidents and changes, record search and filtering.
- The personal and team dashboards configured on the web (ServiceOps 1.113.54 or later): count tiles, ticket lists, charts, trends, team workload, tasks, approvals, upcoming changes, requests, knowledge, work items, notes and links. Every number opens exactly the tickets it counts.
- Projects: browse projects and their work items, change an item's status and comment on it.
- Incident creation, record updates, work notes, and activity history.
- Linked ticket CIs and services, exact rack destinations, record fields, change governance, reviews, SLAs, approvals, tasks and related records. Detail sections follow server permissions and support older servers.
- Approval actions, knowledge search, searchable assets with site/rack/hardware details, and connection diagnostics.
- Front/rear rack elevations with selected-device highlighting, recorded capacity, placement warnings and optional server-provided totals.
- APNs device registration, real-time ticket/approval/security alerts, and an
  in-app notification inbox.
- User-attributed server audit events containing iOS platform, app version,
  build, and device context.

## Run locally

1. Open `ServiceOps.xcodeproj` in Xcode and select the `ServiceOps` target.
2. Under **Signing & Capabilities**, select your Apple development team.
3. Run on a simulator or a signed iPhone.
4. Enter the HTTPS ServiceOps URL and sign in with your own account.

New installations default to `https://serviceops.wijesundara.com`. Existing saved server addresses are preserved. Enter your own HTTPS ServiceOps endpoint when connecting to another deployment. Local HTTP is for development only; `127.0.0.1` on a physical phone refers to the phone itself.

### Passkeys and signing

Simulator builds retain an application identifier and Associated Domains entitlement. Debug simulator builds also include the Associated Domains developer-mode entry. The `apple-app-site-association` document must be publicly reachable and list your team ID plus bundle identifier.

The current device entitlement file supports builds using a personal development team and omits Associated Domains; **passkeys are unavailable in that device configuration**. For a team provisioned for Associated Domains, set `CODE_SIGN_ENTITLEMENTS[sdk=iphoneos*]` to `ServiceOps/ServiceOps.entitlements` in both Debug and Release and use a matching provisioning profile. Push notifications likewise need a profile with the relevant capability.

Native passkey creation and physical-device acceptance remain to be verified. Simulator build and screenshot checks do not establish either.

Push notifications require a signed build with the Push Notifications
entitlement and matching APNs configuration in ServiceOps:

- Team ID
- APNs key ID
- complete `.p8` private key
- bundle identifier `wijesundara.com.ServiceOps`
- sandbox or production APNs environment matching the installed build

Never commit signing keys, provisioning profiles, credentials, tokens, or
local device inventories. The repository `.gitignore` excludes these files.

## Screenshot maintenance

Repository images show the current SwiftUI views rendered in an iPhone simulator, including scrolled ticket sections and expanded change details. Example responses are intercepted in a separate temporary capture build. Fixture data and capture entrypoints are excluded from the published app source.

## Validation

CI builds the iOS simulator target and runs rack layout and backward-compatible response decoding regressions. Run the same model checks locally:

```sh
xcrun swiftc ServiceOps/Models.swift ServiceOps/RackLayout.swift Tests/main.swift -o /tmp/serviceops-model-checks
/tmp/serviceops-model-checks
```

Screenshot capture uses a separate temporary build with example network responses. No fixture data, capture entrypoint or authentication bypass is included in the published app source.
