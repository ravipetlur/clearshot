import CryptoKit
import Foundation
import Testing
@testable import CSWebP

/// The files the encoder writes, byte for byte. The round-trip tests say a file decodes to the right pixels; these say
/// it is the same file as before, so a change that should only alter how the encoder works (its memory, its speed) is
/// shown not to alter what it writes.
///
/// Each case is encoded and its SHA-256 compared with the one recorded below. When a change to the encoder is meant to
/// change its output (a better choice of copies, say), the failing cases print their new digests as table lines to
/// paste in.
struct EncoderOutputTests {
    /// One file to encode: the name it is recorded under, and how it is made.
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        let encode: @Sendable () throws -> Data

        var testDescription: String { name }
    }

    /// The automatic choice for every fixture of the round-trip catalogue and for the two screenshots with photographs
    /// in them (the images large enough to be judged on a sample, and where the predictor wins); then a few small
    /// images through each way of coding the pixels, which the public `encode` never picks by itself.
    static let cases: [Case] = {
        var list: [Case] = []
        func automatic(_ name: String, _ make: @escaping @Sendable () -> RGBAImage) {
            list.append(Case(name: "automatic " + name) {
                let image = make()
                return try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height)
            })
        }
        for fixture in Fixtures.catalogue { automatic(fixture.name, fixture.make) }
        automatic("ui with a banner photograph 1200x800") { Fixtures.uiScreenshotWithPhoto(1200, 800) }
        automatic("article with photographs 400x3200") { Fixtures.articleWithPhotos(400, 3200) }

        let images: [(name: String, make: @Sendable () -> RGBAImage)] = [
            ("noise 100x80", { Fixtures.noise(100, 80, seed: 1) }),
            ("ui 160x90", { Fixtures.uiScreenshot(160, 90) }),
            ("runs 200x150", { Fixtures.runs(200, 150) }),
            ("binary alpha 97x61", { Fixtures.binaryAlpha(97, 61) }),
        ]
        let transforms: [(name: String, value: WebPLosslessEncoder.Transforms)] = [
            ("no transform", .none), ("predictor", .predictor),
            ("subtract green and predictor", .subtractGreenAndPredictor),
        ]
        let codings: [(name: String, value: WebPLosslessEncoder.PixelCoding)] = [
            ("literals only", .literalsOnly), ("copies without a cache", .backReferences(cacheBits: 0)),
            ("copies with a 4-bit cache", .backReferences(cacheBits: 4)),
        ]
        func forced(_ imageName: String, _ make: @escaping @Sendable () -> RGBAImage, _ transformName: String,
                    _ transforms: WebPLosslessEncoder.Transforms, _ codingName: String,
                    _ coding: WebPLosslessEncoder.PixelCoding) {
            list.append(Case(name: "\(imageName), \(transformName), \(codingName)") {
                let image = make()
                return try WebPLosslessEncoder.encode(rgba: image.rgba, width: image.width, height: image.height,
                                                      coding: coding, transforms: transforms)
            })
        }
        for image in images {
            for transform in transforms {
                for coding in codings {
                    forced(image.name, image.make, transform.name, transform.value, coding.name, coding.value)
                }
            }
        }
        for coding in codings {
            forced("palette 5 17x9", { Fixtures.palette(5, 17, 9) }, "palette", .palette, coding.name, coding.value)
            forced("palette 2 40x30", { Fixtures.palette(2, 40, 30) }, "palette", .palette, coding.name, coding.value)
        }
        return list
    }()

    static func digest(of file: Data) -> String {
        SHA256.hash(data: file).map { String(format: "%02x", $0) }.joined()
    }

    @Test(arguments: cases)
    func theFileIsTheOneRecorded(_ testCase: Case) throws {
        let actual = Self.digest(of: try testCase.encode())
        let expected = Self.digests[testCase.name]
        #expect(actual == expected, """
            \(testCase.name): recorded \(expected ?? "nothing"); the table entry is
                    "\(testCase.name)":
                        "\(actual)",
            """)
    }

    @Test func theTableHoldsExactlyTheCases() {
        #expect(Set(Self.digests.keys) == Set(Self.cases.map(\.name)))
        #expect(Set(Self.cases.map(\.name)).count == Self.cases.count, "the names are all different")
    }

    /// SHA-256 of each file, by case name.
    static let digests: [String: String] = [
        "automatic all transparent 33x17":
            "985132c0fe29d1a74e4cb9557e7a933c0282df962ac258908f9006180f3904ca",
        "automatic alpha gradient 256x64":
            "dc3c60d3cb6d97b703b8c570f98bde8713a2a2047eb8ea6c6c374201aff8b407",
        "automatic alpha gradient 50x1":
            "8e67ccf8ddad96fc0576746f543f991299050e8c2d4349c398b36cf47af2f163",
        "automatic article with photographs 400x3200":
            "c975affc83c620358fa0beca7ce0d70338a0c2f069f1562cb23934afaabc6040",
        "automatic binary alpha 97x61":
            "afe576aa21e4112362ac5f3356abe40c4a6a627d90a0320c20461b12df2be9b0",
        "automatic noise 100x80":
            "9285adb859794f6d35e63a0503b67036a7e7973cfc051a4bf2acff22dab02bb7",
        "automatic noise 31x7":
            "328d61ec20f3062cb0ccfba3b5c7bd574f3448159746e9b3484fcc3facd44c03",
        "automatic palette 1 40x30":
            "f2601411f3d16524b28471f814cdc11b21ae21e6ec4c18c8628aaa1020487678",
        "automatic palette 16 17x9":
            "0d945df213fac2222b0c288fd7fea1c31a075b5cbc8c7fa5db8d249cfa29474a",
        "automatic palette 16 40x30":
            "a1514258b234f019bce5ad02391f8e93b0657dc14f3fbf04e4813f96e2de5df9",
        "automatic palette 17 40x30":
            "98e77a6b14e397cbe829a7f32dda7a226c232607a182960acfd22c03d6fc2082",
        "automatic palette 2 17x9":
            "92f10cb8d6177c394b03f7abdbd8f3fac0a37256734ceea405de4e56bac5ca22",
        "automatic palette 2 40x30":
            "fb8b36f58a534a636bf510cc4ef531f2c168d2d0c2ca125785944627d329278f",
        "automatic palette 256 40x30":
            "76832d182163793a9895aeba21820bcc362feeaf5ea21a289a33a47252f96299",
        "automatic palette 257 40x30":
            "ca4568de285e5c804b6783c9556d1bb751ee4afea199db8295c5805e8b899121",
        "automatic palette 3 17x9":
            "31474fcafc8f8e4d9a5504f610e17270936c4e23addd86f26fa9bfd39d6967bb",
        "automatic palette 3 40x30":
            "f00062acc9236413c42c155cf7eb8f6632110c517dadf68c4990f5518d211e96",
        "automatic palette 4 17x9":
            "94b2a933b85978c35dcc83cfa0c9ed733b73b07f4ecb8c7c92e0d2e4df3e9af7",
        "automatic palette 4 40x30":
            "b000572caba9561eb6b313c96d92b5dfe700ca89e04bf86893382a6e780ebd6c",
        "automatic palette 5 17x9":
            "7b32cb3fb6ca80000fda026d9bbf202324d53b985bacaed643599f059c6dd16e",
        "automatic palette 5 40x30":
            "51e4bb7ee0ce25b376e9820a4b2d19a8cf121ceb3884dd18969c954133e01714",
        "automatic random noise 100x80":
            "0504be2b48070a87c51e8f00f4a243659b0d6b1f7cfcde2aec1b38776b715e61",
        "automatic random noise 310x70":
            "3e47bd909bcfc7cafa8627fb8e0c5420aecd769746518503e3faa00cdd31fa25",
        "automatic repeated tiles 1x40":
            "6ce4a32fd5ad2a1b2cbbbe297ac6037b9461cdfe27397bd8c2e393f82681bc49",
        "automatic repeated tiles 2x40":
            "47854edb63306d57b886dc89d8227465f30eaf81304e382b79d5944d58d10ce6",
        "automatic repeated tiles 3x40":
            "a03ed6b60212f337c19114f81a051f70e72c9972fff70bb4990e7dfb396a4d3a",
        "automatic repeated tiles 64x40":
            "5669f43deb48ae7855bb97289aaf6473a2ca5fcd9c4fd2993c3c0b1d951c1e4a",
        "automatic repeated tiles 8x40":
            "40d67bf039841f7c7eec5a15c8a1a9485336af3bfeba36f6496a73f4d3dbb409",
        "automatic runs 1x9000":
            "7e970c7cbae7d8bcd6c29bbd8876a16b08725529e60662c226730d4a2a3f880b",
        "automatic runs 200x150":
            "80098d1d17fd34f92872b06b3162c8e00762b77232c44aaa73b051662d8fe85f",
        "automatic ui 17x33":
            "8b90d293f418dee09c190102ef2e936f9c595535b2d93384a9a9d349fce63724",
        "automatic ui 640x360":
            "a947448d3760aa98fe474583d8e27cf042f9db8db6e3c0bfcc76870c2ff07490",
        "automatic ui flat 640x360":
            "2a806cbdb9a28bafc1311625f5ed38e2c29dead4ec429711a7290286801e8dec",
        "automatic ui with a banner photograph 1200x800":
            "dd8dfcabf6f0934172ad3a23b635ba5c2761151b9d08f01c575fbe2052ceb5e2",
        "binary alpha 97x61, no transform, copies with a 4-bit cache":
            "0cd58295dd7d9cdaee3595c42ef558c2b33973f0eaf72c0d2f41e117a66510bd",
        "binary alpha 97x61, no transform, copies without a cache":
            "663fb56e8e1d2ae92ca2110b28789ef57b5b6813029829cba57e9c713703f2ac",
        "binary alpha 97x61, no transform, literals only":
            "09caccddc725bfb14e6c93ff9ad0081b41aba6112eb2b72bb94ab8b48be212d7",
        "binary alpha 97x61, predictor, copies with a 4-bit cache":
            "1dd486d47c4d25db304e65c443408cd5ada05da71a71493d8d5768ee9d92de4a",
        "binary alpha 97x61, predictor, copies without a cache":
            "38ceb2d6dbcd6332434fbb93a9afa21018a2aa316646b88dc9c2e1b8f9129097",
        "binary alpha 97x61, predictor, literals only":
            "c693176f6ce34c73ab80f251b7c143c5f86388e0b5d23c20922edaf0681f0074",
        "binary alpha 97x61, subtract green and predictor, copies with a 4-bit cache":
            "8961704d10e78dfad9756b954c9b039fb842b5eab3bfd763feb62aa862a72b8f",
        "binary alpha 97x61, subtract green and predictor, copies without a cache":
            "2938ece17f881ffc0d222baf5a891d88bf67cf8e6ab1dfa2076740109e1b672c",
        "binary alpha 97x61, subtract green and predictor, literals only":
            "dabab9b126a80ca6e0c14da6dec0fae42ce2a23a5d08a4f2658a33661756403a",
        "noise 100x80, no transform, copies with a 4-bit cache":
            "c426f6994a2c38294209904d4cef69fde095a115153eba79fad4bcff007b8cc7",
        "noise 100x80, no transform, copies without a cache":
            "ed5641c04b612f4f8ff6b327db895bc153ead5733a7ef8e21624f6b8b8f2f240",
        "noise 100x80, no transform, literals only":
            "ed5641c04b612f4f8ff6b327db895bc153ead5733a7ef8e21624f6b8b8f2f240",
        "noise 100x80, predictor, copies with a 4-bit cache":
            "d826ac546609e57513f133716f075eed1295b075a0afbc96da6795a3381ec613",
        "noise 100x80, predictor, copies without a cache":
            "25b7e26f250ecfcd914e2f9d961d8dc52f0bfcab57b016673a48f9c10fee33cc",
        "noise 100x80, predictor, literals only":
            "7bdc0b686444f2e7eb2e36295aac5e94cec6ccb70bb012caea71aab72dd60f1f",
        "noise 100x80, subtract green and predictor, copies with a 4-bit cache":
            "7edd21c805dec57a3ca9e81971d65d17d361406f60fdb378078e36396d3401f8",
        "noise 100x80, subtract green and predictor, copies without a cache":
            "cb93b6baa4fc18ffb5faf0d8c92b4e103bd2cfba1cb65560cfb3c50f1e7fe50a",
        "noise 100x80, subtract green and predictor, literals only":
            "9285adb859794f6d35e63a0503b67036a7e7973cfc051a4bf2acff22dab02bb7",
        "palette 2 40x30, palette, copies with a 4-bit cache":
            "857b7697b75286b507674323f2a0a22800a6898efcfdd2e4c852462eb417d622",
        "palette 2 40x30, palette, copies without a cache":
            "fb8b36f58a534a636bf510cc4ef531f2c168d2d0c2ca125785944627d329278f",
        "palette 2 40x30, palette, literals only":
            "0ee7f10be44d3e1f5e2140a1550c5ab6aa8f5c1b8e421d3bc92be263e04865bd",
        "palette 5 17x9, palette, copies with a 4-bit cache":
            "44235ed6c8b39980260bd92692bd3251b1130ed1159a3de905107b4a77049c1a",
        "palette 5 17x9, palette, copies without a cache":
            "7b32cb3fb6ca80000fda026d9bbf202324d53b985bacaed643599f059c6dd16e",
        "palette 5 17x9, palette, literals only":
            "179178ca3568f9665ef6286d0670117b5c58da7b1cd69adf1bbe4ad7f99d1a09",
        "runs 200x150, no transform, copies with a 4-bit cache":
            "18525e627275d56a21aa591243db63a901e312f612a83c91e19792231100ac47",
        "runs 200x150, no transform, copies without a cache":
            "3190c433dfb7f3a5e5e204f2ace04b551aec7294c3712d7250087da31fbc722c",
        "runs 200x150, no transform, literals only":
            "20cdb89877b9e92517da07b639784c81504b33a692d16332fcce35e5b6ff1a9c",
        "runs 200x150, predictor, copies with a 4-bit cache":
            "0b649fe19779bb9f74f40e25d48e7fc3fc449129bf73411618973c013053c6fb",
        "runs 200x150, predictor, copies without a cache":
            "895a199b10c239d57ce2e27aa449b438a151e661ba20fe40f8d12b4273bbfc84",
        "runs 200x150, predictor, literals only":
            "e7380724675f148ddf41530c1a4eea38f1f88f353256272c02d589231ac76d34",
        "runs 200x150, subtract green and predictor, copies with a 4-bit cache":
            "79343c88b0f11dfbe86516214abdeb36e76e182554400c514b76c91aa5e6ec3f",
        "runs 200x150, subtract green and predictor, copies without a cache":
            "99d89998911c7ea0f4fbf35bc7786a6f7768e2d75c8d4d67a734d2701b4c4d70",
        "runs 200x150, subtract green and predictor, literals only":
            "176ad1739b581b01c3afe4dfe08d1eeec91ac8a574862cd87766652f23745b37",
        "ui 160x90, no transform, copies with a 4-bit cache":
            "5f3095916ab11f0559c0246992bdd4585b56209cbe239edb9bdfcc3be6416618",
        "ui 160x90, no transform, copies without a cache":
            "c154761cd2ac6651ba4f916b9f730f29b9e7816270a3a4efd07478a310918775",
        "ui 160x90, no transform, literals only":
            "c39e7719594022092ad0910fde9209a4ba0d06f8e79694770db9eba70084337a",
        "ui 160x90, predictor, copies with a 4-bit cache":
            "67751d3f70f3b9b2a51b1ae2e5895165d61799539ca2b4d7f6f34334635b9313",
        "ui 160x90, predictor, copies without a cache":
            "449dc1b16894f5dcea63febec08dd0d8b1081887b063b8a2c53fcc476e0ce8f1",
        "ui 160x90, predictor, literals only":
            "7132395a0c25ebe9fecdb7050b6aceff1cc420ca6c1b6beec8874397d2d473eb",
        "ui 160x90, subtract green and predictor, copies with a 4-bit cache":
            "68aab9ce418ac0eed5b82b6c0e6f8ff889e65f74e63c5c149870faa81f389981",
        "ui 160x90, subtract green and predictor, copies without a cache":
            "cccaada79b573181c9fd38f54a17c99114d29ee4357c550a81aec99e8e366b19",
        "ui 160x90, subtract green and predictor, literals only":
            "215128129c17807b59d0ef718d02df22c2977252ea6897f9314223ada431aeb6",
    ]
}
