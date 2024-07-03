<div align="center">
    <img src="https://avatars.githubusercontent.com/u/26165732?s=200&v=4" width="100" height="100" alt="avatar" />
    <h1>PassKit</h1>
    <a href="https://swiftpackageindex.com/vapor-community/PassKit/0.5.0/documentation/passkit">
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

🎟️ 📦 A Vapor package for creating, distributing and updating passes and orders for Apple Wallet.

### Major Releases

The table below shows a list of PassKit major releases alongside their compatible Swift versions. 

|Version|Swift|SPM|
|---|---|---|
|0.5.0|5.10+|`from: "0.5.0"`|
|0.4.0|5.10+|`from: "0.4.0"`|
|0.2.0|5.9+|`from: "0.2.0"`|
|0.1.0|5.9+|`from: "0.1.0"`|

Use the SPM string to easily include the dependendency in your `Package.swift` file

```swift
.package(url: "https://github.com/vapor-community/PassKit.git", from: "0.5.0")
```

> Note: This package is made for Vapor 4.

## 🎟️ Wallet Passes

Add the `Passes` product to your target's dependencies:

```swift
.product(name: "Passes", package: "PassKit")
```

See the [documentation](https://swiftpackageindex.com/vapor-community/PassKit/0.5.0/documentation/passes) for guides on how to use the framework.

## 📦 Wallet Orders

Add the `Orders` product to your target's dependencies:

```swift
.product(name: "Orders", package: "PassKit")
```

See the [documentation](https://swiftpackageindex.com/vapor-community/PassKit/0.5.0/documentation/orders) for guides on how to use the framework.