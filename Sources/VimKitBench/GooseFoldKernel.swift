#if os(macOS)
@_spi(Benchmarks) import VimCore
import VimGooseKernels

/// The Goose fold kernel (Kernels/fold_blocks.goose), plugged into
/// `VimFoldBlockScanner` in place of the Swift one.
enum GooseFoldKernel {
    /// The Goose runtime is set up once, on the first call.
    private static let started: Void = goose_init(0, nil)

    static let kernel: VimFoldBlockScanner.Kernel = { text, tab, lastOf, stackLine, stackIndent in
        _ = started
        func slice(_ buffer: UnsafeMutableBufferPointer<Int32>) -> sl_i32 {
            sl_i32(data: buffer.baseAddress, len: Int64(buffer.count))
        }
        let input = sl_u16(data: UnsafeMutablePointer(mutating: text.baseAddress), len: Int64(text.count))
        return Int(vimkit_fold_blocks(input, tab, slice(lastOf), slice(stackLine), slice(stackIndent)))
    }
}
#endif
