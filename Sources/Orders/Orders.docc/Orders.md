# ``Orders``

Create, distribute, and update orders in Apple Wallet with Vapor.

## Overview

The Orders framework provides a set of tools to help you create, build, and distribute orders that users can track and manage in Apple Wallet using a Vapor server.
It also provides a way to update orders after they have been distributed, using APNs, and models to store order and device data.

For information on Apple Wallet orders, see the [Apple Developer Documentation](https://developer.apple.com/documentation/walletorders).

### Featured

@Links(visualStyle: detailedGrid) {
    - <doc:OrderData>
    - <doc:DistributeUpdate>
}


## Topics

### Essentials

- <doc:OrderData>
- <doc:DistributeUpdate>
- ``OrderJSON``

### Concrete Models

- ``Order``
- ``OrdersRegistration``
- ``OrdersDevice``
- ``OrdersErrorLog``
