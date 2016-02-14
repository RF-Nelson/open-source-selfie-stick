//
//  CameraViewController.swift
//  Open Source Selfie Stick
//
//  Created by Richard Nelson on 2/11/16.
//  Copyright © 2016 Richard Nelson. All rights reserved.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import Foundation
import UIKit
import AVFoundation
import AssetsLibrary
import MultipeerConnectivity

var SessionRunningAndDeviceAuthorizedContext = "SessionRunningAndDeviceAuthorizedContext"
var RecordingContext = "RecordingContext"

class CameraViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    
    var captureDevice : AVCaptureDevice?
    var sessionQueue: dispatch_queue_t!
    var session: AVCaptureSession?
    var videoDeviceInput: AVCaptureDeviceInput?
    var photoFileOutput : AVCaptureStillImageOutput?
    var recordingDateTimer: NSTimer?
    var cameraService = CameraServiceManager()
    var savePhoto : Bool?
    var sendPhoto : Bool?
    var lastImage : UIImage?
    
    var iso : Float = 300.0
    var minIso : Float?
    var maxIso : Float?
    
    var maxColor : Float = 4.0
    
    var red : Float?
    var green : Float?
    var blue : Float?
    var redDefault : Float = 0.0
    var greenDefault : Float = 0.0
    var blueDefault : Float = 0.0
    
    var focusAndExposurePoint : CGPoint?
    
    var deviceAuthorized: Bool = false
    var backgroundRecordId: UIBackgroundTaskIdentifier = UIBackgroundTaskInvalid
    var sessionRunningAndDeviceAuthorized: Bool {
        get {
            return (self.session?.running != nil && self.deviceAuthorized )
        }
    }
    
    var locked: Bool!
    
    var runtimeErrorHandlingObserver: AnyObject?
    var lockInterfaceRotation: Bool = false
    
    @IBOutlet weak var previewView: AVCamPreviewView!
    @IBOutlet weak var lockButton: UIButton!
    @IBOutlet weak var isoLabel: UILabel!
    @IBOutlet weak var isoTextField: UITextField!
    @IBOutlet weak var advancedControlsView: UIView!
    @IBOutlet weak var redLabel: UILabel!
    @IBOutlet weak var greenLabel: UILabel!
    @IBOutlet weak var blueLabel: UILabel!
    @IBOutlet weak var redTextField: UITextField!
    @IBOutlet weak var greenTextField: UITextField!
    @IBOutlet weak var blueTextField: UITextField!
    @IBOutlet weak var flashButton: UIButton!
    @IBOutlet weak var RGBinfo: UILabel!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.advancedControlsView.hidden = true
        isoTextField.keyboardType = .DecimalPad
        redTextField.keyboardType = .DecimalPad
        greenTextField.keyboardType = .DecimalPad
        blueTextField.keyboardType = .DecimalPad
        
        savePhoto = true
        self.locked = false
        let session: AVCaptureSession = AVCaptureSession()
        self.session = session
        self.previewView.session = session
        self.checkDeviceAuthorizationStatus()
        cameraService.delegate = self
        let sessionQueue: dispatch_queue_t = dispatch_queue_create("session queue",DISPATCH_QUEUE_SERIAL)
        
        self.sessionQueue = sessionQueue
        dispatch_async(sessionQueue, {
            self.backgroundRecordId = UIBackgroundTaskInvalid
            
            let videoDevice: AVCaptureDevice! = CameraViewController.deviceWithMediaType(AVMediaTypeVideo, preferringPosition: AVCaptureDevicePosition.Back)
            var error: NSError? = nil
            
            var videoDeviceInput: AVCaptureDeviceInput?
            do {
                videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)
            } catch let error1 as NSError {
                error = error1
                videoDeviceInput = nil
            } catch {
                fatalError()
            }
            
            if (error != nil) {
                print(error)
                let alert = UIAlertController(title: "Error", message: error!.localizedDescription
                    , preferredStyle: .Alert)
                alert.addAction(UIAlertAction(title: "OK", style: .Default, handler: nil))
                self.presentViewController(alert, animated: true, completion: nil)
            }
            
            if session.canAddInput(videoDeviceInput){
                session.addInput(videoDeviceInput)
                self.videoDeviceInput = videoDeviceInput
                dispatch_async(dispatch_get_main_queue(), {
                    // Why are we dispatching this to the main queue?
                    // Because AVCaptureVideoPreviewLayer is the backing layer for AVCamPreviewView and UIView can only be manipulated on main thread.
                    // Note: As an exception to the above rule, it is not necessary to serialize video orientation changes on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.
                    let statusBarOrientation : UIInterfaceOrientation = UIApplication.sharedApplication().statusBarOrientation
                    var initialVideoOrientation : AVCaptureVideoOrientation = AVCaptureVideoOrientation.LandscapeLeft
                    
                    if ( statusBarOrientation != UIInterfaceOrientation.Unknown ) {
                        initialVideoOrientation = AVCaptureVideoOrientation(ui: statusBarOrientation);
                    }
                    
                    (self.previewView.layer as! AVCaptureVideoPreviewLayer).connection.videoOrientation = initialVideoOrientation
                    
                })
                
            }
            
            let audioDevice: AVCaptureDevice = AVCaptureDevice.devicesWithMediaType(AVMediaTypeAudio).first as! AVCaptureDevice
            
            var audioDeviceInput: AVCaptureDeviceInput?
            
            do {
                audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice)
            } catch let error2 as NSError {
                error = error2
                audioDeviceInput = nil
            } catch {
                fatalError()
            }
            
            if error != nil{
                print(error)
                let alert = UIAlertController(title: "Error", message: error!.localizedDescription
                    , preferredStyle: .Alert)
                alert.addAction(UIAlertAction(title: "OK", style: .Default, handler: nil))
                self.presentViewController(alert, animated: true, completion: nil)
            }
            
            if session.canAddInput(audioDeviceInput){
                session.addInput(audioDeviceInput)
            }
            
            let tempPhotoFileOutput: AVCaptureStillImageOutput = AVCaptureStillImageOutput()
            if session.canAddOutput(tempPhotoFileOutput){
                session.addOutput(tempPhotoFileOutput)
                self.photoFileOutput = tempPhotoFileOutput
            }
        })
        
        let devices = AVCaptureDevice.devices()
        
        // Loop through all the capture devices on this phone
        for device in devices {
            // Make sure this particular device supports video
            if (device.hasMediaType(AVMediaTypeVideo)) {
                // Finally check the position and confirm we've got the back camera
                if(device.position == AVCaptureDevicePosition.Back) {
                    captureDevice = device as? AVCaptureDevice
                }
            }
        }
    }
    
    override func viewWillAppear(animated: Bool) {
        self.isoLabel.text = String(self.iso)
        
        self.cameraService.serviceAdvertiser.startAdvertisingPeer()
        dispatch_async(self.sessionQueue, {
            
            self.addObserver(self, forKeyPath: "sessionRunningAndDeviceAuthorized", options: [.Old , .New] , context: &SessionRunningAndDeviceAuthorizedContext)
            
            NSNotificationCenter.defaultCenter().addObserver(self, selector: "subjectAreaDidChange:", name: AVCaptureDeviceSubjectAreaDidChangeNotification, object: self.videoDeviceInput?.device)
            
            weak var weakSelf = self
            
            self.runtimeErrorHandlingObserver = NSNotificationCenter.defaultCenter().addObserverForName(AVCaptureSessionRuntimeErrorNotification, object: self.session, queue: nil, usingBlock: {
                (note: NSNotification?) in
                let strongSelf: CameraViewController = weakSelf!
                dispatch_async(strongSelf.sessionQueue, {
                    //                    strongSelf.session?.startRunning()
                    if let sess = strongSelf.session{
                        sess.startRunning()
                    }
                    //                    strongSelf.recordButton.title  = NSLocalizedString("Record", "Recording button record title")
                })
                
            })
            
            self.session?.startRunning()
        })
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewDidAppear(animated)
        
        self.focusWithMode(AVCaptureFocusMode.AutoFocus, exposureMode: AVCaptureExposureMode.AutoExpose, point: CGPoint(x: 0.5, y: 0.5), monitorSubjectAreaChange: true)
        
        let saveAlert = UIAlertController(title: "Save photos", message: "Do you want to save photos from this session to this device?", preferredStyle: UIAlertControllerStyle.Alert)
        
        saveAlert.addAction(UIAlertAction(title: "Yes", style: .Default, handler: { (action: UIAlertAction!) in
            self.savePhoto = true
        }))
        
        saveAlert.addAction(UIAlertAction(title: "No", style: .Default, handler: { (action: UIAlertAction!) in
            self.savePhoto = false
        }))
        
        presentViewController(saveAlert, animated: true, completion: nil)
    }
    
    override func viewWillDisappear(animated: Bool) {
        self.cameraService.serviceAdvertiser.stopAdvertisingPeer()
        
        dispatch_async(self.sessionQueue, {
            if let sess = self.session{
                sess.stopRunning()
                
                NSNotificationCenter.defaultCenter().removeObserver(self, name: AVCaptureDeviceSubjectAreaDidChangeNotification, object: self.videoDeviceInput?.device)
                NSNotificationCenter.defaultCenter().removeObserver(self.runtimeErrorHandlingObserver!)
                
                self.removeObserver(self, forKeyPath: "sessionRunningAndDeviceAuthorized", context: &SessionRunningAndDeviceAuthorizedContext)
                self.removeObserver(self, forKeyPath: "movieFileOutput.recording", context: &RecordingContext)
            }
        })
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
    override func prefersStatusBarHidden() -> Bool {
        return true
    }
    
    override func willRotateToInterfaceOrientation(toInterfaceOrientation: UIInterfaceOrientation, duration: NSTimeInterval) {
        
        (self.previewView.layer as! AVCaptureVideoPreviewLayer).connection.videoOrientation = AVCaptureVideoOrientation(rawValue: toInterfaceOrientation.rawValue)!
        
        //        if let layer = self.previewView.layer as? AVCaptureVideoPreviewLayer{
        //            layer.connection.videoOrientation = self.convertOrientation(toInterfaceOrientation)
        //        }
        
    }
    
    func takePhoto() {
        dispatch_async(self.sessionQueue, {
            if let videoConnection = self.photoFileOutput!.connectionWithMediaType(AVMediaTypeVideo) {
                if UIDevice.currentDevice().multitaskingSupported {
                    self.backgroundRecordId = UIApplication.sharedApplication().beginBackgroundTaskWithExpirationHandler({})
                }
                
                self.photoFileOutput!.captureStillImageAsynchronouslyFromConnection(videoConnection) {
                    (imageDataSampleBuffer, error) -> Void in
                    let imageData = AVCaptureStillImageOutput.jpegStillImageNSDataRepresentation(imageDataSampleBuffer)
                    self.lastImage = UIImage(data: imageData)!
                    let outputFilePath = NSURL(fileURLWithPath: NSTemporaryDirectory()).URLByAppendingPathComponent("photo.jpg")
                    UIImageJPEGRepresentation(self.lastImage!, 100)?.writeToURL(outputFilePath, atomically: true)
                    self.cameraService.transferFile(outputFilePath)
                    
                    if (self.savePhoto!) {
                        ALAssetsLibrary().writeImageToSavedPhotosAlbum(self.lastImage!.CGImage, orientation: ALAssetOrientation(rawValue: self.lastImage!.imageOrientation.rawValue)!, completionBlock: nil)
                    }
                }
            }
        })
    }
    
    override func shouldAutorotate() -> Bool {
        return !self.lockInterfaceRotation
    }
    
    func captureOutput(captureOutput: AVCaptureFileOutput!, didFinishRecordingToOutputFileAtURL outputFileURL: NSURL!, fromConnections connections: [AnyObject]!, error: NSError!) {
        
        if(error != nil){
            print(error)
        }
        
        self.cameraService.transferFile(outputFileURL)
    }
    
    func subjectAreaDidChange(notification: NSNotification){
    }
    
    func focusWithMode(focusMode:AVCaptureFocusMode, exposureMode:AVCaptureExposureMode, point:CGPoint, monitorSubjectAreaChange:Bool){
        dispatch_async(self.sessionQueue, {
            let device: AVCaptureDevice! = self.videoDeviceInput!.device
            
            do {
                try device.lockForConfiguration()
                
                if device.focusPointOfInterestSupported && device.isFocusModeSupported(focusMode){
                    device.focusMode = focusMode
                    device.focusPointOfInterest = point
                }
                
                if device.exposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode){
                    //                    device.exposurePointOfInterest = point
                    //                    device.exposureMode = exposureMode
                    
                    if (self.minIso == nil) {
                        self.minIso = device.activeFormat.minISO
                        self.maxIso = device.activeFormat.maxISO
                        self.maxColor = device.maxWhiteBalanceGain
                        let focusString = "Tap screen to focus on that point. Click lock to lock the focus."
                        let ISOstring = "\nThe ISO value must be between " + self.minIso!.description + " and " + self.maxIso!.description
                        let RGBstring = "\nAll three RGB values must be between 1.0 and " + self.maxColor.description
                        self.RGBinfo.text = focusString + ISOstring + RGBstring
                    }
                    
                    device.setExposureModeCustomWithDuration(AVCaptureExposureDurationCurrent, ISO: self.iso, completionHandler: nil)
                }
                
                if device.hasFlash && device.isFlashModeSupported(AVCaptureFlashMode.Off) {
                    device.flashMode = AVCaptureFlashMode.Off
                }
                
                if (self.green == nil) {
                    self.red = self.redDefault
                    self.green = self.greenDefault
                    self.blue = self.blueDefault
                    self.redLabel.text = self.red?.description
                    self.greenLabel.text = self.green?.description
                    self.blueLabel.text = self.blue?.description
                }
                
                // THIS CODE SETS CUSTOM RGB WHITE BALANCE VALUES
                let gains = AVCaptureWhiteBalanceGains(redGain: self.red!, greenGain: self.green!, blueGain: self.blue!)
                
                if (gains.redGain >= 1.0 && gains.redGain <= self.maxColor &&
                    gains.greenGain >= 1.0 && gains.greenGain <= self.maxColor &&
                    gains.blueGain >= 1.0 && gains.blueGain <= self.maxColor) {
                        device.setWhiteBalanceModeLockedWithDeviceWhiteBalanceGains(gains, completionHandler: nil)
                } else {
                    device.whiteBalanceMode = .ContinuousAutoWhiteBalance
                }
                
                device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
                device.unlockForConfiguration()
                
            }catch{
                print(error)
            }
        })
    }
    
    func checkDeviceAuthorizationStatus(){
        let mediaType:String = AVMediaTypeVideo;
        
        AVCaptureDevice.requestAccessForMediaType(mediaType, completionHandler: { (granted: Bool) in
            if granted{
                self.deviceAuthorized = true;
            }else{
                
                dispatch_async(dispatch_get_main_queue(), {
                    let alert: UIAlertController = UIAlertController(
                        title: "AVCam",
                        message: "AVCam does not have permission to access camera",
                        preferredStyle: UIAlertControllerStyle.Alert);
                    
                    let action: UIAlertAction = UIAlertAction(title: "OK", style: UIAlertActionStyle.Default, handler: {
                        (action2: UIAlertAction) in
                        exit(0);
                    } );
                    
                    alert.addAction(action);
                    
                    self.presentViewController(alert, animated: true, completion: nil);
                })
                
                self.deviceAuthorized = false;
            }
        })
        
    }
    
    class func setFlashMode(flashMode: AVCaptureFlashMode, device: AVCaptureDevice){
        if device.hasFlash && device.isFlashModeSupported(flashMode) {
            var error: NSError? = nil
            do {
                try device.lockForConfiguration()
                device.flashMode = flashMode
                device.unlockForConfiguration()
                
            } catch let error1 as NSError {
                error = error1
                print(error)
            }
        }
    }
    
    class func deviceWithMediaType(mediaType: String, preferringPosition:AVCaptureDevicePosition)->AVCaptureDevice{
        var devices = AVCaptureDevice.devicesWithMediaType(mediaType);
        var captureDevice: AVCaptureDevice = devices[0] as! AVCaptureDevice;
        
        for device in devices{
            if device.position == preferringPosition{
                captureDevice = device as! AVCaptureDevice
                break
            }
        }
        
        return captureDevice
    }
    
    @IBAction func pressLock(sender: AnyObject) {
        if self.locked == true {
            self.locked = false
            self.lockButton.selected = false
            self.isoTextField.hidden = false
            self.redTextField.hidden = false
            self.greenTextField.hidden = false
            self.blueTextField.hidden = false
        } else {
            self.locked = true
            self.lockButton.selected = true
            self.isoTextField.hidden = true
            self.redTextField.hidden = true
            self.greenTextField.hidden = true
            self.blueTextField.hidden = true
        }
        
        print("CAMERA SETTINGS LOCK HAS BEEN CHANGED TO: \(self.locked)")
    }
    
    @IBAction func isoTextFieldEditingDidEnd(sender: AnyObject) {
        let selectedIso = Float(self.isoTextField.text!)
        self.isoTextField.text = ""
        
        if selectedIso != nil {
            if selectedIso! < (self.minIso!) {
                self.iso = self.minIso!
            } else if  selectedIso! > (self.maxIso!) {
                self.iso = self.maxIso!
            } else {
                self.iso = selectedIso!
            }
            
            self.isoLabel.text = self.iso.description
        }
        self.isoTextField.endEditing(true)
    }
    
    @IBAction func redTextFieldEditingDidEnd(sender: AnyObject) {
        let selectedRed = Float(self.redTextField.text!)
        self.redTextField.text = ""
        
        if selectedRed != nil {
            
            if selectedRed! < 1.0 {
                self.red = 1.0
            } else if selectedRed! > self.maxColor {
                self.red = self.maxColor
            } else {
                self.red = selectedRed!
            }
            
            self.redLabel.text = self.red?.description
        }
    }
    
    @IBAction func greenTextFieldEditingDidEnd(sender: AnyObject) {
        let selectedGreen = Float(self.greenTextField.text!)
        self.greenTextField.text = ""
        
        if selectedGreen != nil {
            
            if selectedGreen! < 1.0 {
                self.green = 1.0
            } else if selectedGreen! > self.maxColor {
                self.green = self.maxColor
            } else {
                self.green = selectedGreen!
            }
            
            self.greenLabel.text = self.green?.description
        }
    }
    
    @IBAction func blueTextFieldEditingDidEnd(sender: AnyObject) {
        let selectedBlue = Float(self.blueTextField.text!)
        self.blueTextField.text = ""
        
        if selectedBlue != nil {
            
            if selectedBlue! < 1.0 {
                self.blue = 1.0
            } else if selectedBlue! > self.maxColor {
                self.blue = self.maxColor
            } else {
                self.blue = selectedBlue!
            }
            
            self.blueLabel.text = self.blue?.description
        }
    }
    
    @IBAction func focusAndExposeTap(gestureRecognizer: UIGestureRecognizer) {
        print("will reset configuration: \(!self.locked)")
        if !self.locked {
            let devicePoint: CGPoint = (self.previewView.layer as! AVCaptureVideoPreviewLayer).captureDevicePointOfInterestForPoint(gestureRecognizer.locationInView(gestureRecognizer.view))
            
            self.focusWithMode(AVCaptureFocusMode.AutoFocus, exposureMode: AVCaptureExposureMode.AutoExpose, point: devicePoint, monitorSubjectAreaChange: true)
        }
    }
    
    @IBAction func settingsTapped(sender: AnyObject) {
        advancedControlsView.hidden = !advancedControlsView.hidden
    }
    
    // HIDE KEYBOARD WHEN IT LOSES FOCUS
    override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
        self.view.endEditing(true)
        super.touchesBegan(touches, withEvent: event)
    }
    
    @IBAction func flashButtonTapped(sender: AnyObject) {
        self.toggleFlash()
    }
    
    func toggleFlash() {
        if (self.videoDeviceInput!.device.flashAvailable) {
            let device = self.videoDeviceInput!.device
            if (self.videoDeviceInput!.device.flashMode == AVCaptureFlashMode.Off) {
                do {
                    try device.lockForConfiguration()
                    device.flashMode = AVCaptureFlashMode.On
                    device.unlockForConfiguration()
                    let image = UIImage(named: "noFlash.png")
                    self.flashButton.setImage(image, forState: UIControlState.Normal)
                } catch let error as NSError {
                    print(error)
                }
            } else {
                do {
                    try device.lockForConfiguration()
                    device.flashMode = AVCaptureFlashMode.Off
                    device.unlockForConfiguration()
                    let image = UIImage(named: "flash.png")
                    self.flashButton.setImage(image, forState: UIControlState.Normal)
                } catch let error as NSError {
                    print(error)
                }
            }
        }
    }
    
    @IBAction func resetRGB(sender: AnyObject) {
        self.red = redDefault
        self.green = greenDefault
        self.blue = blueDefault
        self.iso = 300
        self.isoLabel.text = "300"
        self.redLabel.text = self.red?.description
        self.greenLabel.text = self.green?.description
        self.blueLabel.text = self.blue?.description
        self.focusWithMode(AVCaptureFocusMode.AutoFocus, exposureMode: AVCaptureExposureMode.AutoExpose, point: CGPoint(x: 0.5, y: 0.5), monitorSubjectAreaChange: true)
    }
    
    
}

