import Foundation

/// Runs synchronously on the socket actor: no other send or option mutation can
/// interleave between reading, temporarily changing and restoring blocking mode.
enum SRTNonblockingSend {
    struct RestorationFailure: Error {
        let acceptedAt: Double?
        let underlying: any Error
    }
    static func perform(get: () throws -> Bool, set: (Bool) throws -> Void,
                        send: () throws -> Bool,
                        now: () -> Double = { ProcessInfo.processInfo.systemUptime }) throws -> Bool {
        let original = try get()
        if original { try set(false) }
        let result: Result<Bool, Error>
        do { result = .success(try send()) } catch { result = .failure(error) }
        let acceptedAt = (try? result.get()) == true ? now() : nil
        if original {
            do { try set(true) }
            catch { throw RestorationFailure(acceptedAt: acceptedAt, underlying: error) }
        }
        return try result.get()
    }
}
