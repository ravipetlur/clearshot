import Testing
@testable import CSRecording

struct VideoEditPlanTests {
    /// A 10 s 1080p recording at 30 fps, 8 Mbit/s H.264, with one stereo track.
    func source(width: Int = 1920, height: Int = 1080, audio: [Int] = [2]) -> VideoSourceInfo {
        VideoSourceInfo(duration: 10, pixelWidth: width, pixelHeight: height, framesPerSecond: 30, videoBitRate: 8_000_000,
                        codec: .h264, audioChannelCounts: audio)
    }

    func edit(_ change: (inout VideoEdit) -> Void) -> VideoEdit {
        var edit = VideoEdit()
        change(&edit)
        return edit
    }

    @Test func noChangeIsNothing() {
        let plan = VideoEditPlan.make(edit: VideoEdit(), source: source())
        #expect(plan.path == .nothing)
        #expect(plan.timeRange == nil)
        #expect(plan.outputWidth == 1920)
        #expect(plan.outputHeight == 1080)
        #expect(plan.includesAudio)
        // A trim over the whole clip, or a resolution at or above the source, isn't a change either.
        let whole = edit { $0.trim = TrimRange(start: 0, end: 10, duration: 10, framesPerSecond: 30) }
        #expect(VideoEditPlan.make(edit: whole, source: source()).path == .nothing)
        let larger = edit { $0.resolution = .res1080p }
        #expect(VideoEditPlan.make(edit: larger, source: source()).path == .nothing)
        // Audio edits on a clip with no audio change nothing.
        let silent = edit { $0.mute = true; $0.volume = 0.5 }
        #expect(VideoEditPlan.make(edit: silent, source: source(audio: [])).path == .nothing)
    }

    @Test func aTrimIsAPassthrough() {
        let trim = TrimRange(start: 2, end: 6, duration: 10, framesPerSecond: 30)
        let plan = VideoEditPlan.make(edit: edit { $0.trim = trim }, source: source())
        #expect(plan.path == .passthrough)
        #expect(plan.timeRange == trim)
        #expect(plan.outputWidth == 1920)
        #expect(plan.outputHeight == 1080)
        #expect(plan.codec == .h264)
        #expect(plan.videoBitRate == nil)
        #expect(plan.includesAudio)
        #expect(plan.audioChannels == 2)
        #expect(plan.trackVolumes == [1])
        #expect(!plan.mergesTracks)
    }

