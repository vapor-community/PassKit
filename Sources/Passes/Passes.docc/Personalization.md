# Setting Up Pass Personalization (⚠️ WIP)

Create and sign a personalized pass for Apple Wallet, and send it to a device with a Vapor server.

## Overview

> Warning: This section is a work in progress. Testing is hard without access to the certificates required to develop this feature. If you have access to the entitlements, please help us implement this feature.

Pass Personalization lets you create passes, referred to as personalizable passes, that prompt the user to provide personal information during signup that is used to update the pass.

> Important: Making a pass personalizable, just like adding NFC to a pass, requires a special entitlement issued by Apple. Although accessing such entitlements is hard if you're not a big company, you can learn more in [Getting Started with Apple Wallet](https://developer.apple.com/wallet/get-started/).

Personalizable passes can be distributed like any other pass. For information on personalizable passes, see the [Wallet Developer Guide](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/PassKit_PG/PassPersonalization.html#//apple_ref/doc/uid/TP40012195-CH12-SW2) and [Return a Personalized Pass](https://developer.apple.com/documentation/walletpasses/return_a_personalized_pass).

### Implement the Delegate

You'll have to make a few changes to ``PassesDelegate`` to support personalizable passes.

A personalizable pass is just a standard pass package with the following additional files:

- A `personalization.json` file.
- A `personalizationLogo@XX.png` file.

Implement the ``PassesDelegate/personalizationJSON(for:db:)`` method, which gives you the ``Pass`` to encode.
If the pass requires personalization, and if it was not already personalized, create the ``PersonalizationJSON`` struct, which will contain all the fields for the generated `personalization.json` file, and return it, otherwise return `nil`.

In the ``PassesDelegate/template(for:db:)`` method, you have to return two different directory paths, depending on whether the pass has to be personalized or not. If it does, the directory must contain the `personalizationLogo@XX.png` file.

Finally, you have to implement the ``PassesDelegate/encode(pass:db:encoder:)`` method as usual, but remember to use in the ``PassJSON`` initializer the user info that will be saved inside ``Pass/userPersonalization`` after the pass has been personalized.

```swift
import Vapor
import Fluent
import Passes

final class PassDelegate: PassesDelegate {
    func encode<P: PassModel>(pass: P, db: Database, encoder: JSONEncoder) async throws -> Data {
        // Here encode the pass JSON data as usual.
        guard let passData = try await PassData.query(on: db)
            .filter(\.$pass.$id == pass.requireID())
            .first()
        else {
            throw Abort(.internalServerError)
        }
        guard let data = try? encoder.encode(PassJSONData(data: passData, pass: pass)) else {
            throw Abort(.internalServerError)
        }
        return data
    }

    func personalizationJSON<P: PassModel>(for pass: P, db: any Database) async throws -> PersonalizationJSON? {
        guard let passData = try await PassData.query(on: db)
            .filter(\.$pass.$id == pass.requireID())
            .with(\.$pass)
            .first()
        else {
            throw Abort(.internalServerError)
        }

        if try await passData.pass.$userPersonalization.get(on: db) == nil {
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

    func template<P: PassModel>(for pass: P, db: Database) async throws -> String {
        guard let passData = try await PassData.query(on: db)
            .filter(\.$pass.$id == pass.requireID())
            .first()
        else {
            throw Abort(.internalServerError)
        }

        if passData.requiresPersonalization {
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

After implementing the delegate methods, there is nothing else you have to do.

Initializing the ``PassesService`` will automatically set up the endpoints that Apple Wallet expects to exist on your server to handle pass personalization.

Adding the ``PassesService/register(migrations:)`` method to your `configure.swift` file will automatically set up the database table that stores the user personalization data.

Generate the pass bundle with ``PassesService/generatePassContent(for:on:)`` as usual and distribute it.
The user will be prompted to provide the required personal information when they add the pass.
Wallet will then send the user personal information to your server, which will be saved in the ``UserPersonalization`` table.
Immediately after that, Wallet will request the updated pass.
This updated pass will contain the user personalization data that was previously saved inside the ``Pass/userPersonalization`` field.

> Important: This updated and personalized pass **must not** contain the `personalization.json` file, so make sure that the ``PassesDelegate/personalizationJSON(for:db:)`` method returns `nil` when the pass has already been personalized.

## Topics

### Delegate Method

- ``PassesDelegate/personalizationJSON(for:db:)``
