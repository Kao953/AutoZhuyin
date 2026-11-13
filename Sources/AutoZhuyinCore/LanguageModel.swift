import Accelerate
import Foundation

/// Scores Chinese text: natural-log probability of `text` following `context`.
public protocol LanguageModel: AnyObject {
    func logProb(_ text: String, context: String) -> Double
}

/// GPT-2 forward pass (CPU, Accelerate) for the character-level CKIP gpt2-tiny-chinese
/// model (GPL-3.0), stored by training/lm/export_lm.py as float16 ("AZLM" format).
/// Weights are expanded to float32 in memory (~46 MB for gpt2-tiny).
public final class GPT2LanguageModel: LanguageModel {
    public enum LoadError: Error { case badFormat(String) }

    let nLayer: Int, nHead: Int, d: Int, vocabSize: Int
    let eps: Float
    private var weights: [Float] = []
    private var offsets: [String: Int] = [:]
    private var vocab: [Character: Int32] = [:]
    static let cls: Int32 = 101, unk: Int32 = 100
    /// Longest input scored (context + text); longer contexts are cut from the left.
    public var maxTokens = 64

    public init(modelURL: URL, vocabURL: URL) throws {
        let data = try Data(contentsOf: modelURL, options: .mappedIfSafe)
        guard data.count > 8, data.prefix(4) == Data("AZLM".utf8) else { throw LoadError.badFormat("magic") }
        let headerLength = Int(data[4]) | Int(data[5]) << 8 | Int(data[6]) << 16 | Int(data[7]) << 24
        guard let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + headerLength))) as? [String: Any],
              let nLayer = header["n_layer"] as? Int, let nHead = header["n_head"] as? Int,
              let d = header["n_embd"] as? Int, let vocabSize = header["vocab"] as? Int,
              let eps = header["eps"] as? Double, let tensors = header["tensors"] as? [[Any]]
        else { throw LoadError.badFormat("header") }
        self.nLayer = nLayer; self.nHead = nHead; self.d = d; self.vocabSize = vocabSize; self.eps = Float(eps)
        for t in tensors {
            guard let name = t[0] as? String, let offset = t[2] as? Int else { throw LoadError.badFormat("tensor") }
            offsets[name] = offset
        }
        let start = 8 + headerLength
        let count = (data.count - start) / 2
        weights = [Float](repeating: 0, count: count)
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.advanced(by: start) else { throw LoadError.badFormat("data") }
            try weights.withUnsafeMutableBufferPointer { out in
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base), height: 1,
                                        width: vImagePixelCount(count), rowBytes: count * 2)
                var dst = vImage_Buffer(data: out.baseAddress, height: 1,
                                        width: vImagePixelCount(count), rowBytes: count * 4)
                guard vImageConvert_Planar16FtoPlanarF(&src, &dst, 0) == kvImageNoError else {
                    throw LoadError.badFormat("float16")
                }
            }
        }
        var index: Int32 = 0
        for line in try String(contentsOf: vocabURL, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.count == 1, let c = line.first, vocab[c] == nil { vocab[c] = index }
            index += 1
        }
        for name in ["wte.weight", "wpe.weight", "ln_f.weight"] where offsets[name] == nil {
            throw LoadError.badFormat("missing \(name)")
        }
    }

    func tokens(_ text: String) -> [Int32] { text.map { vocab[$0] ?? GPT2LanguageModel.unk } }

    public func logProb(_ text: String, context: String) -> Double {
        let target = tokens(text)
        guard !target.isEmpty else { return 0 }
        var ctx = tokens(context)
        if ctx.count + target.count + 1 > maxTokens { ctx = Array(ctx.suffix(max(0, maxTokens - target.count - 1))) }
        let input = [GPT2LanguageModel.cls] + ctx + target.dropLast()
        let h = hidden(input)                     // [T, d]
        return weights.withUnsafeBufferPointer { w in
            logSoftmaxScore(h, rows: input.count, from: ctx.count, targets: target, w: w)
        }
    }

    // MARK: - Forward pass

    private func w(_ name: String) -> Int { offsets[name]! }

    /// Final hidden states [T, d] (row-major).
    func hidden(_ ids: [Int32]) -> [Float] {
        let T = ids.count, d = self.d
        var x = [Float](repeating: 0, count: T * d)
        weights.withUnsafeBufferPointer { W in
            let wte = w("wte.weight"), wpe = w("wpe.weight")
            for t in 0..<T {
                vDSP_vadd(W.baseAddress! + wte + Int(ids[t]) * d, 1, W.baseAddress! + wpe + t * d, 1,
                          &x[t * d], 1, vDSP_Length(d))
            }
            for l in 0..<nLayer {
                let p = "h.\(l)."
                var h = layerNorm(x, rows: T, p + "ln_1", W)
                let qkv = linear(h, rows: T, inDim: d, outDim: 3 * d, p + "attn.c_attn", W)
                let a = attention(qkv, T: T)
                var proj = linear(a, rows: T, inDim: d, outDim: d, p + "attn.c_proj", W)
                GPT2LanguageModel.add(&x, proj)
                h = layerNorm(x, rows: T, p + "ln_2", W)
                var f = linear(h, rows: T, inDim: d, outDim: 4 * d, p + "mlp.c_fc", W)
                geluNew(&f)
                proj = linear(f, rows: T, inDim: 4 * d, outDim: d, p + "mlp.c_proj", W)
                GPT2LanguageModel.add(&x, proj)
            }
            x = layerNorm(x, rows: T, "ln_f", W)
        }
        return x
    }

    private func layerNorm(_ x: [Float], rows: Int, _ name: String, _ W: UnsafeBufferPointer<Float>) -> [Float] {
        let d = self.d
        var out = [Float](repeating: 0, count: x.count)
        let g = W.baseAddress! + w(name + ".weight"), b = W.baseAddress! + w(name + ".bias")
        for r in 0..<rows {
            var mean: Float = 0, sd: Float = 0
            x.withUnsafeBufferPointer { xp in
                out.withUnsafeMutableBufferPointer { op in
                    let src = xp.baseAddress! + r * d, dst = op.baseAddress! + r * d
                    vDSP_normalize(src, 1, dst, 1, &mean, &sd, vDSP_Length(d))
                    // vDSP_normalize divides by the population std without eps; redo with eps.
                    let scale = sd / (sd * sd + eps).squareRoot()
                    var s = scale
                    vDSP_vsmul(dst, 1, &s, dst, 1, vDSP_Length(d))
                    vDSP_vma(dst, 1, g, 1, b, 1, dst, 1, vDSP_Length(d))
                }
            }
        }
        return out
    }

    /// x [rows, inDim] · W [inDim, outDim] + bias.
    private func linear(_ x: [Float], rows: Int, inDim: Int, outDim: Int, _ name: String,
                        _ W: UnsafeBufferPointer<Float>) -> [Float] {
        var out = [Float](repeating: 0, count: rows * outDim)
        vDSP_mmul(x, 1, W.baseAddress! + w(name + ".weight"), 1, &out, 1,
                  vDSP_Length(rows), vDSP_Length(outDim), vDSP_Length(inDim))
        let bias = W.baseAddress! + w(name + ".bias")
        out.withUnsafeMutableBufferPointer { op in
            for r in 0..<rows {
                vDSP_vadd(op.baseAddress! + r * outDim, 1, bias, 1, op.baseAddress! + r * outDim, 1, vDSP_Length(outDim))
            }
        }
        return out
    }

    /// Causal multi-head self-attention. qkv is [T, 3d] (q | k | v).
    private func attention(_ qkv: [Float], T: Int) -> [Float] {
        let d = self.d, hd = d / nHead
        let scale = 1 / Float(hd).squareRoot()
        var out = [Float](repeating: 0, count: T * d)
        var scores = [Float](repeating: 0, count: T)
        qkv.withUnsafeBufferPointer { q in
            out.withUnsafeMutableBufferPointer { o in
                for head in 0..<nHead {
                    for i in 0..<T {
                        let qi = q.baseAddress! + i * 3 * d + head * hd
                        var maxScore = -Float.infinity
                        for j in 0...i {
                            var s: Float = 0
                            vDSP_dotpr(qi, 1, q.baseAddress! + j * 3 * d + d + head * hd, 1, &s, vDSP_Length(hd))
                            scores[j] = s * scale
                            maxScore = max(maxScore, scores[j])
                        }
                        var sum: Float = 0
                        for j in 0...i { scores[j] = expf(scores[j] - maxScore); sum += scores[j] }
                        let dst = o.baseAddress! + i * d + head * hd
                        for j in 0...i {
                            var a = scores[j] / sum
                            vDSP_vsma(q.baseAddress! + j * 3 * d + 2 * d + head * hd, 1, &a, dst, 1, dst, 1, vDSP_Length(hd))
                        }
                    }
                }
            }
        }
        return out
    }

    /// x += y (same length).
    private static func add(_ x: inout [Float], _ y: [Float]) {
        x.withUnsafeMutableBufferPointer { xp in
            vDSP_vadd(xp.baseAddress!, 1, y, 1, xp.baseAddress!, 1, vDSP_Length(xp.count))
        }
    }

    /// gelu_new: 0.5·x·(1 + tanh(√(2/π)·(x + 0.044715·x³))).
    private func geluNew(_ x: inout [Float]) {
        let n = x.count
        var inner = [Float](repeating: 0, count: n)
        x.withUnsafeMutableBufferPointer { xb in
            inner.withUnsafeMutableBufferPointer { ib in
                let xp = xb.baseAddress!, ip = ib.baseAddress!, len = vDSP_Length(n)
                var c3: Float = 0.044715, one: Float = 1, k = (2 / Float.pi).squareRoot(), half: Float = 0.5
                vDSP_vsq(xp, 1, ip, 1, len)                    // x²
                vDSP_vsmsa(ip, 1, &c3, &one, ip, 1, len)       // 1 + 0.044715·x²
                vDSP_vmul(ip, 1, xp, 1, ip, 1, len)            // x + 0.044715·x³
                vDSP_vsmul(ip, 1, &k, ip, 1, len)
                var count = Int32(n)
                vvtanhf(ip, ip, &count)
                vDSP_vsadd(ip, 1, &one, ip, 1, len)            // 1 + tanh(…)
                vDSP_vmul(ip, 1, xp, 1, xp, 1, len)
                vDSP_vsmul(xp, 1, &half, xp, 1, len)
            }
        }
    }

    /// Sum over target positions of log softmax(h · wteᵀ)[target]. Row `from + i` predicts target i.
    private func logSoftmaxScore(_ h: [Float], rows T: Int, from start: Int, targets: [Int32],
                                 w W: UnsafeBufferPointer<Float>) -> Double {
        let d = self.d, V = vocabSize
        let rowsUsed = T - start
        // hᵀ for the rows we need: [d, rowsUsed]
        var hT = [Float](repeating: 0, count: d * rowsUsed)
        h.withUnsafeBufferPointer { hp in
            vDSP_mtrans(hp.baseAddress! + start * d, 1, &hT, 1, vDSP_Length(d), vDSP_Length(rowsUsed))
        }
        // logitsᵀ [V, rowsUsed] = wte [V, d] · hᵀ [d, rowsUsed]
        var logitsT = [Float](repeating: 0, count: V * rowsUsed)
        vDSP_mmul(W.baseAddress! + w("wte.weight"), 1, hT, 1, &logitsT, 1,
                  vDSP_Length(V), vDSP_Length(rowsUsed), vDSP_Length(d))
        var logits = [Float](repeating: 0, count: V * rowsUsed)       // [rowsUsed, V]
        vDSP_mtrans(logitsT, 1, &logits, 1, vDSP_Length(rowsUsed), vDSP_Length(V))
        var total = 0.0
        var expBuf = [Float](repeating: 0, count: V)
        logits.withUnsafeMutableBufferPointer { lp in
            expBuf.withUnsafeMutableBufferPointer { eb in
                let e = eb.baseAddress!
                for i in 0..<rowsUsed {
                    let row = lp.baseAddress! + i * V
                    var m: Float = 0
                    vDSP_maxv(row, 1, &m, vDSP_Length(V))
                    var negM = -m
                    vDSP_vsadd(row, 1, &negM, e, 1, vDSP_Length(V))
                    var n = Int32(V)
                    vvexpf(e, e, &n)
                    var sum: Float = 0
                    vDSP_sve(e, 1, &sum, vDSP_Length(V))
                    total += Double(row[Int(targets[i])] - m) - Double(logf(sum))
                }
            }
        }
        return total
    }
}
