import AppKit
import Foundation

enum PrivilegedRunnerError: Error, Equatable {
    case cancelled
    /// Non-zero exit (or AppleScript error) with its code and message.
    case failed(code: Int, message: String)
}

/// Runs a fixed shell script as root through `do shell script ... with
/// administrator privileges`.
///
/// Arguments are passed to an AppleScript handler as Apple event parameters and
/// shell-quoted inside AppleScript with `quoted form of`. No caller-supplied
/// value is ever interpolated into AppleScript or shell source, so quotes,
/// backslashes, newlines, and `$()` in paths are inert data.
enum PrivilegedRunner {
    // OpenScripting four-char codes ('ascr', 'psbr', 'snam'); Carbon is not imported.
    private static let appleScriptSuite = AEEventClass(0x6173_6372)
    private static let subroutineEvent = AEEventID(0x7073_6272)
    private static let subroutineNameKeyword = AEKeyword(0x736E_616D)

    private static let handlerSource = """
    on run_script(script_text, script_arguments, as_root)
        set command_line to "/bin/sh -c " & quoted form of script_text & " soundbridge-helper"
        repeat with script_argument in script_arguments
            set command_line to command_line & " " & quoted form of (contents of script_argument)
        end repeat
        if as_root then
            return do shell script command_line with administrator privileges
        else
            return do shell script command_line
        end if
    end run_script
    """

    /// Must be called on the main thread (NSAppleScript is not thread-safe).
    static func run(script: String, arguments: [String], asRoot: Bool = true) -> Result<String, PrivilegedRunnerError> {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let appleScript = NSAppleScript(source: handlerSource) else {
            return .failure(.failed(code: -1, message: "Could not create AppleScript"))
        }

        let parameters = NSAppleEventDescriptor.list()
        parameters.insert(NSAppleEventDescriptor(string: script), at: 0)
        let argumentList = NSAppleEventDescriptor.list()
        for argument in arguments {
            argumentList.insert(NSAppleEventDescriptor(string: argument), at: 0)
        }
        parameters.insert(argumentList, at: 0)
        parameters.insert(NSAppleEventDescriptor(boolean: asRoot), at: 0)

        let event = NSAppleEventDescriptor(
            eventClass: appleScriptSuite,
            eventID: subroutineEvent,
            targetDescriptor: NSAppleEventDescriptor.currentProcess(),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setDescriptor(NSAppleEventDescriptor(string: "run_script"), forKeyword: subroutineNameKeyword)
        event.setDescriptor(parameters, forKeyword: keyDirectObject)

        var errorInfo: NSDictionary?
        let result = appleScript.executeAppleEvent(event, error: &errorInfo)
        if let errorInfo {
            let code = (errorInfo[NSAppleScript.errorNumber] as? Int) ?? -1
            let message = (errorInfo[NSAppleScript.errorMessage] as? String) ?? "Unknown error"
            return .failure(code == -128 ? .cancelled : .failed(code: code, message: message))
        }
        return .success(result.stringValue ?? "")
    }
}

/// The only commands ever executed as root. Destinations are fixed; the source
/// bundle is copied into a root-owned staging directory and every check runs on
/// that staged copy, so replacing the source after the user authorizes has no
/// effect.
///
/// Arguments: mode (install|update|repair|uninstall), source bundle path,
/// expected version, expected protocol version, expected team ID (may be empty).
enum DriverInstallScript {
    static let exitCodeMessages: [Int: String] = [
        2: "Invalid installer arguments",
        3: "The HAL plug-in directory is not trustworthy",
        4: "The driver destination is a symbolic link",
        5: "Could not create a staging directory",
        6: "Could not copy the driver",
        7: "Could not set driver ownership",
        8: "The driver bundle contains symbolic links",
        9: "The driver bundle identifier is wrong",
        10: "The driver version does not match the app",
        11: "The driver protocol does not match the app",
        12: "The driver signature does not match the app's developer",
        14: "Could not move the existing driver aside",
        15: "Could not install the driver; the previous driver was restored",
        16: "Installed driver verification failed; the previous driver was restored",
        21: "Could not remove the driver",
    ]

    static let source = #"""
    set -eu
    umask 022
    PATH=/usr/bin:/bin:/usr/sbin:/sbin
    export PATH

    HAL_DIR=/Library/Audio/Plug-Ins/HAL
    TARGET="$HAL_DIR/SoundBridgeDriver.driver"
    BUNDLE_ID=com.soundbridge.driver

