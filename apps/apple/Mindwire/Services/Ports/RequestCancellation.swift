import Foundation

extension Error {
    /// A child request can be cancelled without cancelling its caller's task.
    var isRequestCancellation: Bool {
        if self is CancellationError { return true }
        let error = self as NSError
        return error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
    }
}
