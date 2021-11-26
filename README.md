# zig-qoi

A implementation of the [_Quite-OK-Image_](https://phoboslab.org/log/2021/11/qoi-fast-lossless-image-compression) format for Zig.

## API

Add `qoi.zig` to your Zig project as a package.

```zig
pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };
pub const EncodeError = error{ OutOfMemory, ImageTooLarge, EndOfStream };

pub fn isQOI(bytes: []const u8) bool;
pub fn decodeBuffer(allocator: *std.mem.Allocator, buffer: []const u8) DecodeError!Image;
pub fn decodeStream(allocator: *std.mem.Allocator, reader: anytype) !Image;

pub fn encodeBuffer(allocator: *std.mem.Allocator, image: ConstImage) EncodeError![]u8;
```

## Performance

This implementation uses a buffered reader in `decodeStream` which does not read after the QOI file end. This buffered reader allows high performance even when passing an unbuffered file reader directly.

On my machine (AMD Ryzen 7 3700U), i did a small benchmark with decoding `bench.zig`, which will decode `zero.qoi`:

| Build Mode   | QOI Bytes   | Raw Bytes      | Encoding Time | Decoding Time |
| ------------ | ----------- | -------------- | ------------- | ------------- |
| Debug        | 67.009 byte | 1.048.576 byte | 15.419ms      | 9.943ms       |
| ReleaseSafe  | 67.009 byte | 1.048.576 byte | 1.388ms       | 1.447ms       |
| ReleaseFast  | 67.009 byte | 1.048.576 byte | 1.282ms       | 1.036ms       |
| ReleaseSmall | 67.009 byte | 1.048.576 byte | 1.741ms       | 2.035ms       |

This means that this implementation is roughly able to decode ~ 700 MB/s raw texture data and is considered "fast enough" for now. If you find some performance improvements, feel free to PR it!

## Contribution

Run the test suite like this:

```sh-console
[felix@denkplatte-v2 zig-qoi]$ zig test qoi.zig
All 4 tests passed.
```

Run the benchmark like this:

```sh-console
[felix@denkplatte-v2 zig-qoi]$ zig run -lc -O ReleaseSmall bench.zig
Benchmark [4072/4096] Decoding time for 67009 => 1048576 bytes: 1.741ms
```

Note that the benchmark has two source-config options `total_rounds` and `test_encoder` (which will decode if the encoder or decoder is benchmarked).
