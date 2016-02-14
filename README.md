<div align="center"><img src="http://i.imgur.com/gbbeJFH.png"/><br><br></div><h4>_Q: What is Open Source Selfie Stick?_<br>A: A free open source iOS app which allows one iOS device to act as a camera remote for another iOS device. Put your phone across the room and use your friend's phone to take pictures and have the photos sent to either one or both!<br><br>_Q: How does this app work?_<br>A: This app leverages the [Multipeer Connectivity Framework](https://developer.apple.com/library/ios/documentation/MultipeerConnectivity/Reference/MultipeerConnectivityFramework/) to allow the devices to communicate over WiFi.<br><br>_Q: Does it work over Bluetooth?_<br>A: Not completely. Bluetooth is much slower than WiFi; for example, it can take 5-10 seconds for the two devices to find one another over Bluetooth, while over WiFi it is almost instantaneous. Once connected, you can use the remote control to take pictures and save them to the camera device without issue, but having pictures sent back and saved to the remote control device over Bluetooth will fail or take too long.<br><br>_Q: Can I contribute to the development of this app?_<br>A: Yes! Feel free to fork this repo, look at the to-do list, and make a pull request.<br><br>_Q: Can I download this app from the App Store?_<br>A: This app is currently pending review/release on the App Store. Alternatively, you can open this project on any Mac with Xcode 7.2.1 and build it on any Apple mobile device with iOS v8.1 or higher via USB.

### TO DO
- [x] Give user the option to save photos on either or both devices
- [x] Add an optional timer
- [ ] Add file transfer status bar if remote control device is receiving a file
- [ ] Viewable gallery of photos from current/most recent session
- [ ] Detect Bluetooth connection and compress photo if being sent back to remote control device
- [ ] Make a more aesthetically pleasing UI
- [ ] Share your newly taken photos on Facebook and Twitter with SocialKit
- [ ] Allow the recording and sharing of video clips
- [ ] Allow the device acting as the remote control to receive a live video feed
- [ ] Allow multiple devices to act as cameras or remotes
- [ ] Refactor
- [ ] Come up with a better name than "Open Source Selfie Stick"

<br><br>
__*License*__<br>
This software is licensed under the [MPL version 2.0](http://mozilla.org/MPL/2.0/).<br>

__*Logo credits*__<br>
Logo created with <a href="http://logomakr.com" title="Logo Maker">Logo Maker</a>. The camera, person, and phone icons seens within the logo are from <a href="http://www.freepik.com/">Freepik</a> from <a href="http://www.flaticon.com/">Flaticon</a>. They are licensed under <a href="http://creativecommons.org/licenses/by/3.0/" title="Creative Commons BY 3.0">CC BY 3.0</a>.

__*Special Thanks*__<br>
Thanks to [Joystick Interactive](https://github.com/joystickinteractive/), [Alex Konrad](https://github.com/alexkonrad), [Ralf Ebert](https://www.ralfebert.de/tutorials/ios-swift-multipeer-connectivity/), and [Ray Wenderlich](http://www.raywenderlich.com/). Without them, this project may never have happened.
