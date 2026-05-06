import SwiftUI

private struct FontSizeOffsetKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var fontSizeOffset: Int {
        get { self[FontSizeOffsetKey.self] }
        set { self[FontSizeOffsetKey.self] = newValue }
    }
}