    @Test func muteIsAPassthroughWithoutAudio() {
        let plan = VideoEditPlan.make(edit: edit { $0.mute = true }, source: source())
        #expect(plan.path == .passthrough)
        #expect(!plan.includesAudio)
        #expect(plan.audioChannels == 0)
        #expect(plan.trackVolumes.isEmpty)
        #expect(plan.videoBitRate == nil)
        // Mute Audio… is that plan, whatever else the item has.
        #expect(VideoEditPlan.mute(source()) == plan)
        #expect(VideoEditPlan.mute(source(audio: [2, 1])) == VideoEditPlan.make(edit: edit { $0.mute = true },
                                                                                  source: source(audio: [2, 1])))
        // Muting wins over the other audio edits.
        let muted = edit { $0.mute = true; $0.mono = true; $0.volume = 1.5 }
        #expect(VideoEditPlan.make(edit: muted, source: source()) == plan)
    }

    @Test func monoOrVolumeRemixesAndKeepsTheVideo() {
        let mono = VideoEditPlan.make(edit: edit { $0.mono = true }, source: source())
        #expect(mono.path == .audioRemix)
        #expect(mono.audioChannels == 1)
        #expect(mono.videoBitRate == nil)
        #expect(mono.outputWidth == 1920)
        #expect(mono.outputHeight == 1080)
        #expect(mono.includesAudio)
        let louder = VideoEditPlan.make(edit: edit { $0.volume = 1.5 }, source: source())
        #expect(louder.path == .audioRemix)
        #expect(louder.audioChannels == 2)
        #expect(louder.trackVolumes == [1.5])
        // With a trim too, the remix covers the trimmed range.
        let trim = TrimRange(start: 1, end: 3, duration: 10, framesPerSecond: 30)
        let both = VideoEditPlan.make(edit: edit { $0.mono = true; $0.trim = trim }, source: source())
        #expect(both.path == .audioRemix)
        #expect(both.timeRange == trim)
    }

    /// Single track after a recording with both: the system track, then the microphone's, mixed into one.
    @Test func mergingTwoTracksGivesOne() {
        let plan = VideoEditPlan.make(edit: edit { $0.trackVolumes = [1, 0.8] }, source: source(audio: [2, 1]))
        #expect(plan.path == .audioRemix)
        #expect(plan.mergesTracks)
        #expect(plan.trackVolumes == [1, 0.8])
        #expect(plan.audioChannels == 2)
        // One stereo track in the estimate: (8 Mbit/s + 192 kbit/s) × 10 s.
        #expect(plan.estimatedBytes == 10_240_000)
        // The overall volume applies on top of each track's.
        let quieter = VideoEditPlan.make(edit: edit { $0.trackVolumes = [1, 0.8]; $0.volume = 0.5 },
                                         source: source(audio: [2, 1]))
        #expect(quieter.trackVolumes == [0.5, 0.4])
    }

    @Test func aSmallerResolutionReencodesEvenSized() {
        let plan = VideoEditPlan.make(edit: edit { $0.resolution = .res480p }, source: source())
        #expect(plan.path == .reencode)
        #expect(plan.outputWidth == 854)
        #expect(plan.outputHeight == 480)
        #expect(plan.codec == .h264)
        // Original quality keeps the source's bits per pixel: 8 Mbit/s × 854 × 480 ÷ (1920 × 1080).
        #expect(plan.videoBitRate == 1_581_481)
        // A quality change alone keeps the size, made even: 0.06 bits per pixel at 30 fps.
        let medium = VideoEditPlan.make(edit: edit { $0.quality = .medium }, source: source(width: 1001, height: 667))
        #expect(medium.path == .reencode)
        #expect(medium.outputWidth == 1000)
        #expect(medium.outputHeight == 666)
        #expect(medium.videoBitRate == 1_198_800)
        let low = VideoEditPlan.make(edit: edit { $0.quality = .low; $0.resolution = .res720p }, source: source())
        #expect(low.outputWidth == 1280)
        #expect(low.outputHeight == 720)
        #expect(low.videoBitRate == 829_440)
        let high = VideoEditPlan.make(edit: edit { $0.quality = .high }, source: source())
        #expect(high.videoBitRate == 6_220_800)
        // EncoderPlan's codec rule: a side over 4096 is HEVC.
        let native = VideoEditPlan.make(edit: edit { $0.quality = .low }, source: source(width: 6720, height: 3780))
        #expect(native.codec == .hevc)
        // Audio edits ride along with the re-encode.
        let mono = VideoEditPlan.make(edit: edit { $0.quality = .low; $0.mono = true }, source: source())
        #expect(mono.path == .reencode)
        #expect(mono.audioChannels == 1)
    }

    /// Some imported files report an estimated data rate of 0: Original quality keeps the source's bits per pixel, which
    /// would be 0 bit/s, so it takes the encoder's floor instead.
    @Test func aReencodeAtOriginalQualityIsFloored() {
        var unknown = source()
        unknown.videoBitRate = 0
        let plan = VideoEditPlan.make(edit: edit { $0.resolution = .res720p }, source: unknown)
        #expect(plan.path == .reencode)
        #expect(plan.videoBitRate == EncoderPlan.minimumBitRate)
        // The estimate counts the floored rate: (1 Mbit/s + 192 kbit/s) × 10 s.
        #expect(plan.estimatedBytes == 1_490_000)
        // A low-rate source shrunk at Original quality goes no lower either.
        var low = source()
        low.videoBitRate = 600_000
        #expect(VideoEditPlan.make(edit: edit { $0.resolution = .res480p }, source: low).videoBitRate
            == EncoderPlan.minimumBitRate)
    }

    /// A file can report a nominal frame rate of 0; the bitrate maths then takes 30 fps, as the exporter's encoder does,
    /// so no quality plans 0 bit/s.
    @Test func aZeroFrameRateStillPlansABitrate() {
        var unknown = source()
        unknown.framesPerSecond = 0
        let low = VideoEditPlan.make(edit: edit { $0.quality = .low; $0.resolution = .res720p }, source: unknown)
        #expect(low.videoBitRate == 829_440)
        #expect(low.codec == .h264)
        for quality in VideoQuality.allCases {
            let plan = VideoEditPlan.make(edit: edit { $0.quality = quality; $0.resolution = .res480p }, source: unknown)
            #expect((plan.videoBitRate ?? 0) > 0, "\(quality)")
        }
        #expect(VideoEditPlan.fallbackFramesPerSecond == 30)
    }

    /// The exporter writes at most two separate audio tracks (a recording's), so a file with more has them merged into
    /// one whenever its audio is written again; a passthrough copies every track as it is.
    @Test func moreThanTwoTracksAreMergedWhenTheAudioIsWrittenAgain() {
        let three = source(audio: [2, 2, 1])
        let louder = VideoEditPlan.make(edit: edit { $0.volume = 1.5 }, source: three)
        #expect(louder.path == .audioRemix)
        #expect(louder.mergesTracks)
        #expect(louder.audioChannels == 2)
        #expect(louder.trackVolumes == [1.5, 1.5, 1.5])
        // One stereo track in the estimate: (8 Mbit/s + 192 kbit/s) × 10 s.
        #expect(louder.estimatedBytes == 10_240_000)
        let smaller = VideoEditPlan.make(edit: edit { $0.resolution = .res720p }, source: three)
        #expect(smaller.path == .reencode)
        #expect(smaller.mergesTracks)
        // A trim copies all three: 8 Mbit/s + 192 + 192 + 128 kbit/s for 4 s.
        let trim = TrimRange(start: 2, end: 6, duration: 10, framesPerSecond: 30)
        let trimmed = VideoEditPlan.make(edit: edit { $0.trim = trim }, source: three)
        #expect(trimmed.path == .passthrough)
        #expect(!trimmed.mergesTracks)
        #expect(trimmed.estimatedBytes == 4_256_000)
        // Two tracks stay separate unless the edit merges them.
        #expect(!VideoEditPlan.make(edit: edit { $0.volume = 1.5 }, source: source(audio: [2, 1])).mergesTracks)
    }

    /// A GIF's estimate: its current size per second of what it shows, for the trimmed length.
    @Test func aGIFEstimateScalesItsSizeByLength() {
        #expect(FileSizeEstimate.bytes(scaling: 3_000_000, from: 6, to: 2) == 1_000_000)
        #expect(FileSizeEstimate.bytes(scaling: 3_000_000, from: 6, to: 6) == 3_000_000)
        // Nothing to scale from.
        #expect(FileSizeEstimate.bytes(scaling: 3_000_000, from: 0, to: 2) == 3_000_000)
        #expect(FileSizeEstimate.bytes(scaling: 3_000_000, from: 6, to: -1) == 0)
    }

    @Test func onlyResolutionsBelowTheSourceAreOffered() {
        #expect(VideoEditPlan.resolutions(for: source()) == [.original, .res720p, .res480p])
        #expect(VideoEditPlan.resolutions(for: source(width: 3840, height: 2160))
            == [.original, .res1440p, .res1080p, .res720p, .res480p])
        // A portrait source measures its long side, its height.
        #expect(VideoEditPlan.resolutions(for: source(width: 1080, height: 1920)) == [.original, .res720p, .res480p])
        #expect(VideoEditPlan.resolutions(for: source(width: 640, height: 360)) == [.original])
    }

    @Test func estimateIsRatesTimesDuration() {
        #expect(FileSizeEstimate.bytes(videoBitRate: 8_000_000, audioBitRates: [192_000], duration: 10) == 10_240_000)
        #expect(FileSizeEstimate.bytes(videoBitRate: 1_000_000, audioBitRates: [], duration: 0) == 0)
        // A passthrough trim: the source's rate for the trimmed 4 s.
        let trim = TrimRange(start: 2, end: 6, duration: 10, framesPerSecond: 30)
        #expect(VideoEditPlan.make(edit: edit { $0.trim = trim }, source: source()).estimatedBytes == 4_096_000)
        // Two separate tracks, stereo and mono: 192 + 128 kbit/s.
        #expect(VideoEditPlan.make(edit: VideoEdit(), source: source(audio: [2, 1])).estimatedBytes == 10_400_000)
        // Mono: 128 kbit/s; muted: video alone.
        #expect(VideoEditPlan.make(edit: edit { $0.mono = true }, source: source()).estimatedBytes == 10_160_000)
        #expect(VideoEditPlan.mute(source()).estimatedBytes == 10_000_000)
        // A re-encode at its planned rate: 0.03 × 1280 × 720 × 30 = 829 440 bit/s, plus the audio, for 10 s.
        let low = VideoEditPlan.make(edit: edit { $0.quality = .low; $0.resolution = .res720p }, source: source())
        #expect(low.estimatedBytes == 1_276_800)
    }

    /// A four-character code as a format's media subtype reads it.
    func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }

    /// An edit writes an MP4, except one that copies the video as stored (Mute, a trim, a remix) from a codec MP4 can't
    /// carry (ProRes, say), which stays a QuickTime movie. A re-encode writes H.264 or HEVC, so it is always an MP4.
    @Test func anEditIsAnMP4UnlessItCopiesVideoMP4CantCarry() {
        var prores = source()
        prores.codec = nil
        prores.videoCodecType = code("apcn")
        let trim = TrimRange(start: 2, end: 6, duration: 10, framesPerSecond: 30)
        let edits = [edit { $0.trim = trim }, edit { $0.volume = 0.5 }, edit { $0.mono = true }, edit { $0.quality = .low }]
        #expect(edits.map { VideoEditPlan.make(edit: $0, source: prores).path } == [.passthrough, .audioRemix, .audioRemix,
                                                                                 .reencode])
        #expect(edits.map { VideoEditPlan.make(edit: $0, source: prores).container } == [.mov, .mov, .mov, .mp4])
        #expect(VideoEditPlan.mute(prores).container == .mov)
        var h264 = source()
        h264.videoCodecType = code("avc1")
        #expect(edits.map { VideoEditPlan.make(edit: $0, source: h264).container } == [.mp4, .mp4, .mp4, .mp4])
        #expect(VideoEditPlan.mute(h264).container == .mp4)
        // A source whose codec wasn't read is taken to be one MP4 carries, as before.
        #expect(source().videoCodecType == nil)
        #expect(VideoEditPlan.mute(source()).container == .mp4)
    }

    @Test func mp4CarriesOnlyTheCodecsItIsKnownToCarry() {
        for carried in ["avc1", "hvc1", "hev1", "mp4v"] {
            #expect(VideoContainer.mp4Carries(videoCodecType: code(carried)), "\(carried)")
        }
        // ProRes 422 and 4444, Animation, PNG and Motion JPEG stay in QuickTime.
        for kept in ["apcn", "apch", "apcs", "apco", "ap4h", "ap4x", "rle ", "png ", "jpeg"] {
            #expect(!VideoContainer.mp4Carries(videoCodecType: code(kept)), "\(kept)")
        }
        #expect(VideoContainer.mp4.fileExtension == "mp4")
        #expect(VideoContainer.mov.fileExtension == "mov")
    }
}
