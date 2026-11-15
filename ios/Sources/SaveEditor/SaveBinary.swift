import Foundation

// Little-endian u16 / u32 get / set helpers for save blocks ([UInt8]) and Data.
// Free functions are prefixed `save` so they never collide with other files' private `u16` / `u32` members.

@inline(__always) func saveU16(_ b: [UInt8], _ off: Int) -> Int {
  Int(b[off]) | (Int(b[off + 1]) << 8)
}

@inline(__always) func saveU32(_ b: [UInt8], _ off: Int) -> Int {
  Int(b[off]) | (Int(b[off + 1]) << 8) | (Int(b[off + 2]) << 16) | (Int(b[off + 3]) << 24)
}

@inline(__always) func savePutU16(_ b: inout [UInt8], _ off: Int, _ v: Int) {
  b[off] = UInt8(truncatingIfNeeded: v)
  b[off + 1] = UInt8(truncatingIfNeeded: v >> 8)
}

@inline(__always) func savePutU32(_ b: inout [UInt8], _ off: Int, _ v: Int) {
  savePutU16(&b, off, v & 0xFFFF)
  savePutU16(&b, off + 2, (v >> 16) & 0xFFFF)
}

extension Data {
  func u16(at off: Int) -> Int {
    Int(self[startIndex + off]) | (Int(self[startIndex + off + 1]) << 8)
  }

  func u32(at off: Int) -> Int {
    u16(at: off) | (u16(at: off + 2) << 16)
  }

  mutating func setU16(at off: Int, _ v: Int) {
    self[startIndex + off] = UInt8(truncatingIfNeeded: v)
    self[startIndex + off + 1] = UInt8(truncatingIfNeeded: v >> 8)
  }

  mutating func setU32(at off: Int, _ v: Int) {
    setU16(at: off, v & 0xFFFF)
    setU16(at: off + 2, (v >> 16) & 0xFFFF)
  }
}
