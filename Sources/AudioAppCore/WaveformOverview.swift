/// A picture of a recording small enough to draw: the lowest, highest and average level of
/// each short stretch, kept at several zoom levels so any width of view is cheap to draw.
public struct WaveformOverview: Codable, Equatable, Sendable {
    /// One stretch of audio.
    public struct Bucket: Codable, Equatable, Sendable {
        public var min: Float
        public var max: Float
        public var rms: Float

        public init(min: Float, max: Float, rms: Float) {
            self.min = min
            self.max = max
            self.rms = rms
        }

        public static let silent = Bucket(min: 0, max: 0, rms: 0)
    }

    /// The whole recording at one zoom.
    public struct Level: Codable, Equatable, Sendable {
        public let framesPerBucket: Int
        /// One row of buckets per channel.
        public let channels: [[Bucket]]

        public init(framesPerBucket: Int, channels: [[Bucket]]) {
            self.framesPerBucket = framesPerBucket
            self.channels = channels
        }
    }

    public let frameCount: Int
    public let sampleRate: Double
    public let channelCount: Int
    /// Finest first.
    public let levels: [Level]

    public init(frameCount: Int, sampleRate: Double, channelCount: Int, levels: [Level]) {
        self.frameCount = frameCount
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.levels = levels
    }

    /// The index of the coarsest level that still has at least one bucket per pixel, or the
    /// finest when the view is zoomed in past it.
    public func levelIndex(framesPerPixel: Double) -> Int {
        var chosen = 0
        for (index, level) in levels.enumerated() where Double(level.framesPerBucket) <= framesPerPixel { chosen = index }
        return chosen
    }

    /// What to draw for a range of frames across a width in pixels: one bucket per pixel.
    /// Pixels past the end of the recording are silent.
    public func buckets(channel: Int, frames: Range<Int>, width: Int) -> [Bucket] {
        guard width > 0, !frames.isEmpty, channel >= 0, channel < channelCount, !levels.isEmpty else {
            return [Bucket](repeating: .silent, count: Swift.max(0, width))
        }
        let perPixel = Double(frames.count) / Double(width)
        let level = levels[levelIndex(framesPerPixel: perPixel)]
        let row = level.channels[channel]
        let size = Double(level.framesPerBucket)
        return (0..<width).map { pixel in
            let start = Double(frames.lowerBound) + Double(pixel) * perPixel
            let first = Int((start / size).rounded(.down))
            let last = Swift.max(first + 1, Int(((start + perPixel) / size).rounded(.up)))
            guard first < row.count, last > 0 else { return .silent }
            var merged = row[Swift.max(0, first)]
            var squares = merged.rms * merged.rms
            var count: Float = 1
            var index = Swift.max(0, first) + 1
            while index < Swift.min(last, row.count) {
                merged.min = Swift.min(merged.min, row[index].min)
                merged.max = Swift.max(merged.max, row[index].max)
                squares += row[index].rms * row[index].rms
                count += 1
                index += 1
            }
            merged.rms = (squares / count).squareRoot()
            return merged
        }
    }
}

/// Makes a `WaveformOverview`, all at once from a buffer or a block at a time as a recording
/// arrives. Not for the audio thread: it grows as audio is appended.
public struct WaveformBuilder {
    private struct Running {
        var min: Float = .infinity
        var max: Float = -.infinity
        var squares: Double = 0
        var count = 0

        mutating func add(_ sample: Float) {
            min = Swift.min(min, sample)
            max = Swift.max(max, sample)
            squares += Double(sample) * Double(sample)
            count += 1
        }

        mutating func add(_ other: Running) {
            min = Swift.min(min, other.min)
            max = Swift.max(max, other.max)
            squares += other.squares
            count += other.count
        }

        var bucket: WaveformOverview.Bucket {
            count == 0 ? .silent : .init(min: min, max: max, rms: Float((squares / Double(count)).squareRoot()))
        }
    }

    public let channelCount: Int
    public let sampleRate: Double
    public let framesPerBucket: Int
    /// How much coarser each level is than the one before.
    public let factor: Int
    public private(set) var frameCount = 0
    private var finished: [[Running]]
    private var partial: [Running]

    public init(channelCount: Int, sampleRate: Double, framesPerBucket: Int = 256, factor: Int = 4) {
        self.channelCount = Swift.max(1, channelCount)
        self.sampleRate = sampleRate
        self.framesPerBucket = Swift.max(1, framesPerBucket)
        self.factor = Swift.max(2, factor)
        finished = [[Running]](repeating: [], count: self.channelCount)
        partial = [Running](repeating: Running(), count: self.channelCount)
    }

    /// Adds more audio to the end. Channels the block lacks are treated as silent.
    public mutating func append(_ block: AudioBlock) {
        for channel in 0..<channelCount {
            let samples = channel < block.channelCount ? block[channel] : nil
            for frame in 0..<block.frameCount {
                partial[channel].add(samples?[frame] ?? 0)
                if partial[channel].count == framesPerBucket {
                    finished[channel].append(partial[channel])
                    partial[channel] = Running()
                }
            }
        }
        frameCount += block.frameCount
    }

    /// The overview of everything appended so far. The builder can go on being appended to.
    public func overview() -> WaveformOverview {
        var rows = finished
        for channel in 0..<channelCount where partial[channel].count > 0 { rows[channel].append(partial[channel]) }
        var levels: [WaveformOverview.Level] = []
        var size = framesPerBucket
        while true {
            levels.append(.init(framesPerBucket: size, channels: rows.map { $0.map(\.bucket) }))
            guard (rows.first?.count ?? 0) > 1 else { break }
            rows = rows.map { row in
                stride(from: 0, to: row.count, by: factor).map { start in
                    var merged = Running()
                    for index in start..<Swift.min(start + factor, row.count) { merged.add(row[index]) }
                    return merged
                }
            }
            size *= factor
        }
        return WaveformOverview(frameCount: frameCount, sampleRate: sampleRate, channelCount: channelCount, levels: levels)
    }

    /// The overview of a whole buffer.
    public static func overview(of buffer: SampleBuffer, sampleRate: Double, framesPerBucket: Int = 256, factor: Int = 4) -> WaveformOverview {
        var builder = WaveformBuilder(channelCount: buffer.channelCount, sampleRate: sampleRate, framesPerBucket: framesPerBucket, factor: factor)
        builder.append(buffer.block)
        return builder.overview()
    }
}
