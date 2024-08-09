# ``Orders``

Create, distribute, and update orders in Apple Wallet with Vapor.

## Overview

The Orders framework provides a set of tools to help you create, build, and distribute orders trackable in the Apple Wallet app using a Vapor server.
It also provides a way to update orders after they have been distributed, using APNs, and models to store order and device data.

For information on Apple Wallet orders, see the [Apple Developer Documentation](https://developer.apple.com/documentation/walletorders).

## Topics

### Essentials

- <doc:GettingStarted>
- ``OrderJSON``

### Building and Distribution

- ``OrdersDelegate``
- ``OrdersService``
- ``OrdersServiceCustom``

### Concrete Models

- ``Order``
- ``OrdersRegistration``
- ``OrdersDevice``
- ``OrdersErrorLog``

### Abstract Models

- ``OrderModel``
- ``OrdersRegistrationModel``
- ``OrderDataModel``

### Errors

- ``OrdersError``