# ``Passes``

Create, distribute, and update passes for the Apple Wallet app with Vapor.

## Overview

@Row {
    @Column { }
    @Column(size: 4) {
        ![Passes](passes)
    }
    @Column { }
}

The Passes framework provides a set of tools to help you create, build, and distribute digital passes for the Apple Wallet app using a Vapor server. It also provides a way to update passes after they have been distributed, using APNs, and models to store pass and device data.

For information on Apple Wallet passes, see the [Apple Developer Documentation](https://developer.apple.com/documentation/walletpasses).

## Topics

### Essentials

- <doc:PassData>
- <doc:DistributeUpdate>
- ``PassJSON``

### Building and Distribution

- ``PassesDelegate``
- ``PassesService``
- ``PassesServiceCustom``

### Concrete Models

- ``PKPass``
- ``PassesRegistration``
- ``PassesDevice``
- ``PassesErrorLog``

### Abstract Models

- ``PassModel``
- ``PassesRegistrationModel``
- ``PassDataModel``

### Errors

- ``PassesError``

### Personalized Passes (⚠️ WIP)

- <doc:Personalization>
- ``PersonalizationJSON``
