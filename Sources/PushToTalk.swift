import CoreGraphics

struct PushToTalk {
    enum Action: Equatable { case none, start, finish, cancel }

    private var held = false
    private var talking = false
    private var keysDown: Set<Int64> = []
    private static let rightCommand: Int64 = 54
    // 裝置旗標分得出左右 Command；maskCommand 只表示至少有一邊按著。
    private static let rightCommandMask: UInt64 = 0x10
    private static let leftCommandMask: UInt64 = 0x08
    private static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskSecondaryFn]

    mutating func modifiers(key: Int64, flags: CGEventFlags) -> Action {
        if key == Self.rightCommand {
            if flags.rawValue & Self.rightCommandMask == 0 {
                held = false
                guard talking else { return .none }
                talking = false
                return .finish
            }
            guard !held else { return .none }
            held = true
            guard keysDown.isEmpty, flags.rawValue & Self.leftCommandMask == 0,
                  flags.intersection(Self.otherModifiers).isEmpty else { return .none }
            talking = true
            return .start
        }
        return cancel()
    }

    mutating func keyDown(_ key: Int64) -> Action {
        keysDown.insert(key)
        return cancel()
    }

    mutating func keyUp(_ key: Int64) {
        keysDown.remove(key)
    }

    mutating func cancel() -> Action {
        guard talking else { return .none }
        talking = false
        return .cancel
    }

    mutating func reset() -> Action {
        held = false
        keysDown.removeAll(keepingCapacity: true)
        return cancel()
    }
}