    fail() { echo "$2" >&2; exit "$1"; }
    restart_audio() { killall coreaudiod 2>/dev/null || true; }
    plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2" 2>/dev/null; }

    [ "$#" -eq 5 ] || fail 2 "expected 5 arguments"
    MODE=$1
    SOURCE=$2
    EXPECTED_VERSION=$3
    EXPECTED_PROTOCOL=$4
    TEAM_ID=$5

    if [ -L /Library/Audio ] || [ -L /Library/Audio/Plug-Ins ] || [ -L "$HAL_DIR" ]; then
        fail 3 "symlinked plug-in directory"
    fi
    [ -L "$TARGET" ] && fail 4 "symlinked destination"

    case "$MODE" in
        uninstall)
            if [ -e "$TARGET" ]; then
                rm -rf "$TARGET" || fail 21 "remove failed"
            fi
            [ -e "$TARGET" ] && fail 21 "driver still present"
            restart_audio
            exit 0
            ;;
        install|update|repair) ;;
        *) fail 2 "unknown mode" ;;
    esac

    case "$SOURCE" in /*) ;; *) fail 2 "source must be absolute" ;; esac
    [ -d "$SOURCE" ] || fail 6 "source missing"
    case "$EXPECTED_PROTOCOL" in ''|*[!0-9]*) fail 2 "bad protocol argument" ;; esac
    if [ -n "$TEAM_ID" ]; then
        case "$TEAM_ID" in *[!A-Z0-9]*) fail 2 "bad team argument" ;; esac
        [ "${#TEAM_ID}" -eq 10 ] || fail 2 "bad team argument"
    fi

    mkdir -p "$HAL_DIR"
    [ "$(stat -f %u "$HAL_DIR")" = 0 ] || fail 3 "plug-in directory not owned by root"
    STAGE=$(mktemp -d "$HAL_DIR/.soundbridge-stage.XXXXXX") || fail 5 "mktemp failed"
    STAGED="$STAGE/SoundBridgeDriver.driver"
    BACKUP="$STAGE/previous.driver"
    # If we are interrupted between moving the old driver aside and moving the
    # new one in, put the old one back before discarding the staging directory.
    cleanup() {
        if [ ! -e "$TARGET" ] && [ -e "$BACKUP" ]; then
            mv "$BACKUP" "$TARGET" || true
        fi
        rm -rf "$STAGE"
    }
    trap cleanup EXIT
    trap 'exit 130' INT TERM HUP

    ditto --norsrc --noextattr --noqtn --noacl "$SOURCE" "$STAGED" || fail 6 "copy failed"
    chown -R root:wheel "$STAGED" || fail 7 "chown failed"
    chmod -R go-w "$STAGED" || fail 7 "chmod failed"
    [ -z "$(find "$STAGED" -type l -print)" ] || fail 8 "symlinks in bundle"

    PLIST="$STAGED/Contents/Info.plist"
    [ "$(plist_value CFBundleIdentifier "$PLIST")" = "$BUNDLE_ID" ] || fail 9 "bundle identifier"
    [ "$(plist_value CFBundleShortVersionString "$PLIST")" = "$EXPECTED_VERSION" ] || fail 10 "version"
    [ "$(plist_value SoundBridgeProtocolVersion "$PLIST")" = "$EXPECTED_PROTOCOL" ] || fail 11 "protocol"
    if [ -n "$TEAM_ID" ]; then
        REQUIREMENT="anchor apple generic and identifier \"$BUNDLE_ID\" and certificate leaf[subject.OU] = \"$TEAM_ID\""
        codesign --verify --strict --deep "-R=$REQUIREMENT" "$STAGED" >/dev/null 2>&1 || fail 12 "signature"
    fi

    if [ -e "$TARGET" ]; then
        mv "$TARGET" "$BACKUP" || fail 14 "move aside failed"
    fi
    if ! mv "$STAGED" "$TARGET"; then
        [ -e "$BACKUP" ] && mv "$BACKUP" "$TARGET"
        fail 15 "install failed"
    fi
    if [ "$(plist_value CFBundleShortVersionString "$TARGET/Contents/Info.plist")" != "$EXPECTED_VERSION" ]; then
        rm -rf "$TARGET"
        [ -e "$BACKUP" ] && mv "$BACKUP" "$TARGET"
        restart_audio
        fail 16 "post-install verification failed"
    fi
    restart_audio
    exit 0
    """#
}
