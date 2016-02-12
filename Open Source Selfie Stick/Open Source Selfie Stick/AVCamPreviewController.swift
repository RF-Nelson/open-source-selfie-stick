//
//  AVCamPreviewController.swift
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
import AVFoundation


class AVCamPreviewView: UIView{
    var session: AVCaptureSession? {
        get{
            return (self.layer as! AVCaptureVideoPreviewLayer).session;
        }
        set(session){
            (self.layer as! AVCaptureVideoPreviewLayer).session = session;
        }
    };
    
    override class func layerClass() ->AnyClass{
        return AVCaptureVideoPreviewLayer.self;
    }
}