extension CameraViewController : CameraServiceManagerDelegate {
    func connectedDevicesChanged(manager: CameraServiceManager, state: MCSessionState, connectedDevices: [String]) {
        // TO DO: ADD SOME KIND OF AUTHENTICATION
        // FOR NOW, IT AUTOMATICALLY CONNECTS
    }
    
    func shutterButtonTapped(manager: CameraServiceManager, _ sendPhoto: Bool) {
        self.sendPhoto = sendPhoto
        dispatch_async(dispatch_get_main_queue(), {
            self.takePhoto()
        })
    }
    
    func toggleFlash(manager: CameraServiceManager) {
        dispatch_async(dispatch_get_main_queue(), {
            self.toggleFlash()
        })
    }
    
    func didStartReceivingData(manager: CameraServiceManager, withName resourceName: String, withProgress progress: NSProgress) {
    }
    
    func didFinishReceivingData(manager: CameraServiceManager, url: NSURL) {
    }
}

extension AVCaptureVideoOrientation {
    var uiInterfaceOrientation: UIInterfaceOrientation {
        get {
            switch self {
            case .LandscapeLeft:        return .LandscapeLeft
            case .LandscapeRight:       return .LandscapeRight
            case .Portrait:             return .Portrait
            case .PortraitUpsideDown:   return .PortraitUpsideDown
            }
        }
    }
    
    init(ui:UIInterfaceOrientation) {
        switch ui {
        case .LandscapeRight:       self = .LandscapeRight
        case .LandscapeLeft:        self = .LandscapeLeft
        case .Portrait:             self = .Portrait
        case .PortraitUpsideDown:   self = .PortraitUpsideDown
        default:                    self = .Portrait
        }
    }
}