import CSCore
import SwiftUI

extension Preferences {
    func binding<Value: PrefValue>(_ key: PrefKey<Value>) -> Binding<Value> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }
}
