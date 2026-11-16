import SwiftUI

struct NewHostFocusedKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var newHostAction: (() -> Void)? {
        get { self[NewHostFocusedKey.self] }
        set { self[NewHostFocusedKey.self] = newValue }
    }
}
