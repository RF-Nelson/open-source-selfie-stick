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

class CameraControllerViewController : UIViewController {
    
    var cameraService = CameraServiceManager()
    let deviceName = UIDevice.currentDevice().name
    var localURL : NSURL?
    var savePhoto : Bool?
    var timeDelay : Int?
    
    @IBOutlet weak var takePhoto: UIButton!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        self.cameraService.delegate = self
        
        disableButton()
        
        savePhoto = true
        
        timeDelay = 0
    }
    
    override func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        self.cameraService.serviceBrowser.startBrowsingForPeers()
    }
    
    override func viewDidAppear(animated: Bool) {
        super.viewWillAppear(animated)
        
        if (self.cameraService.session.connectedPeers.count > 0) {
            enableButton()
        }
        
        let saveAlert = UIAlertController(title: "Save photos", message: "Do you want to save photos from this session to this device?", preferredStyle: UIAlertControllerStyle.Alert)
        
        saveAlert.addAction(UIAlertAction(title: "Yes", style: .Default, handler: { (action: UIAlertAction!) in
            self.savePhoto = true
        }))
        
        saveAlert.addAction(UIAlertAction(title: "No", style: .Default, handler: { (action: UIAlertAction!) in
            self.savePhoto = false
        }))
        
        presentViewController(saveAlert, animated: true, completion: nil)
    }
    
    @IBAction func takePhotoTapped(sender: AnyObject) {
        cameraService.startRecording(NSDate().timeIntervalSince1970 + Double(timeDelay!))
    }
    
    func enableButton() {
        takePhoto.enabled = true
    }
    
    func disableButton() {
        takePhoto.enabled = false
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
            default:
                print("something went wrong")
            }
        })
    }
    
    func shutterButtonTapped(manager: CameraServiceManager, timeToRecordString: String) {
    }
    
    func didStartReceivingData(manager: CameraServiceManager, withName resourceName: String, withProgress progress: NSProgress) {
        NSOperationQueue.mainQueue().addOperationWithBlock({
        })
    }
    
    func didFinishReceivingData(manager: CameraServiceManager, url: NSURL) {
        NSOperationQueue.mainQueue().addOperationWithBlock({
            self.localURL = url
            if (self.savePhoto!) {
                let data = NSData(contentsOfFile: url.absoluteString)
                ALAssetsLibrary().writeImageDataToSavedPhotosAlbum(data, metadata: nil, completionBlock: nil)
            }
        })
    }
}