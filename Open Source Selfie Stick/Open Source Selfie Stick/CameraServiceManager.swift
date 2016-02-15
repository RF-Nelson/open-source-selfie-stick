//
//  CameraServiceManager.swift
//  Open Source Selfie Stick
//
//  Created by Richard Nelson on 2/11/16.
//  Copyright © 2016 Richard Nelson. All rights reserved.
//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/.

import Foundation
import MultipeerConnectivity
import AssetsLibrary

class CameraServiceManager : NSObject {
    
    private let ServiceType = "camera-service"
    
    private let myPeerId = MCPeerID(displayName: UIDevice.currentDevice().name)
    let serviceAdvertiser : MCNearbyServiceAdvertiser
    
    let serviceBrowser : MCNearbyServiceBrowser
    
    var delegate : CameraServiceManagerDelegate?
    
    override init() {
        self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerId, discoveryInfo: nil, serviceType: ServiceType)
        self.serviceBrowser = MCNearbyServiceBrowser(peer: myPeerId, serviceType: ServiceType)
        
        super.init()
        
        self.serviceAdvertiser.delegate = self
        //        self.serviceAdvertiser.startAdvertisingPeer()
        self.serviceBrowser.delegate = self
        //        self.serviceBrowser.startBrowsingForPeers()
    }
    
    deinit {
        self.serviceAdvertiser.stopAdvertisingPeer()
    }
    
    lazy var session : MCSession = {
        let session = MCSession(peer: self.myPeerId, securityIdentity: nil, encryptionPreference: MCEncryptionPreference.Required)
        session.delegate = self
        return session
    }()
    
    func startSearching() {
        self.serviceAdvertiser.startAdvertisingPeer()
        self.serviceBrowser.startBrowsingForPeers()
    }
    
    func stopSearching() {
        self.serviceAdvertiser.stopAdvertisingPeer()
        self.serviceBrowser.stopBrowsingForPeers()
    }
    
    func takePhoto(sendPhoto: Bool) {
        do {
            var boolString = ""
            if (sendPhoto) {
                boolString = "true"
            } else {
                boolString = "false"
            }
            // ATTEMPT TO SEND DATA TO CAMERA
            try self.session.sendData((boolString.dataUsingEncoding(NSUTF8StringEncoding))!, toPeers: self.session.connectedPeers, withMode: MCSessionSendDataMode.Reliable)
        }
        catch {
            print("SOMETHING WENT WRONG IN CameraServiceManager.takePhoto()")
        }
    }
    
    func toggleFlash() {
        do {
            let dataString = "toggleFlash"
            // ATTEMPT TO SEND DATA TO CAMERA
            try self.session.sendData((dataString.dataUsingEncoding(NSUTF8StringEncoding))!, toPeers: self.session.connectedPeers, withMode: MCSessionSendDataMode.Reliable)
        }
        catch {
            print("SOMETHING WENT WRONG IN CameraServiceManager.toggleFlash()")
        }
    }
    
    func transferFile(file: NSURL) {
        if session.connectedPeers.count > 0 {
            for id in session.connectedPeers {
//                print("TRYING TO SEND OVER THIS FILE: " + file.absoluteString)
                self.session.sendResourceAtURL(file, withName: "photo.jpg", toPeer: id, withCompletionHandler: nil)
            }
        }
    }
}

extension CameraServiceManager : MCNearbyServiceAdvertiserDelegate {
    
    func advertiser(advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: NSError) {
        NSLog("%@", "didNotStartAdvertisingPeer: \(error)")
    }
    
    func advertiser(advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: NSData?, invitationHandler: (Bool, MCSession) -> Void) {
        NSLog("%@", "didReceiveInvitationFromPeer \(peerID)")
        invitationHandler(true, self.session)
    }
}

extension CameraServiceManager : MCNearbyServiceBrowserDelegate {
    func browser(browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: NSError) {
        NSLog("%@", "didNotStartBrowsingForPeers: \(error)")
    }
    
    func browser(browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        NSLog("%@", "foundPeer: \(peerID)")
        
        NSLog("%@", "invitePeer: \(peerID)")
        browser.invitePeer(peerID, toSession: self.session, withContext: nil, timeout: 10)
    }
    
    func browser(browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        NSLog("%@", "lostPeer: \(peerID)")
    }
}

extension MCSessionState {
    func stringValue() -> String {
        switch(self) {
        case .NotConnected: return "NotConnected"
        case .Connecting: return "Connecting"
        case .Connected: return "Connected"
        }
    }
}

extension CameraServiceManager : MCSessionDelegate {
    
    func session(session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, atURL localURL: NSURL, withError error: NSError?) {
        let documentsPath = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0]
        let photoDestinationURL = NSURL.fileURLWithPath(documentsPath + "/photo.jpg")
//        let videoDestinationURL = NSURL.fileURLWithPath(documentsPath + "/movie.mov")
        
        do {
            let fileHandle : NSFileHandle = try NSFileHandle(forReadingFromURL: localURL)
            let data : NSData = fileHandle.readDataToEndOfFile()
            let image = UIImage(data: data)
            UIImageWriteToSavedPhotosAlbum(image!, nil, nil, nil)
            self.delegate?.didFinishReceivingData(self, url: photoDestinationURL)
        }
        catch {
            print("PROBLEM IN CameraServiceManager extension > didFinishReceivingResourceWithName")
        }
    }
    
    func session(session: MCSession, didReceiveData data: NSData, fromPeer peerID: MCPeerID) {
        NSLog("%@", "didReceiveData: \(data)")
        let dataString = NSString(data: data, encoding: NSUTF8StringEncoding)
        
        // CHECK DATA STRING AND ACT ACCORDINGLY
        if (dataString == "toggleFlash") {
            self.delegate?.toggleFlash(self)
        } else {
            // CREATE VARIABLE REPRESENTING WHETHER OR NOT TO SEND PHOTO BACK TO CONTROLLER
            if (dataString == "true" || dataString  == "false") {
                let sendPhoto : Bool?
                if (dataString == "true") {
                    sendPhoto = true
                } else {
                    sendPhoto = false
                }
                
                self.delegate?.shutterButtonTapped(self, sendPhoto!)
            }
        }
    }
    
    func session(session: MCSession, didReceiveStream stream: NSInputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
    }
    
    func session(session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, withProgress progress: NSProgress) {
        self.delegate?.didStartReceivingData(self, withName: resourceName,  withProgress: progress)
    }
    
    func session(session: MCSession, peer peerID: MCPeerID, didChangeState state: MCSessionState) {
        NSLog("%@", "peer \(peerID) didChangeState: \(state.stringValue())")
        self.delegate!.connectedDevicesChanged(self, state: state, connectedDevices:
            session.connectedPeers.map({$0.displayName}))
    }
}

// TO DO: MAKE THIS AN @objc PROTOCOL AND MAKE SOME OF THESE FUNCTIONS OPTIONAL
protocol CameraServiceManagerDelegate {
    func connectedDevicesChanged(manager: CameraServiceManager, state: MCSessionState, connectedDevices: [String])
    func shutterButtonTapped(manager: CameraServiceManager, _ sendPhoto: Bool)
    func toggleFlash(manager: CameraServiceManager)
    func didStartReceivingData(manager: CameraServiceManager, withName resourceName: String, withProgress progress: NSProgress)
    func didFinishReceivingData(manager: CameraServiceManager, url: NSURL)
}