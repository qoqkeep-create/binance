import Metal

final class MetalGlyphTextureCache {
    private struct Entry {
        let texture: MTLTexture
        let bytes: Int
        var lastUse: UInt64
    }

    private let maximumPages: Int
    private let maximumBytes: Int
    private var entries: [UInt64: Entry] = [:]
    private var clock: UInt64 = 0

    init(
        maximumPages: Int = 2,
        maximumBytes: Int = 2_097_152
    ) {
        self.maximumPages = max(1, maximumPages)
        self.maximumBytes = max(1, maximumBytes)
    }

    func texture(
        for atlas: ChartGlyphAtlasSnapshot,
        device: MTLDevice
    ) -> MTLTexture? {
        clock &+= 1
        if var cached = entries[atlas.revision] {
            cached.lastUse = clock
            entries[atlas.revision] = cached
            return cached.texture
        }

        let (bytes, overflow) = atlas.bytesPerRow
            .multipliedReportingOverflow(by: atlas.height)
        guard !overflow,
              atlas.width > 0,
              atlas.height > 0,
              atlas.bytesPerRow >= atlas.width,
              bytes > 0,
              bytes <= maximumBytes,
              atlas.pixels.count >= bytes else {
            return nil
        }

        evictUntilFits(incomingBytes: bytes)
        let currentBytes = entries.values.reduce(into: 0) {
            $0 += $1.bytes
        }
        guard entries.count < maximumPages,
              currentBytes <= maximumBytes - bytes else {
            return nil
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: atlas.width,
            height: atlas.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(
            descriptor: descriptor
        ) else {
            return nil
        }
        texture.label = "Chart glyph atlas \(atlas.revision)"
        atlas.pixels.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return
            }
            texture.replace(
                region: MTLRegionMake2D(
                    0,
                    0,
                    atlas.width,
                    atlas.height
                ),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: atlas.bytesPerRow
            )
        }

        entries[atlas.revision] = Entry(
            texture: texture,
            bytes: bytes,
            lastUse: clock
        )
        return texture
    }

    func removeAll() {
        entries.removeAll(keepingCapacity: false)
        clock = 0
    }

    private func evictUntilFits(incomingBytes: Int) {
        while !entries.isEmpty {
            let currentBytes = entries.values.reduce(into: 0) {
                $0 += $1.bytes
            }
            guard entries.count >= maximumPages
                    || currentBytes > maximumBytes - incomingBytes else {
                return
            }
            guard let oldest = entries.min(by: {
                $0.value.lastUse < $1.value.lastUse
            })?.key else {
                return
            }
            entries.removeValue(forKey: oldest)
        }
    }
}
