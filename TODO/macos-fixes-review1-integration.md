# macOS fixes review loop 1 integration

Status: corrections validated, final review complete

## Findings and corrections

* Cancellation drain must wait for VPN command recovery, but not cancelled
  Firebase/Firestore read callbacks. Those reads already have cancellation and
  account fences. Removed the network-task waits from the cancellation barrier.
  See [menu reviewer evidence](macos-fixes-review1-menu.md).
* Firebase SDK exception fixtures required the cause argument. Added it to
  expired-token and certificate-fetch fixtures. See the auth reviewer notes.
* Vulture reported the nested mock return_value assignment as unused. Replaced
  it with a constructed Mock, preserving the exercised SDK lookup behavior.
* The standalone Swift settings test lacked XCTest's framework search/link
  paths. Added explicit macOS SDK, developer framework, Swift overlay, and private
  framework/rpath arguments. Darwin XCTest
  uses its default test suite rather than the Linux XCTMain entry point.
* Switching WireGuard from remote to local made iOS Periphery report unused
  external library APIs. Excluded the fork from app report output, preserving
  the prior remote-dependency scope. App and shared product sources remain strict.
* Local Go/Swift test output needs ignored build locations. Added the bridge's
  existing .tmp and out directories to the fork ignore file.

No live VPN or native auth actions. Initial api/apple validation found the
fixture, harness, and scan failures above. Log:
`/tmp/cloudgateway-macos-eight-fixes-initial.log`.

API checks and 616 tests passed after the corrections. The macOS gate including
the corrected WireGuard harness passed in
`/tmp/cloudgateway-macos-eight-fixes-loop1-harness.log`. Both unsigned Apple
builds and all five scans passed. Loop 2 found no remaining confirmed issues.
