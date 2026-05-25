import Foundation

public enum RecallError: Error {
    case notInstalled
    case timeout
    case searchFailed(String)
}
