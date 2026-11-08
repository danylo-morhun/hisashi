import Accelerate

// Sound to four bar levels. Pure functions over arrays; the FFT setup is passed in.

enum Spectrum {
    static let frameSize = 1024
    /// Band edges in Hz: bass, low mids, high mids, treble.
    static let edges: [Float] = [40, 160, 640, 2500, 10000]

    static func makeFFT() -> vDSP.FFT<DSPSplitComplex>? {
        vDSP.FFT(log2n: vDSP_Length(log2(Float(frameSize))), radix: .radix2, ofType: DSPSplitComplex.self)
    }

    static let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)

    /// Energy per band in dB for one frame of mono samples.
    static func bandDecibels(_ samples: [Float], sampleRate: Float, fft: vDSP.FFT<DSPSplitComplex>) -> [Float] {
        let half = frameSize / 2
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: half)
        var imag = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(half))
                }
                fft.forward(input: split, output: &split)
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
            }
        }
        let binWidth = sampleRate / Float(frameSize)
        return (0..<edges.count - 1).map { b in
            let lo = max(1, Int(edges[b] / binWidth))
            let hi = max(lo + 1, min(half, Int(edges[b + 1] / binWidth)))
            let mean = power[lo..<hi].reduce(0, +) / Float(hi - lo)
            return 10 * log10(mean + 1e-12)
        }
    }

    /// Levels follow the music: each band is measured against its own slowly
    /// falling peak, rises fast and falls slow, like a real meter.
    static func step(levels: [Float], peaks: [Float], decibels: [Float]) -> (levels: [Float], peaks: [Float]) {
        let range: Float = 30
        var nextLevels = levels, nextPeaks = peaks
        for i in decibels.indices {
            nextPeaks[i] = max(decibels[i], peaks[i] - 0.25)
            let target = min(1, max(0, (decibels[i] - (nextPeaks[i] - range)) / range))
            let speed: Float = target > levels[i] ? 0.6 : 0.18
            nextLevels[i] = levels[i] + (target - levels[i]) * speed
        }
        return (nextLevels, nextPeaks)
    }
}
