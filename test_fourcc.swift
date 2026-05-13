import Foundation
let code: UInt32 = 560947818
let c1 = String(UnicodeScalar(UInt8((code >> 24) & 0xFF)))
let c2 = String(UnicodeScalar(UInt8((code >> 16) & 0xFF)))
let c3 = String(UnicodeScalar(UInt8((code >> 8) & 0xFF)))
let c4 = String(UnicodeScalar(UInt8(code & 0xFF)))
print("Code: \(c1)\(c2)\(c3)\(c4)")
