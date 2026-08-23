import AVFoundation
import Foundation
import PairAndShootCore

/// A one-shot result that can be fulfilled from any thread, before or after someone awaits it.
final class AsyncBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []

    func fulfill(_ result: Result<Value, any Error>) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Value, any Error>] in
            guard self.result == nil else { return [] }
            self.result = result
            let waiters = self.waiters
            self.waiters = []
            return waiters
        }
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> Result<Value, any Error>? in
                if let result { return result }
                waiters.append(continuation)
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }
}

/// Bridges one `AVCapturePhotoOutput` capture to async/await.
final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let box = AsyncBox<CapturedPhoto>()
    private let lock = NSLock()
    private var data: Data?
    private let fileExtension: String

    init(fileExtension: String) {
        self.fileExtension = fileExtension
    }

    func photo() async throws -> CapturedPhoto {
        try await box.value()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: (any Error)?) {
        if let error {
            box.fulfill(.failure(CameraDeviceError.failed(error.localizedDescription)))
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            box.fulfill(.failure(CameraDeviceError.failed("The photo couldn't be encoded.")))
            return
        }
        lock.withLock { self.data = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: (any Error)?) {
        if let error {
            box.fulfill(.failure(CameraDeviceError.failed(error.localizedDescription)))
            return
        }
        guard let data = lock.withLock({ self.data }) else {
            box.fulfill(.failure(CameraDeviceError.failed("The photo never arrived.")))
            return
        }
        box.fulfill(.success(CapturedPhoto(data: data, fileExtension: fileExtension)))
    }
}

/// Bridges one `AVCaptureMovieFileOutput` recording to async/await.
final class MovieRecordingDelegate: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let started = AsyncBox<Bool>()
    private let finished = AsyncBox<URL>()

    func waitUntilStarted() async throws {
        _ = try await started.value()
    }

    func waitUntilFinished() async throws -> URL {
        try await finished.value()
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        started.fulfill(.success(true))
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: (any Error)?) {
        if let error {
            // AVFoundation reports interruptions as errors even when the file is complete and playable.
            let info = (error as NSError).userInfo
            let usable = (info[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
            if !usable {
                let failure = CameraDeviceError.failed(error.localizedDescription)
                started.fulfill(.failure(failure))
                finished.fulfill(.failure(failure))
                return
            }
        }
        started.fulfill(.success(true))
        finished.fulfill(.success(outputFileURL))
    }
}
