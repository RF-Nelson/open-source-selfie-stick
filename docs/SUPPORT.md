# Shot Caller support

Shot Caller needs two nearby iPhones or iPads with the app installed. One takes the photos; the other controls it. Both devices need iOS or iPadOS 18 or later. Keep both apps open while connecting, capturing, and transferring.

## Connect normally

1. Turn on Bluetooth and Wi-Fi on both devices.
2. Choose **Camera** on one and **Remote** on the other.
3. On the remote, select the camera and enter the four-digit code shown on its screen.
4. Use the remote's shutter, timer, camera switch, or video controls.

Bluetooth carries controls without a shared Wi-Fi network. Joining the same Wi-Fi network can make transferring full photos and videos faster. When a file is waiting on Bluetooth, use **Download** and choose the size you want.

## Wi-Fi Aware

Wi-Fi Aware is an optional connection method. Both devices need iOS or iPadOS 26 or later and hardware that supports it. The app checks availability on each device. Enable **Wi-Fi Aware** in the **Connection** section of both home screens before choosing roles, then follow the camera and remote's system pairing controls. The system pairing flow replaces the app's four-digit code.

After confirming Apple's prompt, tap **Done pairing** on the camera if its pairing panel is still open. This releases the service so the selected remote can connect; it is particularly important when pairing a device you used before. The remote connects to the camera selected in the prompt.

If the camera doesn't appear, make sure both devices use the same connection method and keep the camera's pairing interface open while the remote searches. Canceling system pairing should let you try again. To return to Automatic connection, close the sessions and turn Wi-Fi Aware off on both home screens.

## Permissions and missing copies

Camera access belongs on the device taking pictures. Microphone access adds sound to videos; if it is denied, videos record without sound and the camera says so. Photos access lets either device save copies without reading your existing library. Bluetooth and local network permissions let the devices connect. If a permission was denied, open **Settings → Apps → Shot Caller** to change it, then return to the app.

Check the camera's **Keep copies** setting and the remote's copy preferences. The remote receives previews even when full copies are off. A preview does not mean the original has been saved. If a transfer is waiting, keep both devices open and connected until it finishes. Captures that were not saved are temporary; save wanted copies before ending the session.

## Contact the maintainer

Report a problem or ask a question on the [project's GitHub issues page](https://github.com/RF-Nelson/open-source-selfie-stick/issues). A GitHub account is required to post. Include both device models, iOS/iPadOS versions, the app version, your connection method, and the steps that caused the problem.

Reports are public: do not include private photos, pairing codes, or personal information. See the [privacy policy](PRIVACY.md) for details about how Shot Caller handles your data.
