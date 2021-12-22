# zig-qoi

A implementation of the [_Quite OK Image Format_](https://qoiformat.org/) for Zig.

![](design/logo.png)

## API

Add `src/qoi.zig` to your Zig project as a package.

```zig
pub const DecodeError = error{ OutOfMemory, InvalidData, EndOfStream };
pub const EncodeError = error{ OutOfMemory };

pub fn isQOI(bytes: []const u8) bool;
pub fn decodeBuffer(allocator: *std.mem.Allocator, buffer: []const u8) DecodeError!Image;
pub fn decodeStream(allocator: *std.mem.Allocator, reader: anytype) !Image;

pub fn encodeBuffer(allocator: *std.mem.Allocator, image: ConstImage) EncodeError![]u8;
pub fn encodeStream(image: ConstImage, writer: anytype) !void;
```

## Implementation Status

Everything specified in https://github.com/phoboslab/qoi/issues/37 is implemented and accessible via the API.

## Performance

On my machine (AMD Ryzen 7 3700U), i did a small benchmark with decoding `bench.zig`, which will decode `zero.qoi`:

| Build Mode   | QOI Bytes   | Raw Bytes      | Encoding Time | Decoding Time |
| ------------ | ----------- | -------------- | ------------- | ------------- |
| Debug        | 67.076 byte | 1.048.576 byte | 14.543ms      | 5.97ms        |
| ReleaseSmall | 67.076 byte | 1.048.576 byte | 1.809ms       | 1.167ms       |
| ReleaseSafe  | 67.076 byte | 1.048.576 byte | 1.591ms       | 461.465us     |
| ReleaseFast  | 67.076 byte | 1.048.576 byte | 1.357ms       | 393.406us     |

This means that this implementation is roughly able to decode ~ 2.6 GB/s raw texture data and is considered "fast enough" for now. If you find some performance improvements, feel free to PR it!

Running perf on the benchmark compiled with ReleaseFast showed that the implementation is quite optimal for the CPU, utilizing it to 100% and executing up to 3 instructions per cycle on my machine.

```sh-console
[felix@denkplatte-v2 zig-qoi]$ perf stat ./zig-out/bin/qoi-bench
Benchmark [4078/4096] Encoding time for 1048576 => 67076 bytes: 1.308ms
Benchmark [4082/4096] Decoding time for 67076 => 1048576 bytes: 371.522us

 Performance counter stats for './zig-out/bin/qoi-bench':

          9.134,89 msec task-clock:u              #    1,000 CPUs utilized
                 0      context-switches:u        #    0,000 K/sec
                 0      cpu-migrations:u          #    0,000 K/sec
            21.091      page-faults:u             #    0,002 M/sec
    30.813.991.693      cycles:u                  #    3,373 GHz                      (83,33%)
       355.402.342      stalled-cycles-frontend:u #    1,15% frontend cycles idle     (83,32%)
     4.232.272.753      stalled-cycles-backend:u  #   13,73% backend cycles idle      (83,33%)
    92.922.452.336      instructions:u            #    3,02  insn per cycle
                                                  #    0,05  stalled cycles per insn  (83,34%)
    20.239.713.432      branches:u                # 2215,651 M/sec                    (83,35%)
       186.437.210      branch-misses:u           #    0,92% of all branches          (83,33%)

       9,138776575 seconds time elapsed

       9,030548000 seconds user
       0,105006000 seconds sys
```

Also, running the [benchmark dataset](https://phoboslab.org/files/qoibench/) of the original author, it yielded the [following data](data/benchmark.csv):

```
Number of total images:             185
Average PNG Compression:             30.44%
Average QOI Compression:             35.62%
Average Compression Rate (MB/s):    288.97
Minimal Compression Rate (MB/s):    116.21
Maximum Compression Rate (MB/s):    791.38
Average Decompression Rate (MB/s):  691.05
Maximum Decompression Rate (MB/s):  208.44
Maximum Deompression Rate (MB/s):  8421.62
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
