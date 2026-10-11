import CoreGraphics
import Testing

/// The fixture's own promises, which the scanner tests that run "with smoothing on and off" rest on: a page is drawn the way it is
/// asked, whatever this Mac's font-smoothing default is, so the two runs are really two different pages.
struct ScanFixtureTests {
    private func bytes(of image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data!
        return Array(UnsafeBufferPointer(start: CFDataGetBytePtr(data), count: CFDataGetLength(data)))
    }

    private func page(smoothing: Bool) -> ScanFixture {
        let page = ScanFixture(width: 400, height: 80, smoothing: smoothing)
        page.text("jane.doe@example.com", x: 20, top: 20, size: 28)
        return page
    }

    @Test func aPageWithSmoothingOnIsNotThePageWithItOff() {
        let on = page(smoothing: true), off = page(smoothing: false)
        #expect(bytes(of: on.image()) != bytes(of: off.image()))
    }

    @Test func eachSettingDrawsTheSamePageEveryTime() {
        for smoothing in [true, false] {
            #expect(bytes(of: page(smoothing: smoothing).image()) == bytes(of: page(smoothing: smoothing).image()), "smoothing \(smoothing)")
        }
    }

    @Test func inkIsWhereTheTextIsAndNotElsewhere() throws {
        for smoothing in [true, false] {
            let fixture = ScanFixture(width: 400, height: 80, smoothing: smoothing)
            let line = fixture.text("jane.doe@example.com", x: 20, top: 20, size: 28)
            let ink = try #require(fixture.inkBox(in: CGRect(x: 0, y: 0, width: 400, height: 80)))
            // Inside the line's own box, give or take the fringe of a smoothed letter, and none beyond it.
            #expect(line.rect.insetBy(dx: -4, dy: -4).contains(ink), "ink \(ink) for \(line.rect), smoothing \(smoothing)")
            #expect(fixture.inkBox(in: CGRect(x: 0, y: 0, width: 400, height: 10)) == nil, "nothing above the text")
            #expect(fixture.inkBox(in: CGRect(x: 0, y: 70, width: 400, height: 10)) == nil, "nothing below it")
        }
    }
}
