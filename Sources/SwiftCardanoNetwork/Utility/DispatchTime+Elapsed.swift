import Foundation

extension DispatchTime {
    /// Nanoseconds elapsed since `start`.
    ///
    /// Uses `uptimeNanoseconds` directly so it works on Linux, where `DispatchTime`
    /// does not conform to `Strideable` and `.distance(to:)` is unavailable.
    static func nanosecondsSince(_ start: DispatchTime) -> Int64 {
        Int64(bitPattern: DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds)
    }
}
