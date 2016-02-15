//
//  CameraControllerViewController.swift
//  Open Source Selfie Stick
//
//  Created by Richard Nelson on 2/11/16.
//  Copyright © 2016 Richard Nelson. All rights reserved.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import UIKit
import MultipeerConnectivity
import AssetsLibrary

var FileTransferProgressContext = "FileTransferProgressContext"

class CameraControllerViewController : UIViewController {
    
    var cameraService = CameraServiceManager()
    let deviceName = UIDevice.currentDevice().name
    var localURL : NSURL?
    var savePhoto : Bool?
    var timeDelay : Int?
    dynamic var fileTransferProgress : NSProgress!
    
    @IBOutlet weak var takePhoto: UIButton!
    @IBOutlet weak var timerLabel: UILabel!
    @IBOutlet weak var timerTextField: UITextField!
    @IBOutlet weak var timerHelpLabel: UILabel!
    @IBOutlet weak var flashButton: UIButton!
    @IBOutlet weak var fileTransferLabel: UITextField!
    @IBOutlet weak var progressView: UIProgressView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.cameraService.delegate = self
        disableButton()
        timeDelay = 0
        timerLabel.hidden = true
        timerTextField.hidden = true
        timerTextField.keyboardType = .NumberPad
        timerHelpLabel.hidden = true
        hideFileTransferLabel()
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        self.progressView.hidden = true
        self.progressView.progress = 0
        
        self.cameraService.serviceBrowser.startBrowsingForPeers()
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        if (self.cameraService.session.connectedPeers.count > 0) {
            enableButton()
        }
        
        promptToSavePhotos()
    }
    
    func promptToSavePhotos() {
        let saveAlert = UIAlertController(title: "Save photos to this device?", message: "Do you want to save photos from this session to this device? (If connected via Bluetooth, this may be slow)", preferredStyle: UIAlertControllerStyle.Alert)
        
        saveAlert.addAction(UIAlertAction(title: "Yes", style: .Default, handler: { (action: UIAlertAction!) in
            self.savePhoto = true
        }))
        
        saveAlert.addAction(UIAlertAction(title: "No", style: .Default, handler: { (action: UIAlertAction!) in
            self.savePhoto = false
        }))
        
        presentViewController(saveAlert, animated: true, completion: nil)
    }
    
    @IBAction func takePhotoTapped(sender: AnyObject) {
        countdownToPhoto()
    }
    
    func countdownToPhoto() {
        if (timeDelay != 0) {
            takePhoto.hidden = true
            timerLabel.hidden = false
            timerLabel.text = timeDelay?.description
            timeDelay!--
            NSTimer.scheduledTimerWithTimeInterval(1, target: self, selector: "countdownToPhoto", userInfo: nil, repeats: false)
        } else {
            tellCameraToTakePhoto()
            takePhoto.hidden = false
            timerLabel.hidden = true
        }
    }
    
    func tellCameraToTakePhoto() {
        // SEND MESSAGE TO CAMERA TAKE PHOTO, ALONG WITH A BOOLEAN REPRESENTING
        // WHETHER THE CAMERA SHOULD ATTEMPT SENDING THE PHOTO BACK TO THE CONTROLLER
        cameraService.takePhoto(self.savePhoto!)
    }
    
    func enableButton() {
        takePhoto.enabled = true
        takePhoto.backgroundColor = UIColor.darkGrayColor()
        flashButton.hidden = false
    }
    
    func disableButton() {
        takePhoto.enabled = false
        takePhoto.backgroundColor = UIColor.lightGrayColor()
        flashButton.hidden = true
    }
    
    @IBAction func savePhotoButton(sender: AnyObject) {
        promptToSavePhotos()
    }
    
    @IBAction func timerButton(sender: AnyObject) {
        timerHelpLabel.hidden = !timerHelpLabel.hidden
        timerTextField.hidden = !timerTextField.hidden
        
        if (timerTextField.hidden) {
            timeDelay = 0
        }
    }
    
    
    @IBAction func flashButtonTapped(sender: AnyObject) {
        flashButton.selected = !flashButton.selected
        cameraService.toggleFlash()
    }
    
    override func prefersStatusBarHidden() -> Bool {
        return true
    }
    
    func hideFileTransferLabel() {
        self.fileTransferLabel.hidden = true
    }
    
    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
        if (context == &FileTransferProgressContext) {
            dispatch_async(dispatch_get_main_queue(), {
                let fractionCompleted : Float = Float(self.fileTransferProgress.fractionCompleted)
                self.progressView.setProgress(fractionCompleted, animated: true)
                if fractionCompleted == 1.0 {
                    // DO THIS WHEN FILE TRANSFER IS COMPLETE
                    self.fileTransferLabel.text = "Saving photo to camera roll..."
                }
            })
        } else {
            return super.observeValueForKeyPath(keyPath, ofObject: object, change: change, context: context)
        }
    }
    
    // HIDE NUMPAD WHEN IT LOSES FOCUS AND SAVE TIMER VALUE
    override func touchesBegan(touches: Set<UITouch>, withEvent event: UIEvent?) {
        if (!timerTextField.hidden) {
            self.view.endEditing(true)
            timeDelay = Int(timerTextField.text!)
        }
        super.touchesBegan(touches, withEvent: event)
    }
    
    //TO DO: Add orientation-independent UI (the following code forces portrait mode)
    override func shouldAutorotate() -> Bool {
        return false
    }
    
    override func supportedInterfaceOrientations() -> UIInterfaceOrientationMask {
        return UIInterfaceOrientationMask.Portrait
    }
    
}

