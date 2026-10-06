import Foundation

/// What a file has to be (`APIFiles.validate`).
public enum APIFileKind: Sendable, Equatable {
    /// pin, open-annotate's images, capture-text.
    case image
    /// add-quick-access-overlay.
    case imageOrMovie
    /// open-annotate: an image, or a ClearShot project package.
    case imageOrProject
}

/// Why a URL command can't run. The app shows `message` as one HUD line and logs it with the command and the sender.
public enum APIError: Error, Sendable, Equatable {
    case wrongScheme(String), unknownCommand(String), notANumber(String), negative(String), notPositive(String)
    case incompleteArea, badDisplay(String), noSuchDisplay(Int), areaOffDisplay(Int), areaTooSmall
    case badAction(String), uploadRefused, badBoolean(name: String, value: String)
    /// `relativePath` holds the path as given; `fileNotFound` the path abbreviated with `~`; `notAFile`, `unreadable`,
    /// `wrongFileType`, `couldntOpen` (it isn't an image ImageIO reads) and `tooLarge` (`APIFiles.readLimit`) the
    /// file's name.
    case missingFile(String), fileAndArea, relativePath(String), fileNotFound(String), notAFile(String)
    case unreadable(String), wrongFileType(String, expected: APIFileKind), couldntOpen(String), tooLarge(String)

    /// One HUD line. Text from the URL (an action, a path, a file's name) is shown as a sender's name is
    /// (`SenderText.shown`): on one line, without invisible characters, at most 40 characters.
    public var message: String {
        switch self {
        case .wrongScheme: "ClearShot takes clearshot:// commands only"
        case let .unknownCommand(name): "Unknown command “\(APIRequest.shortened(name))”"
        case let .notANumber(parameter): "\(parameter) must be a number"
        case let .negative(parameter): "\(parameter) can't be negative"
        case let .notPositive(parameter): "\(parameter) must be more than 0"
        case .incompleteArea: "x, y, width and height go together"
        case .badDisplay: "display must be 1 or more"
        case let .noSuchDisplay(number): "There's no display \(number)"
        case let .areaOffDisplay(number): "That area isn't on display \(number)"
        case .areaTooSmall: "That area is too small (at least 4 × 4 points)"
        case let .badAction(value): "Unknown action “\(SenderText.shown(value))”: use copy, save, annotate or pin"
        case .uploadRefused: "ClearShot doesn't upload"
        case let .badBoolean(name, _): "\(name) must be true or false"
        case let .missingFile(command): "\(command) needs a filepath"
        case .fileAndArea: "Give capture-text a filepath or an area, not both"
        case .relativePath: "filepath must be a full path"
        case let .fileNotFound(path): "There's no file at \(SenderText.shown(path))"
        case let .notAFile(name): "\(SenderText.shown(name)) isn't a file"
        case let .unreadable(name): "ClearShot can't read \(SenderText.shown(name))"
        case let .wrongFileType(name, .image): "\(SenderText.shown(name)) isn't an image"
        case let .wrongFileType(name, .imageOrMovie): "\(SenderText.shown(name)) isn't an image or a video"
        case let .wrongFileType(name, .imageOrProject):
            "\(SenderText.shown(name)) isn't an image or a ClearShot project"
        case let .couldntOpen(name): "Couldn't open \(SenderText.shown(name))"
        case let .tooLarge(name): "\(SenderText.shown(name)) is too large to open"
        }
    }
}
