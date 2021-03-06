const std = @import("std");
const os = std.os;
const debug = std.debug;

const stdin = std.io.getStdIn();

/// A key that was pressed in addition to the `Input`.
const AltModifier = enum {
    none,
    alt,
};
/// A key that was pressed in addition to the `Input`.
const CtrlModifier = enum {
    none,
    ctrl,
};
/// A key that was pressed in addition to the `Input`.
const ShiftCtrlModifier = enum {
    none,
    shift,
    ctrl,
};

pub const Input = union(enum) {
    up: AltModifier,
    down: AltModifier,
    left: CtrlModifier,
    right: CtrlModifier,

    home: CtrlModifier,
    end: CtrlModifier,
    page_up, // TODO: implement the modifiers
    page_down, // TODO: implement the modifiers

    enter, // It seems this has no modifiers in many if not most terminals
    tab,

    backspace: CtrlModifier,
    delete: ShiftCtrlModifier,

    ctrl_s,

    esc,

    /// This is returned for every other input.
    ///
    /// This could be an input like a single keypress
    /// or a character that was input using an IME.
    bytes: []const u8,

    /// An external file descriptor other than the standard input stream that has input to read.
    readable_file_descriptor: os.fd_t,
};

// TODO: To implement the stuff below, maybe in the future one could use the
//       std's event loop and its I/O functionality when it improves and things
//       like `std.fs.Watch` are available without event-based I/O

/// An extensible set of file descriptors for `poll` to poll from.
var poll_file_descriptors = [2]os.pollfd{
    // Standard input stream
    os.pollfd{
        .fd = stdin.handle,
        .events = os.POLL.IN, // Await input
        .revents = undefined,
    },
    undefined,
};
var filled_poll_file_descriptor_count: usize = 1;

/// Adds a file descriptor to poll from using `poll`.
///
/// This is completely optional but very convenient if you happen to have
/// other file descriptors you would like to await input from
/// in addition to the standard input stream.
pub fn addPollFileDescriptor(file_descriptor: os.fd_t) !void {
    if (filled_poll_file_descriptor_count == poll_file_descriptors.len)
        return error.Full;

    poll_file_descriptors[filled_poll_file_descriptor_count] = .{
        .fd = file_descriptor,
        .events = os.POLL.IN, // Await input
        .revents = undefined,
    };
    filled_poll_file_descriptor_count += 1;
}

/// Polls for input on the standard input stream and any other file descriptors added using `addPollFileDescriptor`.
pub fn poll() !?Input {
    var file_descriptors = poll_file_descriptors[0..filled_poll_file_descriptor_count];

    // This `os.ppoll` will block until any of the file descriptors have input to read
    // or a signal was received.
    //
    // We specify no timeout and no signal mask.
    // The signal mask specifies the signals to block during the poll.
    //
    // Having no signal mask means that we will get `os.E.INTR` ("interrupt") if any signals
    // are received.
    // This is important for `os.SIG.WINCH` because if we receive it, `terminal.size`
    // will be updated (in the signal handler registered in `config.init`) and we want to stop blocking
    // any potential redraws using the updated `terminal.size` after this.
    //
    // We could make it so that we block all signals except `os.SIG.WINCH` by setting the
    // signal mask using `sigfillset` and `sigdelset` but we don't have to.
    //
    // We don't get the same behavior with `os.poll`.
    //
    // For an alternative solution to this, see the comment in `config.setTermios`.
    _ = os.ppoll(file_descriptors, null, null) catch |err| {
        if (err == os.PPollError.SignalInterrupt)
            // Stop blocking
            return null;
        return err;
    };

    for (file_descriptors) |file_descriptor| {
        if (file_descriptor.revents == os.POLL.IN) {
            // This file descriptor is ready to be read
            if (file_descriptor.fd == stdin.handle) {
                // Read terminal input
                return try readInput(stdin);
            } else {
                // It's an external file descriptor not managed by us so pass it on
                return Input{ .readable_file_descriptor = file_descriptor.fd };
            }
        }
    }

    unreachable;
}

var input_buffer: [6]u8 = undefined;

fn readInput(file: std.fs.File) !Input {
    const byte_count = try file.read(&input_buffer);
    return parseInput(input_buffer[0..byte_count]);
}

fn parseInput(bytes: []u8) Input {
    return switch (bytes[0]) {
        '\x1b' => {
            if (bytes.len == 1)
                return .esc;
            return switch (bytes[1]) {
                '[' => {
                    return switch (bytes[2]) {
                        'A' => .{ .up = .none },
                        'B' => .{ .down = .none },
                        'C' => .{ .right = .none },
                        'D' => .{ .left = .none },
                        'F' => .{ .end = .none },
                        'H' => .{ .home = .none },
                        '1' => {
                            debug.assert(bytes[3] == ';');
                            return switch (bytes[4]) {
                                '3' => {
                                    return switch (bytes[5]) {
                                        'A' => .{ .up = .alt },
                                        'B' => .{ .down = .alt },
                                        else => unreachable,
                                    };
                                },
                                '5' => {
                                    return switch (bytes[5]) {
                                        'C' => .{ .right = .ctrl },
                                        'D' => .{ .left = .ctrl },
                                        'F' => .{ .end = .ctrl },
                                        'H' => .{ .home = .ctrl },
                                        else => unreachable,
                                    };
                                },
                                else => unreachable,
                            };
                        },
                        '3' => {
                            return switch (bytes[3]) {
                                '~' => .{ .delete = .none },
                                ';' => {
                                    return switch (bytes[4]) {
                                        '5' => {
                                            // For XTerm
                                            debug.assert(bytes[5] == '~');
                                            return .{ .delete = .ctrl };
                                        },
                                        '2' => .{ .delete = .shift },
                                        else => unreachable,
                                    };
                                },
                                else => unreachable,
                            };
                        },
                        '5' => {
                            debug.assert(bytes[3] == '~');
                            return .page_up;
                        },
                        '6' => {
                            debug.assert(bytes[3] == '~');
                            return .page_down;
                        },
                        else => unreachable,
                    };
                },
                'd' => .{ .delete = .ctrl },
                else => unreachable,
            };
        },
        '\r' => .enter,
        '\t' => .tab,
        0x7F => .{ .backspace = .none },
        0x17 => .{ .backspace = .ctrl },
        0x08 => .{ .backspace = .ctrl }, // For XTerm
        19 => .ctrl_s,
        else => .{ .bytes = bytes },
    };
}
