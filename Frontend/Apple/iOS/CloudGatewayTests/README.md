# CloudGatewayTests

Unit tests for `CloudGatewayViewModel` using a mock `CloudGatewayServicing` and
in-memory fakes for the shared-kit tunnel/cache protocols.

## Why this is a host-less (logic) test bundle

The app scheme cannot build for the iOS Simulator: the `CloudGatewayTunnel`
packet-tunnel extension links WireGuard's `libwg-go.a`, which is device-`arm64` only.
So the usual `@testable import CloudGateway` (which builds and hosts the app, and thus
the extension) fails on the simulator.

Instead this target is a **Unit Testing Bundle with no host application** that recompiles
the Firebase-free view-model core directly, linking only `CloudGatewayKit`. It has no
dependency on the app target, Firebase, or the extension, so it builds and runs on the
simulator.

## One-time Xcode wiring

1. **File > New > Target… > Unit Testing Bundle.** Name it `CloudGatewayTests`.
   Set **Host Application: None** (a logic test bundle).
2. Point the target's folder at this directory so the synchronized group picks up the
   three source files here (`GatewayTestDoubles.swift`, `MockGatewayService.swift`,
   `CloudGatewayViewModelTests.swift`).
3. Add the **`CloudGatewayKit`** package product to the target
   (General > Frameworks and Libraries, or the Frameworks build phase).
4. Add the two Firebase-free app sources to this target's membership (File Inspector >
   Target Membership, tick `CloudGatewayTests`):
   - `CloudGateway/CloudGatewayViewModel.swift`
   - `CloudGateway/CloudGatewayServicing.swift`
   Do **not** add `CloudGatewayFirebaseService.swift` (it imports Firebase and holds the
   live `convenience init()`); the mock replaces it.
5. Set the target's **Swift Language Version** to match the app (5.0) and a Deployment
   Target the installed simulators support.
6. Mark the generated `CloudGatewayTests` scheme **Shared** (Manage Schemes… > Shared)
   so it runs from the command line.

## Running

```sh
xcodebuild test \
  -project Frontend/Apple/iOS/CloudGateway.xcodeproj \
  -scheme CloudGatewayTests \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

Once the shared scheme exists, this command can be added to `test_apple` in
`scripts/test.sh` (it is intentionally not wired in yet, since the scheme does not exist
until the target is created).
