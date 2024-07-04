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

### Featured

@Links(visualStyle: detailedGrid) {
    - <doc:PassData>
    - <doc:DistributeUpdate>
}


## Topics

### Essentials

- <doc:PassData>
- <doc:DistributeUpdate>
- ``PassJSON``

### Concrete Models

- ``PKPass``
- ``PassesRegistration``
- ``PassesDevice``
- ``PassesErrorLog``
