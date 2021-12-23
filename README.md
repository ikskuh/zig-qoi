# zig-qoi

A implementation of the [_Quite OK Image Format_](https://qoiformat.org/) for Zig. This implementation conforms to the [Qoi specification](https://qoiformat.org/qoi-specification.pdf).

![](design/logo.png)

## API

Add `src/qoi.zig` to your Zig project as a package.

```zig
pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };
pub const EncodeError = error{ OutOfMemory };

// Simple API:

pub fn isQOI(bytes: []const u8) bool;
pub fn decodeBuffer(allocator: std.mem.Allocator, buffer: []const u8) DecodeError!Image;
pub fn decodeStream(allocator: std.mem.Allocator, reader: anytype) !Image;

pub fn encodeBuffer(allocator: std.mem.Allocator, image: ConstImage) EncodeError![]u8;
pub fn encodeStream(image: ConstImage, writer: anytype) !void;

// Streaming API:
pub fn encoder(writer: anytype) Encoder(@TypeOf(writer));
pub fn Encoder(comptime Writer: type) type {
   return struct {
      writer: Writer,
      pub fn reset(self: *Self) void;
      pub fn flush(self: *Self) (EncodeError || Writer.Error)!void;
      pub fn write(self: *Self, pixel: Color) (EncodeError || Writer.Error)!void;
   };
}
```

## Implementation Status

Everything specified in https://github.com/phoboslab/qoi/issues/37 is implemented and accessible via the API.

## Performance

On my machine (AMD Ryzen 7 3700U), i did a small benchmark with decoding `bench.zig`, which will decode `zero.qoi`:

| Build Mode   | QOI Bytes   | Raw Bytes      | Encoding Time | Decoding Time |
| ------------ | ----------- | -------------- | ------------- | ------------- |
| Debug        | 75.024 byte | 1.048.576 byte | 14.439ms      | 7.061ms       |
| ReleaseSmall | 75.024 byte | 1.048.576 byte | 1.888ms       | 1.499ms       |
| ReleaseSafe  | 75.024 byte | 1.048.576 byte | 1.392ms       | 512.706us     |
| ReleaseFast  | 75.024 byte | 1.048.576 byte | 1.186ms       | 456.762us     |

This means that this implementation is roughly able to decode ~2.1 GB/s raw texture data and is considered "fast enough" for now. If you find some performance improvements, feel free to PR it!

Running perf on the benchmark compiled with ReleaseFast showed that the implementation is quite optimal for the CPU, utilizing it to 100% and executing up to 3 instructions per cycle on my machine.

```sh-console
[felix@denkplatte-v2 zig-qoi]$ perf stat ./zig-out/bin/qoi-bench
Benchmark [4067/4096] Encoding time for 1048576 => 75024 bytes: 1.019ms
Benchmark [4067/4096] Decoding time for 75024 => 1048576 bytes: 419.223us

 Performance counter stats for './zig-out/bin/qoi-bench':

          9.665,11 msec task-clock:u              #    0,997 CPUs utilized
                 0      context-switches:u        #    0,000 K/sec
                 0      cpu-migrations:u          #    0,000 K/sec
            21.066      page-faults:u             #    0,002 M/sec
    29.757.225.002      cycles:u                  #    3,079 GHz                      (83,33%)
       317.453.390      stalled-cycles-frontend:u #    1,07% frontend cycles idle     (83,33%)
       515.819.113      stalled-cycles-backend:u  #    1,73% backend cycles idle      (83,32%)
    83.377.885.642      instructions:u            #    2,80  insn per cycle
                                                  #    0,01  stalled cycles per insn  (83,36%)
    18.947.655.057      branches:u                # 1960,417 M/sec                    (83,31%)
       193.594.708      branch-misses:u           #    1,02% of all branches          (83,35%)

       9,693303129 seconds time elapsed

       9,553127000 seconds user
       0,112001000 seconds sys
```

Also, running the [benchmark dataset](https://qoiformat.org/benchmark/) of the original author, it yielded the [following data](data/benchmark.csv):

```
Number of total images:             1351
Average PNG Compression:              18.57%
Average QOI Compression:              22.70%
Average Compression Rate (MB/s):     438.31 MB/s
Minimal Compression Rate (MB/s):      27.06 MB/s
Maximum Compression Rate (MB/s):    1390.15 MB/s
Average Decompression Rate (MB/s):  1128.46 MB/s
Maximum Decompression Rate (MB/s):    39.77 MB/s
Maximum Deompression Rate (MB/s):  13307.20 MB/s
```

[See also the original analysis on Google Docs](https://docs.google.com/spreadsheets/d/1guTm4A2TxFzxeB6MRWbCmfidJu3S2iv-S3OM_sOo_4Q/edit?usp=sharing)

## Contribution

Run the test suite like this:

```sh-console
[user@host zig-qoi]$ zig build test
All 5 tests passed.
```

Run the benchmark like this:

```sh-console
[user@host zig-qoi]$ zig build benchmark
Benchmark [4096/4096] Encoding time for 1048576 => 67076 bytes: 16.649ms
Benchmark [4095/4096] Decoding time for 67076 => 1048576 bytes: 5.681ms
```

To run the benchmark for batch files, run this:

```sh-console
[user@host zig-qoi]$ zig build install && ./zig-out/bin/qoi-bench-files $(folder_a) $(folder_b) ...
File Name       Width   Height  Total Raw Bytes  Total PNG Bytes PNG Compression  Total QOI Bytes  QOI Compression  QOI to PNG          Decode Time (ns)  Encode Time (ns)
data/zero.png   512     512     1048576          80591           0.08             67076            0.06             0.8323013782501221  5628360           14499346
total sum       0       0       1048576          80591           0.08             67076            0.06             0.8323013782501221  5628360           14499346
```

Pass as many folders you like to the benchmarking tool. It will render a CSV file on the `stderr`.