extension CameraControllerViewController : CameraServiceManagerDelegate {
    func connectedDevicesChanged(manager: CameraServiceManager, state: MCSessionState, connectedDevices: [String]) {
        NSOperationQueue.mainQueue().addOperationWithBlock({
            switch (state) {
            case .Connected:
                self.enableButton()
            case .Connecting:
                break
            case .NotConnected:
                self.disableButton()
            }
        })
    }
    
    func shutterButtonTapped(manager: CameraServiceManager, _ sendPhoto: Bool) {
        // DO NOTHING (This is where the Camera receives the command to take a photo)
        // TO DO: Make some of these protocol functions optional
    }
    
    func toggleFlash(manager: CameraServiceManager) {
        // DO NOTHING (This is where the Camera receives the command to turn the flash on/off)
        // TO DO: Make some of these protocol functions optional
    }
    
    func didStartReceivingData(manager: CameraServiceManager, withName resourceName: String, withProgress progress: NSProgress) {
        NSOperationQueue.mainQueue().addOperationWithBlock({
            self.fileTransferLabel.text = "Receiving photo..."
            self.fileTransferLabel.hidden = false
            self.progressView.hidden = false
            self.fileTransferProgress = progress
            
            self.addObserver(self,
                forKeyPath: "fileTransferProgress.fractionCompleted",
                options: [.Old, .New],
                context: &FileTransferProgressContext)
        })
    }
    
    func didFinishReceivingData(manager: CameraServiceManager, url: NSURL) {
        NSOperationQueue.mainQueue().addOperationWithBlock({
            self.removeObserver(self,
                forKeyPath: "fileTransferProgress.fractionCompleted",
                context: &FileTransferProgressContext)
            
            let fileSaveClosure : ALAssetsLibraryWriteImageCompletionBlock = {_,_ in
                self.progressView.hidden = true
                self.progressView.progress = 0
                self.fileTransferLabel.text = "Photo saved to camera roll"
                NSTimer.scheduledTimerWithTimeInterval(2, target: self, selector: "hideFileTransferLabel", userInfo: nil, repeats: false)
            }
            
            if (self.savePhoto!) {
                // SAVE PHOTO TO PHOTOS APP
                let data = NSData(contentsOfFile: url.absoluteString)
                ALAssetsLibrary().writeImageDataToSavedPhotosAlbum(data, metadata: nil, completionBlock: fileSaveClosure)
            }
        })
    }
}