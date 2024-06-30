// This is a temporary fix until RoutesBuilder and EmptyPayload are not Sendable
package struct FakeSendable<T>: @unchecked Sendable {
    package let value: T

    package init(value: T) {
        self.value = value
    }
}
