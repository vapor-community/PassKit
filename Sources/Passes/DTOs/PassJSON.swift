//
//  PassJSON.swift
//  PassKit
//
//  Created by Francesco Paolo Severino on 28/06/24.
//

/// A protocol that defines the structure of a `pass.json` file.
/// 
/// > Tip: See the [`Pass`](https://developer.apple.com/documentation/walletpasses/pass) object to understand the keys.
public protocol PassJSON: Encodable {
    /// The authentication token to use with the web service.
    static var token: String { get }

    /// A short description that iOS accessibility technologies use for a pass.
    var description: String { get }

    /// The version of the file format. The value must be 1.
    var formatVersion: Int { get }

    /// The name of the organization.
    var organizationName: String { get }

    /// The pass type identifier that’s registered with Apple.
    /// 
    /// The value must be the same as the distribution certificate used to sign the pass.
    var passTypeIdentifier: String { get }

    /// An alphanumeric serial number.
    /// 
    /// The combination of the serial number and pass type identifier must be unique for each pass.
    var serialNumber: String { get }

    /// The Team ID for the Apple Developer Program account that registered the pass type identifier.
    var teamIdentifier: String { get }
}

/// A protocol that represents the information to display in a field on a pass.
///
/// > Tip: See the [`PassFieldContent`](https://developer.apple.com/documentation/walletpasses/passfieldcontent) object to understand the keys.
public protocol PassFieldContent: Encodable {
    /// A unique key that identifies a field in the pass; for example, `departure-gate`.
    var key: String { get }

    /// The value to use for the field; for example, 42. 
    /// 
    /// A date or time value must include a time zone.
    var value: String { get }
}

/// A protocol that represents the groups of fields that display the information for a boarding pass.
/// 
/// > Tip: See the [`Pass.BoardingPass`](https://developer.apple.com/documentation/walletpasses/pass/boardingpass) object to understand the keys.
public protocol BoardingPass: Encodable {
    /// The type of transit for a boarding pass.
    /// 
    /// This key is invalid for other types of passes.
    /// 
    /// The system may use the value to display more information,
    /// such as showing an airplane icon for the pass on watchOS when the value is set to `PKTransitTypeAir`.
    var transitType: TransitType { get }
}

/// The type of transit for a boarding pass.
public enum TransitType: String, Encodable {
    case air = "PKTransitTypeAir"
    case boat = "PKTransitTypeBoat"
    case bus = "PKTransitTypeBus"
    case generic = "PKTransitTypeGeneric"
    case train = "PKTransitTypeTrain"
}

/// A protocol that represents a barcode on a pass.
/// 
/// > Tip: See the [`Pass.Barcodes`](https://developer.apple.com/documentation/walletpasses/pass/barcodes) object to understand the keys.
public protocol Barcodes: Encodable {
    /// The format of the barcode.
    /// 
    /// The barcode format `PKBarcodeFormatCode128` isn’t supported for watchOS.
    var format: BarcodeFormat { get }

    /// The message or payload to display as a barcode.
    var message: String { get }

    /// The IANA character set name of the text encoding to use to convert message
    /// from a string representation to a data representation that the system renders as a barcode, such as `iso-8859-1`.
    var messageEncoding: String { get }
}

/// The format of the barcode.
public enum BarcodeFormat: String, Encodable {
    case pdf417 = "PKBarcodeFormatPDF417"
    case qr = "PKBarcodeFormatQR"
    case aztec = "PKBarcodeFormatAztec"
    case code128 = "PKBarcodeFormatCode128"
}
