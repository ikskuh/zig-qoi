# zig-qoi

A implementation of the [_Quite-OK-Image_](https://phoboslab.org/log/2021/11/qoi-fast-lossless-image-compression) format for Zig.

## API

```zig
pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };
pub const EncodeError = error{ OutOfMemory, ImageTooLarge, EndOfStream };

pub fn isQOI(bytes: []const u8) bool;
pub fn decodeBuffer(allocator: *std.mem.Allocator, buffer: []const u8) DecodeError!Image;
pub fn decodeStream(allocator: *std.mem.Allocator, reader: anytype) !Image;

pub fn encodeBuffer(allocator: *std.mem.Allocator, image: ConstImage) EncodeError![]u8;
```
