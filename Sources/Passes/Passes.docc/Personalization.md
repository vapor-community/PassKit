# Setting Up Pass Personalization (⚠️ WIP)

Create and sign a personalized pass for Apple Wallet, and send it to a device with a Vapor server.

## Overview

> Warning: This section is a work in progress. Testing is hard without access to the certificates required to develop this feature. If you have access to the entitlements, please help us implement this feature.

Pass Personalization lets you create passes, referred to as personalizable passes, that prompt the user to provide personal information during signup that is used to update the pass.

> Important: Making a pass personalizable, just like adding NFC to a pass, requires a special entitlement issued by Apple. Although accessing such entitlements is hard if you're not a big company, you can learn more in [Getting Started with Apple Wallet](https://developer.apple.com/wallet/get-started/).

Personalizable passes can be distributed like any other pass. For information on personalizable passes, see the [Wallet Developer Guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/PassPersonalization.html#//apple_ref/doc/uid/TP40012195-CH12-SW2) and [Return a Personalized Pass](https://developer.apple.com/documentation/walletpasses/return_a_personalized_pass).

### Implement the Data Model

You'll have to make a few changes to your ``PassDataModel`` to support personalizable passes.

A personalizable pass is just a standard pass package with the following additional files:

- A `personalization.json` file.
- A `personalizationLogo@XX.png` file.

Implement the ``PassDataModel/personalizationJSON(on:)`` method.
If the pass requires personalization, and if it was not already personalized, create the ``PersonalizationJSON`` struct, which will contain all the fields for the generated `personalization.json` file, and return it, otherwise return `nil`.

In the ``PassDataModel/template(on:)`` method, you have to return two different directory paths, depending on whether the pass has to be personalized or not. If it does, the directory must contain the `personalizationLogo@XX.png` file.

Finally, you have to implement the ``PassDataModel/passJSON(on:)`` method as usual, but remember to use in the ``PassJSON/Properties`` initializer the user info that will be saved inside ``Pass/userPersonalization`` after the pass has been personalized.

```swift
extension PassData {
    func passJSON(on db: any Database) async throws -> any PassJSON.Properties {
        // Here create the pass JSON data as usual.
        try await PassJSONData(data: self, pass: self.$pass.get(on: db))
    }

    func personalizationJSON(on db: any Database) async throws -> PersonalizationJSON? {
        if try await self.$pass.get(on: db).$userPersonalization.get(on: db) == nil {
            // If the pass requires personalization, create the personalization JSON struct.
            return PersonalizationJSON(
                requiredPersonalizationFields: [.name, .postalCode, .emailAddress, .phoneNumber],
                description: "Hello, World!"
            )
        } else {
            // Otherwise, return `nil`.
            return nil
        }
    }

    func template(on db: any Database) async throws -> String {
        if self.requiresPersonalization {
            // If the pass requires personalization, return the URL path to the personalization template,
            // which must contain the `personalizationLogo@XX.png` file.
            return "Templates/Passes/Personalization/"
        } else {
            // Otherwise, return the URL path to the standard pass template.
            return "Templates/Passes/Standard/"
        }
    }
}
```

### Implement the Web Service

After implementing the data model methods, there is nothing else you have to do.

Initializing the ``PassesService`` will automatically set up the endpoints that Apple Wallet expects to exist on your server to handle pass personalization.

Adding the ``PassesService/register(migrations:)`` method to your `configure.swift` file will automatically set up the database table that stores the user personalization data.

Generate the pass bundle with ``PassesService/build(pass:on:)`` as usual and distribute it.
The user will be prompted to provide the required personal information when they add the pass.
Wallet will then send the user personal information to your server, which will be saved in the ``UserPersonalization`` table.
Immediately after that, Wallet will request the updated pass.
This updated pass will contain the user personalization data that was previously saved inside the ``Pass/userPersonalization`` field.

> Important: This updated and personalized pass **must not** contain the `personalization.json` file, so make sure that the ``PassDataModel/personalizationJSON(on:)`` method returns `nil` when the pass has already been personalized.

## Topics

### Data Model Method

- ``PassDataModel/personalizationJSON(on:)``
