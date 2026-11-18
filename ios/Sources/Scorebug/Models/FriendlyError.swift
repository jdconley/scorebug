import Foundation
import ScorebugCore

/// Plain-language messages for server and connection errors. No codes, no jargon.
enum FriendlyError {
    static func message(_ error: Error) -> String {
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
                return "This phone is offline. Check Wi-Fi or cellular and try again."
            case .timedOut: return "Scorebug took too long to answer. Try again."
            case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost:
                return "Can't reach Scorebug. Check your connection."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
                return "Scorebug's secure connection didn't check out."
            default: return "Can't reach Scorebug. Try again."
            }
        }
        if let error = error as? MatchClientError {
            switch error {
            case .unauthorized: return "Scorebug didn't accept this phone. Sign in again."
            case .forbidden: return "You aren't allowed to do that."
            case .http(let status, let code): return message(code: code, status: status)
            case .invalidResponse, .invalidIdentifier: return "Scorebug sent something unexpected. Try again."
            }
        }
        if let error = error as? MatchCoordinatorError {
            switch error {
            case .scoringNotAllowed: return "Another device is scoring this match."
            case .storageFailure: return "Couldn't save on this phone. Free up space or unlock the phone, then try again."
            case .busy, .pendingCommand: return "Still sending the last change."
            default: return "The score didn't update. Try again."
            }
        }
        if error is ScoringEndpoint.ValidationError {
            return "Enter a server address, like http://localhost:8787."
        }
        if error is SecureStoreError { return "Couldn't save on this phone. Unlock it and try again." }
        return "Something went wrong. Try again."
    }

    static func message(code: String?, status: Int) -> String {
        switch code {
        case "invite_invalid": return "That invite code didn't work. Check it and try again."
        case "invite_expired": return "That invite has expired. Ask for a new code."
        case "invite_revoked": return "That invite was turned off. Ask for a new code."
        case "match_ended": return "That match has ended."
        case "rate_limited": return "Too many tries. Wait a minute and try again."
        case "device_id_taken": return "This phone is already part of that match."
        case "match_in_flight": return "Your team already has a match open."
        case "team_not_found": return "You're not on that team anymore."
        case "record_only_match": return "This match is record only."
        case "tied_set": return "A set can't end tied."
        case "set_not_won": return "Nobody has won this set yet."
        case "match_already_won": return "The match is already decided."
        case "revision_conflict", "scorer_changed": return "The score changed on another device. Check it and try again."
        case "command_expired": return "That change took too long to send. Check the score and try again."
        case "nothing_to_undo": return "Nothing to undo."
        default:
            if status == 404 { return "Scorebug doesn't know that match." }
            if status >= 500 { return "Scorebug had a problem. Try again in a moment." }
            return "Scorebug said no. Try again."
        }
    }
}
