//! This abstracts everything related to the terminal and provides everything needed for
//! display, manipulation, and input events.
//!
//! One great reference for this is <https://invisible-island.net/xterm/ctlseqs/ctlseqs.html>.

const std = @import("std");
const io = std.io;
const os = std.os;
const linux = os.linux;
const fmt = std.fmt;

const input = @import("terminal/input.zig");
pub const Input = input.Input;
pub const read = input.read;

const Position = @import("main.zig").Position;
const Size = @import("main.zig").Size;

const stdout = io.getStdOut();

const writing = struct {
    const stdout_writer = stdout.writer();
    var buffered_writer = (io.BufferedWriter(4096, @TypeOf(stdout_writer)){ .unbuffered_writer = stdout_writer });
    const writer = buffered_writer.writer();

    fn write(bytes: []const u8) !void {
        try writer.writeAll(bytes);
    }
    fn flush() !void {
        try buffered_writer.flush();
    }
};
pub const write = writing.write;
pub const writeByte = writing.writer.writeByte;
pub const writeByteNTimes = writing.writer.writeByteNTimes;
pub const print = writing.writer.print;
pub const flush = writing.flush;

pub var size: Size = undefined;

fn isSupported() bool {
    return stdout.supportsAnsiEscapeCodes();
}

/// Checks whether the terminal is supported and initializes the terminal.
pub fn init() !void {
    if (!isSupported())
        return error.Unsupported;
    size = try getSize();
    try config.init();
}
/// Deinitializes the terminal to its initial state.
pub fn deinit() !void {
    try config.deinit();
}

/// Returns the size of the terminal.
fn getSize() !Size {
    var winsize: linux.winsize = undefined;
    switch (os.errno(linux.ioctl(stdout.handle, linux.T.IOCGWINSZ, @ptrToInt(&winsize)))) {
        .SUCCESS => return Size{ .width = winsize.ws_col, .height = winsize.ws_row },
        else => |err| return os.unexpectedErrno(err),
    }
}

export fn setSize(signal: c_int, info: *const std.os.linux.siginfo_t, context: ?*const anyopaque) void {
    _ = signal;
    _ = info;
    _ = context;
    size = getSize() catch return;
}

/// Control Sequence Indicator.
const CSI = "\x1b[";

/// Operating System Command.
const OSC = "\x1b]";

/// Alert/beep/bell escape sequence.
const alert = "\x07";

pub const config = struct {
    var original_termios: os.termios = undefined;

    /// Initializes the terminal.
    fn init() !void {
        original_termios = try getTermios();

        var current_termios = original_termios;
        setTermios(&current_termios);
        try applyTermios(current_termios);

        // Register a signal handler for the event of the window being resized
        // so that we can update the size.
        // We could also just update the size every loop iteration but that'd be slower
        // than updating it on demand.
        const handler = os.Sigaction{
            .handler = .{ .sigaction = setSize },
            .mask = os.empty_sigset, // A set of signals to block from being handled during execution of the handler above
            .flags = 0, // No additional options needed
        };
        os.sigaction(os.SIG.WINCH, &handler, null);
    }

    fn deinit() !void {
        try applyTermios(original_termios);

        try disableAlternativeScreenBuffer();
        try showCursor();
    }

    fn getTermios() !os.termios {
        return os.tcgetattr(stdout.handle);
    }
    /// Configures the terminal's input handling.
    fn setTermios(termios: *os.termios) void {
        // Make the terminal raw (as opposed to cooked)
        termios.iflag &= ~(linux.IGNBRK | linux.BRKINT | linux.PARMRK | linux.ISTRIP | linux.INLCR | linux.IGNCR | linux.ICRNL | linux.IXON);
        termios.oflag &= ~linux.OPOST;
        termios.lflag &= ~(linux.ECHO | linux.ECHONL | linux.ICANON | linux.ISIG | linux.IEXTEN);
        termios.cflag &= ~(linux.CSIZE | linux.PARENB);
        termios.cflag |= linux.CS8;

        // As an alternative to the `std.os.ppoll` solution in `terminal.read`, here we could
        // set `termios.cc[std.os.linux.V.MIN]` to 0 and `termios.cc[std.os.linux.V.TIME]` to a certain timeout
        // to make `terminal.read` timeout.
    }
    fn applyTermios(termios: os.termios) !void {
        try os.tcsetattr(stdout.handle, .FLUSH, termios);
    }

    pub fn showCursor() !void {
        try write(CSI ++ "?25h");
    }
    pub fn hideCursor() !void {
        try write(CSI ++ "?25l");
    }

    pub fn enableAlternativeScreenBuffer() !void {
        try write(CSI ++ "?1049h");
    }
    pub fn disableAlternativeScreenBuffer() !void {
        try write(CSI ++ "?1049l");
    }
};

pub const cursor = struct {
    pub fn setPosition(position: Position) !void {
        // This is one-based
        try print(CSI ++ "{};{}H", .{ position.row + 1, position.column + 1 });
    }

    /// Moves the cursor to (0, 0).
    pub fn reset() !void {
        try write(CSI ++ ";H");
    }
};

pub const control = struct {
    /// Clears the entire screen.
    pub fn clear() !void {
        try write(CSI ++ "2J");
    }

    pub fn setBlackOnWhiteBackgroundCellColor() !void {
        try write(CSI ++ "30;107m");
    }

    pub fn resetForegroundAndBackgroundCellColor() !void {
        try write(CSI ++ "39;49m");
    }

    /// Sets the background color of the whole screen.
    ///
    /// `hex_color` is a hexadecimal color that does not start with a number sign.
    pub fn setScreenBackgroundColor(hex_color: []const u8) !void {
        try print(OSC ++ "11;#{s}" ++ alert, .{hex_color});
    }
    pub fn resetScreenBackgroundColor() !void {
        try write(OSC ++ "111" ++ alert);
    }

    /// Sets the foreground color of the whole screen.
    ///
    /// `hex_color` is a hexadecimal color that does not start with a number sign.
    pub fn setScreenForegroundColor(hex_color: []const u8) !void {
        try print(OSC ++ "10;#{s}" ++ alert, .{hex_color});
    }
    pub fn resetScreenForegroundColor() !void {
        try write(OSC ++ "110" ++ alert);
    }

    /// Sets the window's title.
    pub fn setTitle(title: []const u8) !void {
        try print(OSC ++ "0;{s}" ++ alert, .{title});
    }
};
