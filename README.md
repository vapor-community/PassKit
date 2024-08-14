<div align="center">
    <img src="https://avatars.githubusercontent.com/u/26165732?s=200&v=4" width="100" height="100" alt="avatar" />
    <h1>PassKit</h1>
    <a href="https://swiftpackageindex.com/vapor-community/PassKit/documentation">
        <img src="https://design.vapor.codes/images/readthedocs.svg" alt="Documentation">
    </a>
    <a href="https://discord.gg/vapor"><img src="https://design.vapor.codes/images/discordchat.svg" alt="Team Chat"></a>
    <a href="LICENSE"><img src="https://design.vapor.codes/images/mitlicense.svg" alt="MIT License"></a>
    <a href="https://github.com/vapor-community/PassKit/actions/workflows/test.yml">
        <img src="https://img.shields.io/github/actions/workflow/status/vapor-community/PassKit/test.yml?event=push&style=plastic&logo=github&label=tests&logoColor=%23ccc" alt="Continuous Integration">
    </a>
    <a href="https://codecov.io/github/vapor-community/PassKit">
        <img src="https://img.shields.io/codecov/c/github/vapor-community/PassKit?style=plastic&logo=codecov&label=codecov">
    </a>
    <a href="https://swift.org">
        <img src="https://design.vapor.codes/images/swift510up.svg" alt="Swift 5.10+">
    </a>
</div>
<br>

🎟️ 📦 Create, distribute, and update passes and orders for the Apple Wallet app with Vapor.

Use the SPM string to easily include the dependendency in your `Package.swift` file.

```swift
.package(url: "https://github.com/vapor-community/PassKit.git", from: "0.6.0")
```

> Note: This package is made for Vapor 4.

## 🎟️ Wallet Passes

The Passes framework provides a set of tools to help you create, build, and distribute digital passes for the Apple Wallet app using a Vapor server.
It also provides a way to update passes after they have been distributed, using APNs, and models to store pass and device data.

Add the `Passes` product to your target's dependencies:

```swift
.product(name: "Passes", package: "PassKit")
```

See the framework's [documentation](https://swiftpackageindex.com/vapor-community/PassKit/documentation/passes) for information and guides on how to use it.

For information on Apple Wallet passes, see the [Apple Developer Documentation](https://developer.apple.com/documentation/walletpasses).

## 📦 Wallet Orders

The Orders framework provides a set of tools to help you create, build, and distribute orders that users can track and manage in Apple Wallet using a Vapor server.
It also provides a way to update orders after they have been distributed, using APNs, and models to store order and device data.

Add the `Orders` product to your target's dependencies:

```swift
.product(name: "Orders", package: "PassKit")
```

See the framework's [documentation](https://swiftpackageindex.com/vapor-community/PassKit/documentation/orders) for information and guides on how to use it.

For information on Apple Wallet orders, see the [Apple Developer Documentation](https://developer.apple.com/documentation/walletorders).
