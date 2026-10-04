# macOS menu screenshot

Capture the running app's actual native menu over a temporary plain backdrop.
The script saves a PNG with the native rounded corners and shadow. It briefly
covers the desktop while you open the CloudGateway menu, captures it, then
removes the backdrop and returns to your previous app.

1. Run CloudGateway and prepare the state to show, such as a connected VPN.
2. Close other CloudGateway dialogs and leave its menu closed.
3. From the repository root, run:

   ```sh
   swift scripts/macos-menu-screenshot.swift
   ```

4. When the plain backdrop appears, click the CloudGateway menu bar icon within
   30 seconds. Leave the pointer on the icon so no menu row is highlighted.
   The script captures the menu automatically after it opens.

The default output is `docs/images/macos-menu.png`. To save another copy:

```sh
swift scripts/macos-menu-screenshot.swift /tmp/cloudgateway-menu.png
```

The app launching the command needs Screen Recording access.
For the first capture, request the permissions with:

```sh
swift scripts/macos-menu-screenshot.swift --permissions
```

In System Settings → Privacy & Security, enable the launching app (Terminal or
T3 Code, as identified by macOS) under Screen Recording. If
macOS requests a restart of that app, restart it, then rerun the capture command.
The script uses the live menu state and does not change VPN connections.
